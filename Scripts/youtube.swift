#!/usr/bin/env swift
//
// GlobeShot 直播目录服务。
//
// 子命令：
//   mine [--limit N] [--offset N]  按 keywords.json 批量挖掘候选，合并进 candidates.json
//   enrich                         给已有的 candidates.json 补频道国家（分国家归拢用）
//   refresh [--limit N] [--reuse]  读 channels-source.json，产出 live-youtube.json
//
// `refresh` 是**两段式**取源（2026-10-14 起）：先走频道上传列表窗口（1 unit/频道），
// 窗口里没有在播的再用 search.list 兜底（100 units/个，只花当天余量）。所以全量刷新
// 从"13,800 units、两天跑一遍"降到"约 210 units、一天跑得完"。产出的每条都带
// `live` 与 `verifiedAt`，这两个字段是 App 判断"能不能播"的唯一依据。
//
// 密钥只走环境变量 YT_API_KEY，脚本与产物里都不落。
// 退出码非 0 表示失败，供 CI 判断。
//

import Foundation

// MARK: - 配额与口径

/// Data API v3 的配额是**项目级**的（绑 Google Cloud 项目，全体用户共享），不是按用户算。
enum Quota {
    /// search.list 一次 100 units；videos.list / channels.list 一次 1 unit（最多传 50 个 id）。
    static let perSearch = 100
    static let perDay = 10_000

    /// `search.list` 官方配额页（2026-10-08）写明的**独立**日上限：
    /// *"The search.list and videos.insert methods have their own quota buckets. Each of these
    /// methods has a default daily limit of 100 per day. The quota cost is 1 per call."*
    /// 也即：搜索的硬约束是**一天 100 次调用**，而且它不跟其它端点抢那 10,000 units。
    ///
    /// 本项目仍按旧模型记账（一次 100 units、与刷新共用 10,000 的池子）——那是**偏保守**的算法，
    /// 宁可低估余额。按旧模型算出的极限也是 100 次/天，**两个模型在"一天能搜多少次"上一致**，
    /// 所以策划语区覆盖时用这个数就行。分页每多一页算一次调用。
    static let searchCallsPerDay = 100

    /// 给刷新的 L3 兜底留出的调用数（用户口径：「刷新预留 30 次」）。
    ///
    /// 挖矿与刷新抢的是同一个搜索桶，而这个桶一天只有 100 次：一天里挖 100 次关键词，刷新就
    /// 一次兜底都发不出去，反过来刷新把 50 条不在播的频道全兜一遍，挖矿那天也就废了。
    /// 所以固定切一刀：**刷新最多 30 次，挖矿最多 70 次**。
    static let searchReservedForRefresh = 30
}

/// 一个频道这一轮的结果。`prune` 只认这个，不认"有没有出现在今天的产物里"。
enum ChannelOutcome: String, Codable, Sendable {
    /// 找到在播且能播的流 → 会发布。
    case playable
    /// 找到在播的流，但刚开播（开播时长门槛没过）。**频道是活的**，不能算失败。
    case startingUp
    /// 窗口与兜底都没找到在播的流。
    case offAir
    /// 在播，但所有者不允许嵌入播放（官方 `status.embeddable`）。
    case notEmbeddable
    /// 在播，但被参照市场屏蔽。
    case regionBlocked
    /// 上传列表 404：频道没了，或者把上传列表藏了。
    case unreachable
}

/// 连续多少次拿不到可播的流才动目录。
///
/// **必须分级，因为"频道没了"和"今天没开播"是两件事**：实测同一天里就有 47/138 条不在播
/// （日更机位在两次开播之间本来就是关的），按一次观测就删会把目录砍掉三分之一。
enum PrunePolicy {
    /// 上传列表 404：频道已经不在，或把上传列表藏了。这种一次就够。
    static let unreachable = 1
    /// 在播但被拒（关了嵌入 / 被地区屏蔽）：信号强，但下一个 broadcast 的开关可能不同，给三次。
    static let rejected = 3
    /// 找不到在播的：日更、维护、临时中断都长这样，一周为限。
    static let offAir = 7

    /// 这种结果连续出现几次就该清掉。`nil` = 永远不清（频道是活的）。
    static func threshold(_ outcome: ChannelOutcome) -> Int? {
        switch outcome {
        case .unreachable: unreachable
        case .notEmbeddable, .regionBlocked: rejected
        case .offAir: offAir
        case .playable, .startingUp: nil
        }
    }
}

/// 清理账本：跨次刷新记住"哪些频道一直拿不到可播的流"。
///
/// 单次刷新答不了"这个频道还能不能播"——它只知道"此刻在不在播"。所以账要跨天记，
/// 而唯一的跨天载体是 `data` 分支上那两个文件（feed 与它）。只记有问题的频道，可播的清零，
/// 文件因此不会长大。
struct RefreshState: Codable, Sendable {
    struct Entry: Codable, Sendable {
        /// 连续多少次没拿到可播的流。
        var misses: Int
        var outcome: ChannelOutcome
        var lastCheckedAt: String
        /// 给人工看的一句话（如"上传列表 404"）。
        var note: String?
    }

    var generatedAt: String
    /// channelId → 条目，只含有问题的。
    var channels: [String: Entry]

    /// 已经达到清理阈值的那些。
    var prunable: [(channelID: String, entry: Entry)] {
        channels
            .compactMap { channelID, entry in
                guard let threshold = PrunePolicy.threshold(entry.outcome) else { return nil }
                return entry.misses >= threshold ? (channelID, entry) : nil
            }
            .sorted { $0.channelID < $1.channelID }
    }
}

/// `refresh` 一次要花多少 units，开工前就能算出来——与 `search.list` 那种按频道线性涨的成本
/// 完全不同。守卫放在前面：算得清才开工，而且**算的是最坏情况**（一条都复用不上、两级窗口全走满）；
/// 实花多少由 `Meter` 在收尾时报出来，不靠人算（坑 33 就是算漏了尾巴）。
///
/// 阶梯，越靠前越便宜（2026-10-14 优化后的顺序）：
///   L0 复核上一次的 videoId（1 unit / 50 个频道）——还活着就直接复用，不查窗口
///   L1 上传窗口前 10 条（1 unit / 频道）+ 复核（1 unit / 50 个 id）
///   L2 同一个窗口翻到第 50 条（1 unit / 频道）+ 复核
///   L3 `search.list` 兜底（100 units / 个 + 1 复查），只花当天余量
enum RefreshCost {
    /// 先窄后宽：窄窗口的复核便宜，宽窗口只对没找到的那些再开一次。
    static let windowFirst = 10
    static let windowWide = 50

    /// `videos.list` 与 `playlistItems` 都是 1 unit，一次最多 50 个 id。
    static func check(_ ids: Int) -> Int { (ids + 49) / 50 }

    /// 最坏情况：没有一条能复用，全部走 L1、又全部走 L2。
    static func ceiling(_ channels: Int) -> Int {
        check(channels)
            + channels + check(channels * windowFirst)
            + channels + check(channels * (windowWide - windowFirst))
    }

    /// 兜底一个频道：`search.list` 一次，加上那一条的三道校验复查。
    static let search = Quota.perSearch + 1
}

enum Region {
    /// 地区限制的参照市场：被这些市场屏蔽的流不要。
    /// 用户主体在欧美，先用美国当基准；要放宽就往这里加。
    static let reference = ["US"]
}

// MARK: - 输入 / 输出模型

struct Coordinate: Codable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// channels-source.json 的一条：人工策展出来的频道。
/// id 绑定**频道**而不是 videoId——直播重开一次 videoId 就变，App 那边的观看历史会断。
struct Seed: Codable, Sendable {
    let id: String
    let channelId: String
    let name: String
    let country: String
    let city: String?
    let coordinate: Coordinate?
    let category: String
    let isLandmark: Bool
    let source: String
}

/// keywords.json 的一条。只有词和类别——国家和城市**不能**从查询词推，
/// 见 Candidate 的注释。
struct Query: Codable, Sendable {
    let q: String
    let category: String
}

/// mine 的产物，给人工筛选用。
///
/// 这里刻意**不带** country / city / isLandmark：它们只能人工确认。
/// 早先的版本把查询词里的国家城市直接盖在返回结果上，于是
/// "Melbourne live cam" 找到的游隼鸟巢被标成 AU:Melbourne、
/// "Osaka live cam" 找到的横滨摄像头被标成 JP:Osaka。
/// 查询词跟结果在哪座城市毫无关系。
struct Candidate: Codable, Sendable {
    let query: String
    let category: String
    let channelId: String
    let channelTitle: String
    let videoId: String
    let title: String
    var viewers: Int?
    /// 卡片上那张静帧。挖掘收尾时从 `videos.list` 顺手记下，`refresh --reuse` 重新打包时直接带走。
    var thumbnail: String?
    /// 频道自报的国家（`channels.list` 的 `snippet.country`）。是**提示**不是事实：
    /// 频道注册地不一定是镜头所在地。人工筛的时候用它归拢，不要直接当数据用。
    var channelCountry: String?
}

struct CandidateFile: Codable, Sendable {
    var generatedAt: String
    var candidates: [Candidate]
    /// 已经跑过的关键词。
    ///
    /// **额度是这套东西最大的约束**：一条关键词 100 units，重复跑一遍等于白烧。所以"挖过"要
    /// 记账，而账就写在这个文件自己身上——不新增文件，也不会被别的子命令丢掉（它们重写这个
    /// 文件时必须把它带走）。可选，好让老文件照样解出来。
    var minedQueries: [String]?
}

/// 人工筛选。跟候选池分开放：候选是机器挖的，这份是人写的，
/// 混在一起就分不清哪个结论是谁定的了。每一轮挖掘都要重来一次，所以写成数据而不是代码。
struct Curation: Codable, Sendable {
    /// channelId → 剔除原因。
    var exclude: [String: String]
    /// channelId → 正确的国家。用来改掉"频道注册地 ≠ 镜头所在地"，也用来补频道没公开的那些。
    var country: [String: String]
}

/// 人工编辑层：机械生成的清单里，频道名不是地点名的那一批在这里改。
/// 跟 curation.json 分开，是因为它管的是"成品长什么样"，不是"留不留"。
struct SeedOverride: Codable, Sendable {
    var name: String?
    var city: String?
    var coordinate: Coordinate?
    var category: String?
    var isLandmark: Bool?
}

/// refresh 的产物，App 读它。
///
/// **字段就是 App 那边 `LiveChannel` 的字段**，一个不多一个不少。App 的解码是合成的，
/// 少一个必填键就整份解不出来——而两边的名字一旦不一致，坏的是全部条目，不是某一条。
/// 所以：改这里之前先看 `LiveChannel`；能推出来的东西（videoId）不重复携带，App 从 `url` 里取。
struct Stream: Codable, Sendable {
    let id: String
    let name: String
    let country: String
    let city: String?
    let coordinate: Coordinate?
    let category: String
    let isLandmark: Bool
    let url: String
    /// 这条流该怎么播。YouTube 只能走它自己的嵌入播放器，所以这个事实由 feed 声明，
    /// 而不是让 App 从 URL 的域名去反推——知道答案的是产出方。
    let playback: String
    let source: String
    /// 清单是按常驻机位策展的，所以一律 true。这一项只影响列表的排序优先级。
    let is24x7: Bool
    let viewers: Int?
    /// 卡片上那张静帧。**不**从 videoId 推：直播这张图由 YouTube 随画面刷新，
    /// 拼 `i.ytimg.com` 的固定路径拿到的可能是旧画面，而且那条路径不是我们能依赖的接口。
    let thumbnail: String?
    /// 写这份文件时，这条是否在播；`verifiedAt` 是上面这个结论的时间。
    ///
    /// 两个都是**可选**，因为"没回答"必须和"回答了否"分得开：App 拿到没有结论的目录时不做
    /// 过滤（快照与 Bundle 兜底都属于这一类），拿到过期的结论时才降级展示并加一行提示。
    /// 发出去的条目按定义都是确认在播的（三道校验 + 开播时长门槛），所以有 `verifiedAt` 就是
    /// `live: true`。
    let live: Bool?
    let verifiedAt: String?
}

struct Feed: Codable, Sendable {
    /// 两个仓库独立演进：将来服务端加字段时，老版本 App 不该解崩。
    let schema: Int
    let generatedAt: String
    let streams: [Stream]
}

// MARK: - YouTube 响应

struct SearchResponse: Decodable {
    struct Item: Decodable {
        struct Id: Decodable { let videoId: String? }
        struct Snippet: Decodable {
            let title: String
            let channelId: String
            let channelTitle: String
        }
        let id: Id
        let snippet: Snippet
    }
    let items: [Item]?
}

struct VideosResponse: Decodable {
    struct Item: Decodable {
        struct Snippet: Decodable {
            let liveBroadcastContent: String
            let thumbnails: Thumbnails?
        }
        /// 尺寸是按名字给的，任意一档都可能缺。挑到的那档用最大的一张：
        /// 卡片是裁切显示，原图越大越经得起裁。
        struct Thumbnails: Decodable {
            struct Thumbnail: Decodable { let url: String }
            let maxres: Thumbnail?
            let standard: Thumbnail?
            let high: Thumbnail?
            let medium: Thumbnail?
        }
        struct Status: Decodable { let embeddable: Bool? }
        struct ContentDetails: Decodable {
            struct RegionRestriction: Decodable {
                let allowed: [String]?
                let blocked: [String]?
            }
            let regionRestriction: RegionRestriction?
        }
        struct LiveStreamingDetails: Decodable {
            let concurrentViewers: String?
            /// 这一场实际开播的时刻。用来挡掉"刚开播就断"的流，见 `isSettled`。
            let actualStartTime: String?
        }

        let id: String
        let snippet: Snippet
        let status: Status?
        let contentDetails: ContentDetails?
        let liveStreamingDetails: LiveStreamingDetails?
    }
    let items: [Item]?
}

struct ChannelsResponse: Decodable {
    struct Item: Decodable {
        struct Snippet: Decodable { let country: String? }
        let id: String
        let snippet: Snippet
    }
    let items: [Item]?
}

struct PlaylistItemsResponse: Decodable {
    struct Item: Decodable {
        struct ContentDetails: Decodable { let videoId: String }
        let contentDetails: ContentDetails
    }
    let items: [Item]?
    /// 窗口要翻页时用它，`maxResults` 上限 50。
    let nextPageToken: String?
}

struct ErrorResponse: Decodable {
    struct Body: Decodable {
        struct Detail: Decodable { let reason: String? }
        let message: String
        let errors: [Detail]?
    }
    let error: Body
}

// MARK: - 错误

struct ServiceError: Error, LocalizedError, Sendable {
    let reason: String
    let detail: String

    var errorDescription: String? { "\(reason)：\(detail)" }

    static func input(_ detail: String) -> ServiceError {
        ServiceError(reason: "input", detail: detail)
    }

    static func quota(_ detail: String) -> ServiceError {
        ServiceError(reason: "quotaExceeded", detail: detail)
    }
}

// MARK: - 文件落位

func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func read<T: Decodable>(_ name: String) throws -> T {
    let url = repoRoot().appending(path: name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ServiceError.input("\(name) 不存在，期望在 \(repoRoot().path)")
    }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

func write<T: Encodable>(_ value: T, _ name: String) throws {
    let encoder = JSONEncoder()
    // 键排序：这些文件每次重跑都会被整个覆盖，顺序不定的话 diff 全是噪声，看不出真正改了什么。
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    try encoder.encode(value).write(to: repoRoot().appending(path: name))
}

func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: Date())
}

// MARK: - 额度记账

/// 这次跑了多少 units。
///
/// 所有请求都从 `call` 出去，所以计数只放在那一处。**"最省额度"的前提是先看得见花了多少** ——
/// 这个脚本此前只打印第一段的预算，实花要靠人算（坑 33 就是这么来的）。
actor Meter {
    static let shared = Meter()

    private(set) var spent = 0
    private var byPath: [String: Int] = [:]
    /// `search.list` 的**调用次数**。
    ///
    /// 它才是搜索真正的额度：官方配额页（2026-10-08）写明 `search.list` 有**自己**的配额桶，
    /// "100 quota per day. Each call costs 1 quota" —— 100 次/天，而其它端点合计 10,000 units/天。
    /// 分页每多取一页也算一次调用。本项目现在的记账仍按旧模型（一次 100 units、与刷新共用
    /// 10,000 的池子），那是**偏保守**的算法：宁可低估余额，也不要算出个跑一半断掉的任务。
    /// 但"一天能扫多少语区"这件事，只有这个计数说得清，所以单独数一遍。
    private(set) var searchCalls = 0

    func note(_ units: Int, path: String) {
        spent += units
        byPath[path, default: 0] += units
    }

    func countSearchCall() { searchCalls += 1 }

    func report() {
        let detail = byPath.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，")
        print("\n本次共花 \(spent) units（\(detail.isEmpty ? "没有请求" : detail)）")
        if searchCalls > 0 {
            print("搜索调用 \(searchCalls) 次（`search.list` 自己的日上限是 100 次；一页 = 一次 = 最多 50 条）")
        }
    }
}

// MARK: - 请求

/// 一次调用花掉的额度：`search.list` 是 100，其余（`videos` / `playlistItems` / `channels`）都是 1。
/// 不传就是 1——只有 `searchLive` 需要显式给 100。
func call<T: Decodable>(
    _ type: T.Type,
    path: String,
    query: [URLQueryItem],
    units: Int = 1
) async throws -> T {
    let key = ProcessInfo.processInfo.environment["YT_API_KEY"] ?? ""
    guard !key.isEmpty else {
        throw ServiceError.input("环境变量 YT_API_KEY 没有设置")
    }

    var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(path)")!
    components.queryItems = query + [URLQueryItem(name: "key", value: key)]

    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 20

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw ServiceError(reason: "notHTTP", detail: "响应不是 HTTP")
    }

    guard (200..<300).contains(http.statusCode) else {
        // 具体原因在响应体里：quotaExceeded / keyInvalid / ipRefererBlocked 都在
        // error.errors[0].reason。只报状态码会把"给密钥配了应用限制"这类问题藏起来。
        let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        throw ServiceError(
            reason: decoded?.error.errors?.first?.reason ?? "http\(http.statusCode)",
            detail: decoded?.error.message ?? String(decoding: data, as: UTF8.self)
        )
    }

    await Meter.shared.note(units, path: path)

    return try JSONDecoder().decode(T.self, from: data)
}

func searchLive(_ extra: [URLQueryItem]) async throws -> [SearchResponse.Item] {
    await Meter.shared.countSearchCall()
    let response = try await call(
        SearchResponse.self,
        path: "search",
        query: extra + [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "eventType", value: "live"),
            URLQueryItem(name: "type", value: "video"),
            // 只取允许嵌入的。漏了这个参数会拿到一批所有者关闭了嵌入的频道，
            // 播放器一律报 152，看起来像"YouTube 嵌入不可用"，其实是筛错了。
            URLQueryItem(name: "videoEmbeddable", value: "true")
        ],
        units: Quota.perSearch
    )
    return response.items ?? []
}

func fetchDetails(ids: [String]) async throws -> [VideosResponse.Item] {
    var items: [VideosResponse.Item] = []
    var index = 0

    while index < ids.count {
        let chunk = Array(ids[index..<min(index + 50, ids.count)])
        let response = try await call(VideosResponse.self, path: "videos", query: [
            URLQueryItem(name: "part", value: "snippet,status,contentDetails,liveStreamingDetails"),
            URLQueryItem(name: "id", value: chunk.joined(separator: ","))
        ])
        items += response.items ?? []
        index += 50
    }
    return items
}

/// 频道自报国家的映射。查不到的频道不会出现在结果里——多数频道没有公开这一项。
func fetchChannelCountries(ids: [String]) async throws -> [String: String] {
    var countries: [String: String] = [:]
    var index = 0

    while index < ids.count {
        let chunk = Array(ids[index..<min(index + 50, ids.count)])
        let response = try await call(ChannelsResponse.self, path: "channels", query: [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "id", value: chunk.joined(separator: ","))
        ])
        for item in response.items ?? [] {
            if let country = item.snippet.country, !country.isEmpty {
                countries[item.id] = country
            }
        }
        index += 50
    }
    return countries
}

/// 频道的上传列表 id。
///
/// 官方约定是把 channelId 的 `UC` 换成 `UU`（实测 5/5 与 `channels.list` 给的
/// `relatedPlaylists.uploads` 完全一致），所以**不再花那 1 unit/50 去问**。隐藏了上传列表的
/// 频道会拿到 404——调用方把它当作"这个频道这轮没找到"，不影响其他频道。
func uploadsPlaylist(_ channelID: String) -> String {
    "UU" + channelID.dropFirst(2)
}

/// 一个频道的上传窗口。
///
/// **不能只取最新一条**：实测在播的那条不一定排第一（Lisbon / Tokyo 的当日直播都在第 2 位）。
/// 窗口开大不额外花钱（`maxResults` 从 1 到 50 都是 1 unit），花钱的是后面按 id 复核，
/// 所以阶梯是"先窄后宽"：先看 10 条（复核便宜），没找到再用 `nextPageToken` 取到第 50 条。
func fetchWindow(
    playlist: String,
    size: Int,
    pageToken: String? = nil
) async throws -> (ids: [String], next: String?) {
    let response = try await call(PlaylistItemsResponse.self, path: "playlistItems", query: [
        URLQueryItem(name: "part", value: "contentDetails"),
        URLQueryItem(name: "playlistId", value: playlist),
        URLQueryItem(name: "maxResults", value: String(size))
    ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? []))

    return ((response.items ?? []).map(\.contentDetails.videoId), response.nextPageToken)
}

/// 把一批"频道 → 窗口 id"复核成结果：一次 `videos.list`（去重后 50 个一批）判断每条是否
/// 在播、可嵌入、没被参照市场屏蔽，再按窗口顺序取最靠前的一条。
///
/// 窗口里那条若"刚开播"就记进 `justStarted`，**不再往下找**——它下播的概率比它变成熟的概率大。
func resolveWindows(
    _ seeds: [Seed],
    windows: [String: [String]]
) async throws -> (
    resolved: [String: VideosResponse.Item],
    justStarted: [String],
    unresolved: [Seed],
    rejected: [String: ChannelOutcome]
) {
    let ids = Array(Set(windows.values.flatMap { $0 }))
    guard !ids.isEmpty else { return ([:], [], seeds, [:]) }

    let items = try await fetchDetails(ids: ids)
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let usable = Dictionary(
        items.filter(isPlayable).map { ($0.id, $0) },
        uniquingKeysWith: { a, _ in a }
    )

    var resolved: [String: VideosResponse.Item] = [:]
    var justStarted: [String] = []
    var unresolved: [Seed] = []
    var rejected: [String: ChannelOutcome] = [:]

    for seed in seeds {
        let window = (windows[seed.id] ?? []).compactMap { byID[$0] }

        switch window.first(where: { usable[$0.id] != nil }) {
        case .some(let item) where isSettled(item):
            resolved[seed.id] = item
        case .some:
            justStarted.append(seed.id)
        case .none:
            // 窗口里若有**在播但被拒**的那条，把它记下来：`prune` 要靠这个区分
            // "今天没开播"（不能删）与"所有者关了嵌入"（该删）。
            if let refused = window.first(where: { $0.snippet.liveBroadcastContent == "live" }),
               let outcome = rejection(refused) {
                rejected[seed.id] = outcome
            }
            unresolved.append(seed)
        }
    }

    return (resolved, justStarted, unresolved, rejected)
}

/// 把这一轮的结果并进清理账本。
///
/// 只记**有问题的**频道：可播与"刚开播"都算"见到活的"，账清零——这样账本只在真出问题时长大，
/// 而"删不删"由 `PrunePolicy` 按**连续**次数判：一次观测不足以给一个频道定性
/// （实测同一天 47/138 条不在播，日更机位在两次开播之间本来就是关的）。
func updateState(
    previous: String?,
    seeds: [Seed],
    resolved: Set<String>,
    startingUp: Set<String>,
    rejected: [String: ChannelOutcome],
    unreachable: Set<String>,
    checkedAt: String
) throws -> RefreshState {
    let saved: RefreshState? = previous.flatMap { path in
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(RefreshState.self, from: data)
    }

    var channels = saved?.channels ?? [:]

    for seed in seeds {
        if resolved.contains(seed.id) || startingUp.contains(seed.id) {
            channels.removeValue(forKey: seed.channelId)
            continue
        }

        let outcome: ChannelOutcome
        let note: String

        if let refusal = rejected[seed.id] {
            outcome = refusal
            note = refusal == .notEmbeddable ? "在播但所有者关了嵌入" : "在播但被参照市场屏蔽"
        } else if unreachable.contains(seed.id) {
            outcome = .unreachable
            note = "上传列表 404（频道没了或隐藏了）"
        } else {
            outcome = .offAir
            note = "窗口与兜底都没找到在播的流"
        }

        channels[seed.channelId] = RefreshState.Entry(
            misses: (channels[seed.channelId]?.misses ?? 0) + 1,
            outcome: outcome,
            lastCheckedAt: checkedAt,
            note: note
        )
    }

    return RefreshState(generatedAt: checkedAt, channels: channels)
}

/// 上一次发布的产物里，`seed.id` → videoId。
///
/// 这是 L0 复用的输入：workflow 会先 `git fetch origin data` 把上一次的 feed 取下来（那一条分支
/// 上就一份文件），本地则可以直接指到工作区里那份。读不到就当没有——**L0 是纯节省，缺了不影响
/// 正确性**，只是全部走窗口。
func readPreviousVideoIDs(_ path: String) throws -> [String: String] {
    struct Previous: Decodable {
        struct Stream: Decodable {
            let id: String
            let url: String
        }
        let streams: [Stream]
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let feed = try JSONDecoder().decode(Previous.self, from: data)

    var byID: [String: String] = [:]
    for stream in feed.streams {
        let videoID = URLComponents(string: stream.url)?
            .queryItems?.first { $0.name == "v" }?.value
        if let videoID { byID[stream.id] = videoID }
    }
    return byID
}

/// 三道校验：正在直播、允许嵌入、没有被参照市场屏蔽。
/// search 的 `videoEmbeddable` 已经筛过一遍，这里复查是因为清单是人工维护的，
/// 频道主随时可以回头关掉嵌入。
func isPlayable(_ item: VideosResponse.Item) -> Bool {
    guard item.snippet.liveBroadcastContent == "live" else { return false }
    guard item.status?.embeddable == true else { return false }

    if let restriction = item.contentDetails?.regionRestriction {
        if let blocked = restriction.blocked, !Set(blocked).isDisjoint(with: Region.reference) {
            return false
        }
        if let allowed = restriction.allowed, !Region.reference.allSatisfy(allowed.contains) {
            return false
        }
    }
    return true
}

/// 一条**在播**的视频为什么不能发。不是"在播"的返回 `nil`——那属于"今天没开播"，
/// 与"这条内容不允许被嵌入"是两件事，`prune` 也正是靠这个区分决定删不删。
func rejection(_ item: VideosResponse.Item) -> ChannelOutcome? {
    guard item.snippet.liveBroadcastContent == "live" else { return nil }
    guard item.status?.embeddable == true else { return .notEmbeddable }

    if let restriction = item.contentDetails?.regionRestriction {
        if let blocked = restriction.blocked, !Set(blocked).isDisjoint(with: Region.reference) {
            return .regionBlocked
        }
        if let allowed = restriction.allowed, !Region.reference.allSatisfy(allowed.contains) {
            return .regionBlocked
        }
    }

    return nil
}

/// 刚开播的流这次先不发：刷新间隔是一天，开播三分钟就断的流派出去，用户点开就是黑的。
/// 判据是 `actualStartTime`，不需要跨次状态——CI 里根本没有上一次的产物可比。
/// 字段缺失时按"可发"处理：不能因为一个可选字段没给就丢掉一台确实在播的相机。
let minimumUptime: TimeInterval = 10 * 60

func isSettled(_ item: VideosResponse.Item, now: Date = Date()) -> Bool {
    guard let raw = item.liveStreamingDetails?.actualStartTime,
          let started = ISO8601DateFormatter().date(from: raw)
    else { return true }

    return now.timeIntervalSince(started) >= minimumUptime
}

func liveViewers(_ item: VideosResponse.Item) -> Int? {
    item.liveStreamingDetails?.concurrentViewers.flatMap(Int.init)
}

/// 卡片上那张静帧的地址。直播的这张图由 YouTube 随画面刷新，所以取它给的地址，
/// 而不是让 App 拼 `i.ytimg.com` 的固定路径——那条路径不归我们管，也拿不到实时画面。
func bestThumbnail(_ item: VideosResponse.Item) -> String? {
    let sizes = item.snippet.thumbnails
    return sizes?.maxres?.url ?? sizes?.standard?.url ?? sizes?.high?.url ?? sizes?.medium?.url
}

/// 单次几十个请求连着打没必要把限流和配额一次吃满。
func pause() async throws {
    try await Task.sleep(for: .milliseconds(300))
}

/// 候选按频道自报的国家分组打印，人工筛的时候好按地区过。
func printGrouped(_ candidates: [Candidate]) {
    let grouped = Dictionary(grouping: candidates) { $0.channelCountry ?? "未标注" }
    print("\n按频道自报国家归拢：")

    for country in grouped.keys.sorted(by: { ($0 == "未标注" ? "ZZ" : $0) < ($1 == "未标注" ? "ZZ" : $1) }) {
        let bucket = grouped[country]!.sorted { ($0.viewers ?? 0) > ($1.viewers ?? 0) }
        print("\n  [\(country)] \(bucket.count) 条")
        for candidate in bucket {
            let viewers = candidate.viewers.map(String.init) ?? "-"
            print("    \(viewers.padding(toLength: 7, withPad: " ", startingAt: 0)) \(candidate.category.padding(toLength: 10, withPad: " ", startingAt: 0)) \(candidate.channelTitle.prefix(28).padding(toLength: 28, withPad: " ", startingAt: 0)) \(candidate.title.prefix(46))")
        }
    }
}

// MARK: - refresh

/// 一条策展记录 + 解析出来的直播信息，合成 App 读的那条。
///
/// `verifiedAt` 为 nil 表示这份产物**没有结论**（`--reuse` 快照）：`live` 也跟着是 nil，
/// 不能写 false——App 那边"没回答"与"回答了否"是两种处理，后者会被过滤掉。
func makeStream(seed: Seed, videoId: String, viewers: Int?, thumbnail: String?, verifiedAt: String?) -> Stream {
    Stream(
        id: seed.id,
        name: seed.name,
        country: seed.country,
        city: seed.city,
        coordinate: seed.coordinate,
        category: seed.category,
        isLandmark: seed.isLandmark,
        url: "https://www.youtube.com/watch?v=\(videoId)",
        playback: "youTubeEmbed",
        source: seed.source,
        is24x7: true,
        viewers: viewers,
        thumbnail: thumbnail,
        live: verifiedAt.map { _ in true },
        verifiedAt: verifiedAt
    )
}

func refresh(limit: Int?, reuse: Bool, previous: String?, state: String?) async throws {
    let all: [Seed] = try read("channels-source.json")
    guard !all.isEmpty else {
        throw ServiceError.input("channels-source.json 是空的，先跑 mine 再人工筛一遍")
    }

    let seeds = limit.map { Array(all.prefix($0)) } ?? all
    guard !seeds.isEmpty else {
        throw ServiceError.input("--limit \(limit ?? 0) 让这一批变成空的")
    }

    // 复用模式不发任何请求，所以不受配额约束：它只是把 mine 当时抓到的 videoId 重新打包。
    // 用途是客户端联调（也能离线跑），代价是位置是**快照**，谁下播了它不知道。
    // **它也不写 live / verifiedAt**：快照没有结论，写了 App 就会当成"已确认在播"，
    // 而 App 对"没结论"与"结论过期"的处理是不同的。正式下发走下面那条完整路径。
    if reuse {
        let candidates: CandidateFile = try read("candidates.json")
        let byChannel = Dictionary(
            candidates.candidates.map { ($0.channelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var streams: [Stream] = []
        var missing: [String] = []
        for seed in seeds {
            guard let candidate = byChannel[seed.channelId] else {
                missing.append(seed.id)
                continue
            }
            streams.append(
                makeStream(
                    seed: seed,
                    videoId: candidate.videoId,
                    viewers: candidate.viewers,
                    thumbnail: candidate.thumbnail,
                    verifiedAt: nil
                )
            )
        }

        guard !streams.isEmpty else {
            throw ServiceError.input("candidates.json 里一条都匹配不上 channels-source.json 的 channelId")
        }

        try write(Feed(schema: 2, generatedAt: timestamp(), streams: streams), "live-youtube.json")
        print("复用 candidates.json 的 videoId（不发任何请求）：\(streams.count)/\(seeds.count) 条")
        if !missing.isEmpty {
            print("候选中没有、被跳过：\(missing.joined(separator: ", "))")
        }
        print("→ live-youtube.json（联调快照：不带 live/verifiedAt；正式数据不要带 --reuse）")
        return
    }

    // 配额是项目级的、**单日**上限，先算清再开工：跑到一半才配额耗尽会抛错、不写文件，最后
    // 表现为"任务成功、整天配额没了、什么也没产出"。这里算的是**最坏情况**（没有一条能复用、
    // 全部走满两级窗口），实际花多少由 `Meter` 在收尾时报出来。
    let ceiling = RefreshCost.ceiling(seeds.count)
    guard ceiling + RefreshCost.search <= Quota.perDay else {
        throw ServiceError.quota("这一批 \(seeds.count) 个频道最坏要 \(ceiling) units，加一次兜底 \(RefreshCost.search) 就超过每天 \(Quota.perDay)；用 --limit 分批")
    }

    print("刷新 \(seeds.count)/\(all.count) 个频道（最坏 \(ceiling) units，兜底 \(RefreshCost.search)/个，只花余量）…\n")

    var resolved: [String: VideosResponse.Item] = [:]
    var pending = seeds

    // L0：上一次发布的 videoId 还活着吗？活着就直接复用。
    //
    // 这一级同时省额度与"保证可用"：它不花窗口的钱（1 unit/50 个频道），而复用的是一条**已经
    // 服务过、被验证过可播**的流，比每天换一条没播放过的更稳。
    if let previous {
        // 读不到就当没有：L0 是纯节省，缺了不影响正确性（全部走窗口而已），更不该让整轮失败。
        let saved = (try? readPreviousVideoIDs(previous)) ?? [:]
        let remembered = seeds.compactMap { seed in saved[seed.id].map { (seed: seed, videoID: $0) } }

        if remembered.isEmpty {
            print("上一次的产物没读到可复用的条目（\(previous)），这一轮全部查窗口。")
        }

        if !remembered.isEmpty {
            let items = try await fetchDetails(ids: Array(Set(remembered.map(\.videoID))))
            let usable = Dictionary(
                items.filter { isPlayable($0) && isSettled($0) }.map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            for entry in remembered {
                if let item = usable[entry.videoID] { resolved[entry.seed.id] = item }
            }
            pending = seeds.filter { resolved[$0.id] == nil }
            print("L0 复用上一次仍在播的：\(resolved.count)/\(seeds.count) 条")
        }
    }

    // L1：上传窗口前 10 条。**在播那条不一定排第一**（实测 Lisbon / Tokyo 都在第 2 位），
    // 所以是"从窗口里挑一条在播的"，不是"取最新一条"。
    var windows: [String: [String]] = [:]
    var tokens: [String: String] = [:]
    var unreachable: [String] = []
    var transient: [String] = []
    var rejected: [String: ChannelOutcome] = [:]

    for seed in pending {
        do {
            let window = try await fetchWindow(
                playlist: uploadsPlaylist(seed.channelId),
                size: RefreshCost.windowFirst
            )
            windows[seed.id] = window.ids
            if let token = window.next { tokens[seed.id] = token }
            try await pause()
        } catch {
            // 只有"这个播放列表不存在"才是结构性的：404（不存在或私有）与 playlistNotFound。
            // 其余（超时、5xx、限流）是暂时性的——**不能拿一次网络抖动去动目录**。
            let reason = (error as? ServiceError)?.reason ?? "\(error)"
            if reason.hasSuffix("404") || reason.contains("NotFound") {
                unreachable.append(seed.id)
            } else {
                transient.append("\(seed.id):\(reason)")
            }
        }
    }

    var justStarted: [String] = []

    let first = try await resolveWindows(pending, windows: windows)
    resolved.merge(first.resolved) { current, _ in current }
    justStarted += first.justStarted
    rejected.merge(first.rejected) { current, _ in current }
    var unresolved = first.unresolved

    // L2：还没找到的，把同一个窗口翻到第 50 条。USGS 那类高频上传频道的直播就埋在更深处，
    // 而 `maxResults` 从 1 到 50 都是 1 unit——用 1 unit 换掉一次 100 units 的兜底。
    var wide: [String: [String]] = [:]
    for seed in unresolved {
        guard let token = tokens[seed.id],
              let page = try? await fetchWindow(
                  playlist: uploadsPlaylist(seed.channelId),
                  size: RefreshCost.windowWide - RefreshCost.windowFirst,
                  pageToken: token
              )
        else { continue }
        wide[seed.id] = page.ids
        try await pause()
    }

    let second = try await resolveWindows(unresolved, windows: wide)
    resolved.merge(second.resolved) { current, _ in current }
    justStarted += second.justStarted
    rejected.merge(second.rejected) { current, _ in current }
    unresolved = second.unresolved

    print("L0+L1+L2 找到在播：\(resolved.count)/\(seeds.count) 条（刚开播先不发 \(justStarted.count) 条，上传列表不可达 \(unreachable.count) 条，暂时性失败 \(transient.count) 条，待兜底 \(unresolved.count) 条）")

    // L3：兜底走 search.list。**不公开的直播不进上传列表**（实测 Manchester 就是这一类），
    // 对它们只有这条路。价格是窗口的 100 倍，所以只花余量，花完就停。
    // 兜底也吃"搜索调用"那个额度桶（一天 100 次）。按用户口径**刷新最多兜 30 次**——
    // 再多就把挖矿那天的额度吃掉了，而这两件事共用同一个桶。
    var remaining = Quota.perDay - (await Meter.shared.spent)
    var rescueBudget = Quota.searchReservedForRefresh
    var rescued = 0
    var skipped: [String] = []

    // **上传列表 404 的频道不再花 100 units 去搜**：频道没了，搜也是白搜（实测这类只有一种成因：
    // 频道注销或把上传列表藏了）。`unreachable` 的判定已经足够，直接进账本。
    let searchable = unresolved.filter { !unreachable.contains($0.id) }
    if searchable.count != unresolved.count {
        print("跳过兜底（上传列表不可达 \(unresolved.count - searchable.count) 条）")
    }

    for (index, seed) in searchable.enumerated() {
        guard RefreshCost.search <= remaining, rescueBudget > 0 else {
            skipped = searchable[index...].map(\.id)
            break
        }
        remaining -= RefreshCost.search
        rescueBudget -= 1

        let found = try await searchLive([
            URLQueryItem(name: "channelId", value: seed.channelId),
            URLQueryItem(name: "maxResults", value: "1")
        ])
        if let videoId = found.first?.id.videoId {
            // search 带了 videoEmbeddable=true，但清单是人维护的，仍然复查一遍三道校验。
            let check = try await fetchDetails(ids: [videoId])
            if let item = check.first(where: { isPlayable($0) && isSettled($0) }) {
                resolved[seed.id] = item
                rescued += 1
            } else if let item = check.first, let outcome = rejection(item) {
                // 在播、但被拒：这条要记进清理账本（"所有者关了嵌入"与"今天没开播"不是一回事）。
                rejected[seed.id] = outcome
            }
        }
        try await pause()
    }

    print("L3 兜底补回：\(rescued) 条；这次没兜底：\(skipped.count) 条（上限 \(Quota.searchReservedForRefresh) 次搜索调用）")
    if !skipped.isEmpty {
        print("  \(skipped.joined(separator: ", "))")
    }

    // 清理账本：单次刷新答不了"这个频道还能不能播"，只知道"此刻在不在播"，所以账要跨天记。
    // 它写在产物之前——**一份空产物不该把账本也一起吞掉**。
    let ledger = try updateState(
        previous: state,
        seeds: seeds,
        resolved: Set(resolved.keys),
        startingUp: Set(justStarted),
        rejected: rejected,
        unreachable: Set(unreachable),
        checkedAt: timestamp()
    )
    try write(ledger, "refresh-state.json")

    let prunable = ledger.prunable
    print("清理账本 → refresh-state.json：观察中 \(ledger.channels.count) 条，已达阈值 \(prunable.count) 条"
        + (prunable.isEmpty ? "" : "（跑 `prune` 处理，0 units）"))
    if !transient.isEmpty {
        print("暂时性失败（不计入账本）：\(transient.joined(separator: ", "))")
    }

    // 写进产物的每一条都是这一刻确认在播的，所以共用同一个时间戳；`live` 由 `makeStream` 跟着它走。
    let verifiedAt = timestamp()
    let streams: [Stream] = seeds.compactMap { seed in
        resolved[seed.id].map { item in
            makeStream(
                seed: seed,
                videoId: item.id,
                viewers: liveViewers(item),
                thumbnail: bestThumbnail(item),
                verifiedAt: verifiedAt
            )
        }
    }

    // **守卫落在产物上，不落在中间那个字典上**（2026-10-14 实测踩到）：两者键不一致时
    // `resolved` 有值、组装出来却是 0 条，写出去就是一份空目录。宁可什么都不写，让上一次的
    // 数据继续服务。
    guard !streams.isEmpty else {
        print("\n没有任何频道在直播，不覆盖上一次的产物。")
        return
    }

    // 只有一路走到底才落盘。中途失败就让上一次的产物留着，
    // 否则一次配额打满会把 App 的目录清空。
    try write(Feed(schema: 2, generatedAt: verifiedAt, streams: streams), "live-youtube.json")
    print("\n产出 \(streams.count) 条 → live-youtube.json（live=true，verifiedAt=\(verifiedAt)）")
}

// MARK: - enrich

func enrich() async throws {
    let file: CandidateFile = try read("candidates.json")
    let channelIds = Array(Set(file.candidates.map(\.channelId)))
    let countries = try await fetchChannelCountries(ids: channelIds)

    // 静帧要单独补一趟：候选池是分批挖的，早先那几批写盘时还没记这一项。
    let details = try await fetchDetails(ids: file.candidates.map(\.videoId))
    let thumbnails = Dictionary(
        details.compactMap { item in bestThumbnail(item).map { (item.id, $0) } },
        uniquingKeysWith: { first, _ in first }
    )

    var candidates = file.candidates
    for index in candidates.indices {
        candidates[index].channelCountry = countries[candidates[index].channelId]
        if let url = thumbnails[candidates[index].videoId] {
            candidates[index].thumbnail = url
        }
    }

    // 关键词记账要带走：丢了它，下一次 mine 会把所有关键词重跑一遍（每条 100 units）。
    try write(
        CandidateFile(generatedAt: timestamp(), candidates: candidates, minedQueries: file.minedQueries),
        "candidates.json"
    )

    let labeled = candidates.filter { $0.channelCountry != nil }.count
    let pictured = candidates.filter { $0.thumbnail != nil }.count
    print("补完频道国家：\(labeled)/\(candidates.count) 条有标注（其余频道没有公开这一项）")
    print("补完卡片静帧：\(pictured)/\(candidates.count) 条")
    printGrouped(candidates)
}

// MARK: - promote

/// id 里只留 ASCII：它会被 App 的观看历史当键用，混进中日韩字符只会让排查变难。
/// 名字全是非 ASCII 的频道会返回空串，调用方要负责兜底。
func slug(_ text: String) -> String {
    let mapped = text.lowercased().map { character -> Character in
        character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
    }
    return String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
}

func promote() throws {
    let file: CandidateFile = try read("candidates.json")
    let overrides: [String: SeedOverride] = (try? read("seeds-overrides.json")) ?? [:]

    let known = Set(file.candidates.map(\.channelId))
    let unknown = Set(overrides.keys).subtracting(known)
    guard unknown.isEmpty else {
        throw ServiceError.input("seeds-overrides.json 里有 \(unknown.count) 个 channelId 不在候选池里：\(unknown.sorted().joined(separator: ", "))")
    }

    var seeds: [Seed] = []
    var usedIds: Set<String> = []
    var skipped: [String] = []
    var fallbackIds: [String] = []

    for candidate in file.candidates {
        // 没有国家就不发出去。App 按国家分组、地图也按国家落点，
        // 缺这一项的产品行为不对；宁可留一条待办，也不填一个猜的值。
        guard let country = candidate.channelCountry, !country.isEmpty else {
            skipped.append(candidate.channelTitle)
            continue
        }

        let override = overrides[candidate.channelId]
        // YouTube 偶尔会带出首尾空格，直接进 name 与 source 会跟着露到界面上。
        let channelTitle = candidate.channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // id 跟着成品名走：中文频道名 slug 出来是空的，人工编辑层补了英文名之后才有意义。
        let base = "yt-" + slug(override?.name ?? channelTitle)
        var id = base.count > 3 ? base : "yt-\(candidate.channelId)"
        if id == "yt-\(candidate.channelId)" {
            fallbackIds.append(candidate.channelTitle)
        }
        var suffix = 2
        while usedIds.contains(id) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        usedIds.insert(id)

        seeds.append(Seed(
            id: id,
            channelId: candidate.channelId,
            name: override?.name ?? channelTitle,
            country: country,
            city: override?.city,
            coordinate: override?.coordinate,
            category: override?.category ?? candidate.category,
            isLandmark: override?.isLandmark ?? false,
            source: "YouTube · \(channelTitle)"
        ))
    }

    // 一份空目录比一份旧目录糟得多：它是**唯一**的策展清单，写空了 App 就没有东西可发。
    // 走到这里说明候选池里没有一条带国家的条目，那不是"该清空"，而是上游出了问题。
    guard !seeds.isEmpty else {
        throw ServiceError.input("promote 会产出一份空目录（候选池里没有带国家的条目），已放弃写入")
    }

    try write(seeds, "channels-source.json")

    print("产出 channels-source.json：\(seeds.count) 条")
    print("按国家：\(Dictionary(grouping: seeds, by: \.country).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "  "))")
    print("地点名还是频道名（等你编辑）：\(seeds.filter { overrides[$0.channelId]?.name == nil }.count) 条")
    print("id 退化成频道 id（名字里没有 ASCII）：\(fallbackIds.count) 条 \(fallbackIds)")
    print("因缺国家而跳过：\(skipped.count) 条 \(skipped)")
    print("坐标已填：\(seeds.filter { $0.coordinate != nil }.count) 条（按既有口径，不查证就不填）")
}

// MARK: - curate

func curate() async throws {
    let file: CandidateFile = try read("candidates.json")
    let curation: Curation = try read("curation.json")

    // 国家更正指向一个不存在的频道，一定是抄错了——拦住。
    // 但"找不到"有两种是合法的：上一轮就已经剔掉的，以及**本轮 exclude 掉的**——一个人先把
    // 频道改对国家、后来才决定不要它，是完全正常的顺序。2026-10-14 修：原先只容忍前者，
    // 于是"排除一个改过国家的频道"会让 curate 从此永远失败（它是就地过滤，必须能重复跑）。
    let known = Set(file.candidates.map(\.channelId))
    let unknownCountry = Set(curation.country.keys)
        .subtracting(known)
        .subtracting(curation.exclude.keys)
    guard unknownCountry.isEmpty else {
        throw ServiceError.input("curation.json 的 country 里有 \(unknownCountry.count) 个 channelId 既不在候选池、也不在剔除清单里：\(unknownCountry.sorted().joined(separator: ", "))")
    }
    let alreadyRemoved = Set(curation.exclude.keys).subtracting(known).count

    var kept: [Candidate] = []
    var excluded: [(channel: String, reason: String)] = []

    for var candidate in file.candidates {
        if let reason = curation.exclude[candidate.channelId] {
            excluded.append((candidate.channelTitle, reason))
            continue
        }
        if let country = curation.country[candidate.channelId] {
            candidate.channelCountry = country
        }
        kept.append(candidate)
    }

    // 同上：关键词记账不能在这里丢。
    try write(
        CandidateFile(generatedAt: timestamp(), candidates: kept, minedQueries: file.minedQueries),
        "candidates.json"
    )

    print("剔除 \(excluded.count) 条（另有 \(alreadyRemoved) 条已在此前的轮次移除）：\n")
    for entry in excluded.sorted(by: { $0.reason < $1.reason }) {
        print("  \(entry.reason)")
        print("    \(entry.channel)")
    }

    print("\n保留 \(kept.count) 条（其中 \(curation.country.count) 条国家由人工更正/补全）")
    printGrouped(kept)
}

// MARK: - prune

/// 应用清理账本：把**连续**拿不到可播的流的频道从目录里删掉（用户口径：不能播放的资源就删掉，
/// 保证目录里的都是能播的）。
///
/// 删的方式是写进 `curation.json` 的 `exclude`，再跑一遍 `curate` + `promote`。不能直接改
/// `channels-source.json`——那是 `promote` 的产物，下一次就会被覆盖；而进了 `exclude` 之后，
/// 这些频道就算日后又被挖回候选池，也不会再进目录。整个命令 **0 units**。
///
/// `--misses N` 可以临时收紧/放宽阈值；`--dry-run` 只打印不落盘。
func prune(misses: Int?, dryRun: Bool) async throws {
    let state: RefreshState = try read("refresh-state.json")
    let curation: Curation = try read("curation.json")
    let seeds: [Seed] = try read("channels-source.json")
    let nameByChannel = Dictionary(
        seeds.map { ($0.channelId, $0.name) },
        uniquingKeysWith: { first, _ in first }
    )

    var pending: [(channelID: String, reason: String)] = []

    for entry in state.prunable {
        // 已经排除过的不再重复——`promote` 会校验 exclude 的写法不重要，但重复条目是噪声。
        guard curation.exclude[entry.channelID] == nil else { continue }

        let threshold = misses ?? PrunePolicy.threshold(entry.entry.outcome) ?? .max
        guard entry.entry.misses >= threshold else { continue }

        let name = nameByChannel[entry.channelID] ?? entry.channelID
        pending.append((
            entry.channelID,
            "刷新清理（连续 \(entry.entry.misses) 次 \(entry.entry.outcome.rawValue)：\(entry.entry.note ?? "")）——\(name)"
        ))
    }

    guard !pending.isEmpty else {
        print("清理账本里有 \(state.channels.count) 条在观察，没有达到阈值的。")
        return
    }

    print("\(dryRun ? "（dry-run）" : "")将清理 \(pending.count) 条：")
    for entry in pending {
        print("  \(entry.channelID)  \(entry.reason)")
    }

    guard !dryRun else { return }

    try appendExclusions(pending)
    print("\n已写进 curation.json 的 exclude，接着重跑 curate + promote（都不花配额）…\n")

    try await curate()
    try promote()
}

/// 往 `curation.json` 的 `exclude` 里追加条目。
///
/// 那个文件是**人维护的**：分组空行与条目顺序都是可读性的一部分，用 `JSONEncoder` 整个重写会把
/// 它们一起抹掉。所以这里做的是文本插入，而且**先验证结果能解析再落盘**——锚点找不到、或者拼出来
/// 的 JSON 读不回来，就直接报错，绝不在一个不确定的文本上乱改。
func appendExclusions(_ entries: [(channelID: String, reason: String)]) throws {
    let url = repoRoot().appending(path: "curation.json")
    let text = try String(contentsOf: url, encoding: .utf8)

    guard let excludeStart = text.range(of: "\"exclude\"") else {
        throw ServiceError.input("curation.json 里找不到 exclude 块")
    }

    // exclude 块之后最后一个 `\n  },` 就是它的收尾（country 是最后一个块，收尾不带逗号）。
    let tail = text[excludeStart.upperBound...]
    guard let closing = tail.range(of: "\n  },", options: .backwards) else {
        throw ServiceError.input("curation.json 的 exclude 块找不到收尾，格式变了？")
    }

    let head = String(text[text.startIndex..<closing.lowerBound])
    let rest = String(text[closing.lowerBound...])

    let body = head.hasSuffix(",") || head.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(",")
        ? head
        : head + ","
    let lines = entries.map { "    \(quoted($0.channelID)): \(quoted($0.reason))" }
    let block = "\n\n" + lines.joined(separator: ",\n")
    let merged = body + block + (rest.hasPrefix("\n") ? rest : "\n" + rest)

    // 落盘前先确认它仍是一份能解的 curation.json。
    guard let data = merged.data(using: .utf8), (try? JSONDecoder().decode(Curation.self, from: data)) != nil else {
        throw ServiceError.input("拼接后的 curation.json 解不回来，已放弃写入（原文件未动）")
    }

    try data.write(to: url)
}

/// JSON 字符串字面量（条目里带引号或反斜杠时不能直接把文本塞进去）。
private func quoted(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

// MARK: - mine

func mine(limit: Int?, offset: Int, force: Bool) async throws {
    let all: [Query] = try read("keywords.json")
    let existing: CandidateFile? = try? read("candidates.json")

    // **挖过的关键词不重复挖**：一条关键词就是 100 units，重复跑一遍等于白烧。记账写在
    // candidates.json 自己身上（`minedQueries`），所以不需要额外文件，也不会被别的子命令丢掉。
    let mined = Set(existing?.minedQueries ?? [])

    let start = min(offset, all.count)
    let end = limit.map { min(start + $0, all.count) } ?? all.count
    let slice = Array(all[start..<end]).filter { force || !mined.contains($0.q) }

    let skippedKnown = Array(all[start..<end]).count - slice.count
    guard !slice.isEmpty else {
        print("这一段里的 \(skippedKnown) 个关键词都挖过了，没有要跑的。要重跑加 --force。")
        return
    }

    // 一条关键词 = 一次 `search.list`（一次最多 50 条，不翻页）。
    // **搜索的额度是"100 次调用/天"**，而刷新的 L3 兜底也吃同一个桶——按用户口径给刷新
    // **预留 30 次**，所以挖矿一批最多 70 次。
    let calls = slice.count
    let budget = Quota.searchCallsPerDay - Quota.searchReservedForRefresh
    guard calls <= budget else {
        throw ServiceError.quota("这一批 \(calls) 次搜索调用，超过挖矿预算 \(budget)（日上限 \(Quota.searchCallsPerDay)，其中 \(Quota.searchReservedForRefresh) 次留给刷新的 L3 兜底）；用 --limit 分批跑")
    }

    print("挖掘 \(slice.count)/\(all.count) 个关键词（\(calls) 次搜索调用；日上限 \(Quota.searchCallsPerDay)，其中 \(Quota.searchReservedForRefresh) 留给刷新、挖矿可用 \(budget)；跳过已挖过的 \(skippedKnown) 个）…\n")

    // 已有候选按频道合并，所以分两天跑不会互相覆盖。
    var byChannel = Dictionary(
        (existing?.candidates ?? []).map { ($0.channelId, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    var minedQueries = existing?.minedQueries ?? []

    for (index, query) in slice.enumerated() {
        // **不加 `relevanceLanguage`**（2026-10-14 用户口径：去掉英文标题优先）。实测在
        // `city live cam` 上它没有任何影响——那条查询的全集只有 33 条（< maxResults=50），
        // 参数只改变排序、不改变集合；但它是"预设英文"这道偏置，对全集超过 50 的长尾查询会真的
        // 把非英文标题的结果挤出去。**搜索范围本来就是全球的**（不带 `regionCode`），要覆盖更多
        // 国家靠的是关键词换语区（见 keywords.json 的语区那几条），不是靠这个参数。
        //
        // 排序仍是 `order=viewCount`：实测 `order=date` 在同样的查询上返回**完全一样**的集合，
        // 换排序换不来新资源。`type=video` + `eventType=live` + `videoEmbeddable=true` 见
        // `searchLive`。
        //
        // **不用 pageToken 翻页**（2026-10-14 用户口径：不用翻页查询，恢复官方上限）。
        // 一次 `search.list` 最多 50 条（`maxResults` 的官方上限就是 50），想要 ~100 条只能翻
        // 第二页，而那是**第二次搜索调用**。搜索的额度是"100 次调用/天"（自己的配额桶），
        // 一页换一个新语区比翻页划算得多——实测翻页也不是随处可用：`cámara en vivo` 报
        // total≈194 却只回 42 条、**没有**下一页；`live cam` 报 total≈1563、回 44 条、有下一页。
        // （`pageInfo.totalResults` 是近似值，官文写明别拿它当翻页依据——能不能翻只认
        // `nextPageToken`。这条实测留在注释里，代码不再用。）
        let items = try await searchLive([
            URLQueryItem(name: "q", value: query.q),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "order", value: "viewCount")
        ])

        var added = 0
        for item in items {
            guard let videoId = item.id.videoId else { continue }
            guard byChannel[item.snippet.channelId] == nil else { continue }
            byChannel[item.snippet.channelId] = Candidate(
                query: query.q,
                category: query.category,
                channelId: item.snippet.channelId,
                channelTitle: item.snippet.channelTitle,
                videoId: videoId,
                title: item.snippet.title,
                viewers: nil,
                thumbnail: nil,
                channelCountry: nil
            )
            added += 1
        }

        let position = offset + index + 1
        print("[\(position)/\(all.count)] \(query.q.padding(toLength: 30, withPad: " ", startingAt: 0)) 回 \(items.count) 条，新 \(added) 个频道")

        // 每轮落一次盘：配额是真花掉了，中途挂掉不该连已经挖到的也一起丢。
        // 关键词也在这里记账——它同样"已经花掉了"，重跑一次是浪费。`--force` 复跑不加第二遍。
        if !minedQueries.contains(query.q) { minedQueries.append(query.q) }
        try write(
            CandidateFile(generatedAt: timestamp(), candidates: Array(byChannel.values), minedQueries: minedQueries),
            "candidates.json"
        )
        try await pause()
    }

    // 复核一遍池子，**只更新、不删除**。
    //
    // 2026-10-14 修：原先这里做的是"把此刻不在播的候选整条丢掉"，而池子里绝大多数条目是几天前
    // 抓的（直播一换场 videoId 就作废），于是每次 `mine` 都会清掉一大半——更糟的是那些**已经被
    // 人工策展进 `channels-source.json` 的条目也在里面**，下一次 `promote` 目录就跟着缩水。
    // 池子的"减"只能由人工 `curate` 做：机器负责把新挖的加进来、把还在播的刷新一下。
    let details = try await fetchDetails(ids: byChannel.values.map(\.videoId))
    let liveByVideoId = Dictionary(
        details.filter(isPlayable).map { ($0.id, $0) },
        uniquingKeysWith: { a, _ in a }
    )

    var kept: [Candidate] = byChannel.values.map { candidate in
        guard let item = liveByVideoId[candidate.videoId] else { return candidate }
        var copy = candidate
        copy.viewers = liveViewers(item)
        copy.thumbnail = bestThumbnail(item)
        return copy
    }

    // 国家是**分类**，不是搜索条件（用户口径：不要用城市/国家当关键词，只给搜出来的资源按国家
    // 城市归类）。所以这里只用两种来源：频道自报的 `snippet.country`，以及**保留原有的**；
    // 查不到就算了，不拦候选——`curation.json` 的 `country` 表可以人工补。
    let countries = try await fetchChannelCountries(ids: kept.map(\.channelId))
    for index in kept.indices {
        kept[index].channelCountry = countries[kept[index].channelId]
            ?? kept[index].channelCountry
    }

    // 此刻在播的排前面：池子是给人筛的，先看还活着的。
    kept.sort { ($0.viewers ?? 0) > ($1.viewers ?? 0) }
    try write(
        CandidateFile(generatedAt: timestamp(), candidates: kept, minedQueries: minedQueries),
        "candidates.json"
    )

    let labeled = kept.filter { $0.channelCountry != nil }.count
    let liveNow = kept.filter { liveByVideoId[$0.videoId] != nil }.count
    print("\n候选 \(kept.count) 条（其中 \(liveNow) 条此刻在播）→ candidates.json")
    print("池子只增不减：剔除走人工 curate，机器不会因为此刻没在播就丢条目")
    print("其中 \(labeled) 条带国家（频道自报 或 关键词城市兜底；镜头所在地要人工确认）")
    print("已记账的关键词：\(minedQueries.count) 个（重跑会自动跳过）")
    printGrouped(kept)
}

// MARK: - 入口

func option(_ arguments: [String], _ name: String) -> Int? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return Int(arguments[arguments.index(after: index)])
}

func value(_ arguments: [String], _ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[arguments.index(after: index)]
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first, !command.hasPrefix("--") else {
    print("""
    用法：swift Scripts/youtube.swift <mine|enrich|curate|promote|refresh> [选项]

      mine    [--limit N] [--offset N] [--force]
              按 keywords.json 挖掘候选。**已经挖过的关键词默认跳过**（--force 强制重跑），
              所以补挖只花新关键词的钱。
      enrich  补频道国家与卡片静帧（1 unit / 50 个频道）。
      curate  应用人工筛选，不花配额、可重复跑。
      promote 生成 channels-source.json，不花配额。
      prune   [--misses N] [--dry-run]
              应用清理账本：把**连续**拿不到可播的流的频道从目录里删掉（写进 curation.json 的
              exclude，再跑 curate + promote）。阈值分级，见 PrunePolicy。0 units。
      refresh [--limit N] [--reuse] [--previous FILE] [--state FILE]
              产出 live-youtube.json + refresh-state.json（清理账本）。--previous 传上一次的产物：
              里面仍在播的条目会被直接复用，省掉查窗口的钱（见 RefreshCost 的阶梯）。
              --state 传上一次的账本，用来累计"连续几次没拿到可播的流"。
    """)
    exit(2)
}

do {
    switch command {
    case "mine":
        try await mine(
            limit: option(arguments, "--limit"),
            offset: option(arguments, "--offset") ?? 0,
            force: arguments.contains("--force")
        )
    case "enrich":
        try await enrich()
    case "curate":
        try await curate()
    case "promote":
        try promote()
    case "prune":
        try await prune(misses: option(arguments, "--misses"), dryRun: arguments.contains("--dry-run"))
    case "refresh":
        try await refresh(
            limit: option(arguments, "--limit"),
            reuse: arguments.contains("--reuse"),
            previous: value(arguments, "--previous"),
            state: value(arguments, "--state")
        )
    default:
        print("未知子命令：\(command)")
        exit(2)
    }

    // 额度是这次运行最该被看见的数字，放在最后一行打印——成功才打，失败时已经有一行报错。
    await Meter.shared.report()
} catch {
    FileHandle.standardError.write(Data("失败——\(error.localizedDescription)\n".utf8))
    exit(1)
}
