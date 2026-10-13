#!/usr/bin/env swift
//
// GlobeShot 直播目录服务。
//
// 子命令：
//   mine [--limit N] [--offset N]  按 keywords.json 批量挖掘候选，合并进 candidates.json
//   enrich                         给已有的 candidates.json 补频道国家（分国家归拢用）
//   refresh                        读 channels-source.json，产出 live-youtube.json
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
    /// 频道自报的国家（`channels.list` 的 `snippet.country`）。是**提示**不是事实：
    /// 频道注册地不一定是镜头所在地。人工筛的时候用它归拢，不要直接当数据用。
    var channelCountry: String?
}

struct CandidateFile: Codable, Sendable {
    var generatedAt: String
    var candidates: [Candidate]
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
/// 所以：改这里之前先看 `LiveChannel`；能推出来的东西（videoId、缩略图地址）不重复携带，
/// App 从 `url` 里取。
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
        struct Snippet: Decodable { let liveBroadcastContent: String }
        struct Status: Decodable { let embeddable: Bool? }
        struct ContentDetails: Decodable {
            struct RegionRestriction: Decodable {
                let allowed: [String]?
                let blocked: [String]?
            }
            let regionRestriction: RegionRestriction?
        }
        struct LiveStreamingDetails: Decodable { let concurrentViewers: String? }

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

// MARK: - 请求

func call<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem]) async throws -> T {
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

    return try JSONDecoder().decode(T.self, from: data)
}

func searchLive(_ extra: [URLQueryItem]) async throws -> [SearchResponse.Item] {
    let response = try await call(SearchResponse.self, path: "search", query: extra + [
        URLQueryItem(name: "part", value: "snippet"),
        URLQueryItem(name: "eventType", value: "live"),
        URLQueryItem(name: "type", value: "video"),
        // 只取允许嵌入的。漏了这个参数会拿到一批所有者关闭了嵌入的频道，
        // 播放器一律报 152，看起来像"YouTube 嵌入不可用"，其实是筛错了。
        URLQueryItem(name: "videoEmbeddable", value: "true")
    ])
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

func liveViewers(_ item: VideosResponse.Item) -> Int? {
    item.liveStreamingDetails?.concurrentViewers.flatMap(Int.init)
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
func makeStream(seed: Seed, videoId: String, viewers: Int?) -> Stream {
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
        viewers: viewers
    )
}

func refresh(limit: Int?, reuse: Bool) async throws {
    let all: [Seed] = try read("channels-source.json")
    guard !all.isEmpty else {
        throw ServiceError.input("channels-source.json 是空的，先跑 mine 再人工筛一遍")
    }

    let seeds = limit.map { Array(all.prefix($0)) } ?? all
    guard !seeds.isEmpty else {
        throw ServiceError.input("--limit \(limit ?? 0) 让这一批变成空的")
    }

    // 复用模式不发搜索请求，所以不受配额约束：它只是把 mine 当时抓到的 videoId 重新打包。
    // 用途是客户端联调（也能离线跑），代价是位置是**快照**，谁下播了它不知道。
    // 正式下发走下面那条完整路径。
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
            streams.append(makeStream(seed: seed, videoId: candidate.videoId, viewers: candidate.viewers))
        }

        guard !streams.isEmpty else {
            throw ServiceError.input("candidates.json 里一条都匹配不上 channels-source.json 的 channelId")
        }

        try write(Feed(schema: 1, generatedAt: timestamp(), streams: streams), "live-youtube.json")
        print("复用 candidates.json 的 videoId（不发任何请求）：\(streams.count)/\(seeds.count) 条")
        if !missing.isEmpty {
            print("候选中没有、被跳过：\(missing.joined(separator: ", "))")
        }
        print("→ live-youtube.json（联调快照；正式数据不要带 --reuse）")
        return
    }

    // 配额是项目级的，而且是**单日**上限。一次 refresh 会把这一批频道的搜索全部花在同一天，
    // 所以约束落在"这一批有多少个频道"上——隔天刷一次并不会让单次变便宜，这里不能按平均每天算。
    //
    // 超了就直接拒绝，不要跑一半：跑到配额耗尽会抛错、不写文件，而 workflow 的推送步骤看到
    // 文件不存在就跳过，最后表现为"任务成功、整天配额没了、什么也没产出"。
    let searchLimit = Quota.perDay / Quota.perSearch
    guard seeds.count <= searchLimit else {
        throw ServiceError.quota("这一批 \(seeds.count) 个频道要 \(seeds.count * Quota.perSearch) units，超过每天 \(Quota.perDay)；一次最多 \(searchLimit) 个。用 --limit 分批，或把 channels-source.json 收窄")
    }

    print("刷新 \(seeds.count)/\(all.count) 个频道…\n")

    var liveByChannel: [String: String] = [:]
    for seed in seeds {
        let items = try await searchLive([
            URLQueryItem(name: "channelId", value: seed.channelId),
            URLQueryItem(name: "maxResults", value: "1")
        ])
        if let videoId = items.first?.id.videoId {
            liveByChannel[seed.channelId] = videoId
            print("✅ \(seed.id.padding(toLength: 36, withPad: " ", startingAt: 0)) \(videoId)")
        } else {
            print("·  \(seed.id.padding(toLength: 36, withPad: " ", startingAt: 0)) 此刻没在直播")
        }
        try await pause()
    }

    guard !liveByChannel.isEmpty else {
        print("\n没有任何频道在直播，不覆盖上一次的产物。")
        return
    }

    let details = try await fetchDetails(ids: Array(liveByChannel.values))
    let playable = details.filter(isPlayable)
    let dropped = details.count - playable.count
    if dropped > 0 {
        print("\n剔除 \(dropped) 条：已下播 / 关闭了嵌入 / 被参照市场屏蔽。")
    }

    let byVideoId = Dictionary(playable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var streams: [Stream] = []
    for seed in seeds {
        guard let videoId = liveByChannel[seed.channelId], let item = byVideoId[videoId] else { continue }
        streams.append(makeStream(seed: seed, videoId: videoId, viewers: liveViewers(item)))
    }

    // 只有一路走到底才落盘。中途失败就让上一次的产物留着，
    // 否则一次配额打满会把 App 的目录清空。
    try write(Feed(schema: 1, generatedAt: timestamp(), streams: streams), "live-youtube.json")
    print("\n产出 \(streams.count) 条 → live-youtube.json")
}

// MARK: - enrich

func enrich() async throws {
    let file: CandidateFile = try read("candidates.json")
    let channelIds = Array(Set(file.candidates.map(\.channelId)))
    let countries = try await fetchChannelCountries(ids: channelIds)

    var candidates = file.candidates
    for index in candidates.indices {
        candidates[index].channelCountry = countries[candidates[index].channelId]
    }

    try write(CandidateFile(generatedAt: timestamp(), candidates: candidates), "candidates.json")

    let labeled = candidates.filter { $0.channelCountry != nil }.count
    print("补完频道国家：\(labeled)/\(candidates.count) 条有标注（其余频道没有公开这一项）")
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
    // 剔除清单里"找不到"却可能是上一轮就已经剔掉的，所以那一种只计数、不报错：
    // 这个命令是就地过滤，必须能重复跑。
    let known = Set(file.candidates.map(\.channelId))
    let unknownCountry = Set(curation.country.keys).subtracting(known)
    guard unknownCountry.isEmpty else {
        throw ServiceError.input("curation.json 的 country 里有 \(unknownCountry.count) 个 channelId 不在候选池里：\(unknownCountry.sorted().joined(separator: ", "))")
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

    try write(CandidateFile(generatedAt: timestamp(), candidates: kept), "candidates.json")

    print("剔除 \(excluded.count) 条（另有 \(alreadyRemoved) 条已在此前的轮次移除）：\n")
    for entry in excluded.sorted(by: { $0.reason < $1.reason }) {
        print("  \(entry.reason)")
        print("    \(entry.channel)")
    }

    print("\n保留 \(kept.count) 条（其中 \(curation.country.count) 条国家由人工更正/补全）")
    printGrouped(kept)
}

// MARK: - mine

func mine(limit: Int?, offset: Int) async throws {
    let all: [Query] = try read("keywords.json")

    let start = min(offset, all.count)
    let end = limit.map { min(start + $0, all.count) } ?? all.count
    let slice = Array(all[start..<end])
    guard !slice.isEmpty else {
        throw ServiceError.input("keywords.json 只有 \(all.count) 条，offset \(offset) 之后没有可跑的")
    }

    let cost = slice.count * Quota.perSearch
    guard cost <= Quota.perDay else {
        throw ServiceError.quota("\(slice.count) 个关键词要 \(cost) units，超过每天 \(Quota.perDay)；用 --limit 分批跑")
    }

    print("挖掘 \(slice.count)/\(all.count) 个关键词（预算 \(cost) units）…\n")
    if cost > Quota.perDay / 2 {
        print("提示：这一轮用掉一半以上配额，建议分两天跑。\n")
    }

    // 已有候选按频道合并，所以分两天跑不会互相覆盖。
    var byChannel = Dictionary(
        ((try? read("candidates.json") as CandidateFile)?.candidates ?? []).map { ($0.channelId, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    for (index, query) in slice.enumerated() {
        let items = try await searchLive([
            URLQueryItem(name: "q", value: query.q),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "order", value: "viewCount"),
            URLQueryItem(name: "relevanceLanguage", value: "en")
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
                channelCountry: nil
            )
            added += 1
        }

        let position = offset + index + 1
        print("[\(position)/\(all.count)] \(query.q.padding(toLength: 30, withPad: " ", startingAt: 0)) 回 \(items.count) 条，新 \(added) 个频道")

        // 每轮落一次盘：配额是真花掉了，中途挂掉不该连已经挖到的也一起丢。
        try write(CandidateFile(generatedAt: timestamp(), candidates: Array(byChannel.values)), "candidates.json")
        try await pause()
    }

    // 补真实观众数，顺手把不可嵌入 / 被屏蔽 / 已下播的剔掉，
    // 交出去的就是已经过完三道校验的候选。
    let details = try await fetchDetails(ids: byChannel.values.map(\.videoId))
    var viewersByVideoId: [String: Int?] = [:]
    for item in details where isPlayable(item) {
        viewersByVideoId[item.id] = liveViewers(item)
    }

    var kept: [Candidate] = byChannel.values.compactMap { candidate -> Candidate? in
        guard viewersByVideoId.keys.contains(candidate.videoId) else { return nil }
        var copy = candidate
        copy.viewers = viewersByVideoId[candidate.videoId] ?? nil
        return copy
    }

    // 国家只是提示，查不到就算了，不拦候选。
    let countries = try await fetchChannelCountries(ids: kept.map(\.channelId))
    for index in kept.indices {
        kept[index].channelCountry = countries[kept[index].channelId]
    }

    kept.sort { ($0.viewers ?? 0) > ($1.viewers ?? 0) }
    try write(CandidateFile(generatedAt: timestamp(), candidates: kept), "candidates.json")

    let labeled = kept.filter { $0.channelCountry != nil }.count
    print("\n候选 \(kept.count) 条（已剔除不可嵌入 / 被屏蔽 / 已下播）→ candidates.json")
    print("其中 \(labeled) 条带频道自报国家（只是提示，镜头所在地要人工确认）")
    printGrouped(kept)
}

// MARK: - 入口

func option(_ arguments: [String], _ name: String) -> Int? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return Int(arguments[arguments.index(after: index)])
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first, !command.hasPrefix("--") else {
    print("用法：swift Scripts/youtube.swift <mine|enrich|curate|promote|refresh> [--limit N] [--offset N] [--reuse]")
    exit(2)
}

do {
    switch command {
    case "mine":
        try await mine(limit: option(arguments, "--limit"), offset: option(arguments, "--offset") ?? 0)
    case "enrich":
        try await enrich()
    case "curate":
        try await curate()
    case "promote":
        try promote()
    case "refresh":
        try await refresh(limit: option(arguments, "--limit"), reuse: arguments.contains("--reuse"))
    default:
        print("未知子命令：\(command)")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("失败——\(error.localizedDescription)\n".utf8))
    exit(1)
}
