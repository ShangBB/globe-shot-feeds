# globe-shot-feeds

GlobeShot App 的直播目录服务。把人工策展的 YouTube 频道变成 App 可读的 `live-youtube.json`。

**这个仓库里没有一行 App 代码**，App 只是最后一个消费者。它匿名 GET 一个静态 JSON，两个仓库之间只有这一份契约。

## 为什么需要它

三个约束逼出了这个形态：

1. **配额是项目级的**。YouTube Data API v3 的 10,000 units/天绑在 Google Cloud 项目上，**全体用户共享**，不是按用户算。`search.list` 一次就要 100 units → 全 App 一天只有 100 次搜索。客户端直连不可能撑住，必须服务端集中缓存、按"频道维度"摊销（目录对所有人是同一份）。
2. **密钥不能进 App 包**。ToS 要求保护 API Key。
3. **产物必然是公开的**。App 是匿名 GET，带不了凭证。所以真正要保护的只有"源"（策展清单与脚本）——而这个仓库里没有 App 代码，公开它不等于公开项目。

## 怎么跑

`YT_API_KEY` 只走环境变量，脚本与产物里都不落。

```bash
# 一次性：按 keywords.json 批量挖掘候选（结果写 candidates.json）
YT_API_KEY=xxx swift Scripts/youtube.swift mine

# 配额吃紧就分批跑，结果会按频道合并，不会互相覆盖
YT_API_KEY=xxx swift Scripts/youtube.swift mine --limit 40
YT_API_KEY=xxx swift Scripts/youtube.swift mine --offset 40

# 给候选补频道自报国家（按国家归拢用）。每 50 个频道 1 unit
YT_API_KEY=xxx swift Scripts/youtube.swift enrich

# 应用人工筛选：剔除该排除的、改对明显错的国家。不调 API，不花配额
swift Scripts/youtube.swift curate

# 把筛过的候选变成 channels-source.json（id / name / source 机械生成，人工层来自 seeds-overrides.json）
swift Scripts/youtube.swift promote

# 日常：读 channels-source.json，产出 live-youtube.json
YT_API_KEY=xxx swift Scripts/youtube.swift refresh
```

`curate` 与 `promote` 都不调 API、不花配额，改完随时重跑。

退出码非 0 表示失败。两种情况是**故意不写产物**的：任何 API 调用失败（尤其 403 `quotaExceeded`），以及一个频道都没在直播。前者是为了不让一次配额打满把 App 的目录清空，让上一次的数据继续服务。

## 配额账

```
channels-source.json 里的频道数 ≤ 100
```

注意这是**单次**的约束，不是"平均每天"：一次 `refresh` 会把这一批频道的搜索全部花在同一天，所以隔天刷并不会让单次变便宜。

| 清单规模 | 单次消耗 | 能否一次跑完 |
|---|---|---|
| 50 个频道 | 5,000 | ✅ 余量充足 |
| 100 个频道 | 10,000 | ⚠️ 卡满，无余量 |
| **138 个频道（当前）** | **13,800** | ❌ **会被守卫拒绝** |

超过 100 时脚本**直接拒绝运行**，而不是跑到一半。这一点是刻意的：跑到配额耗尽会抛错、不写文件，而 workflow 的推送步骤看到文件不存在就跳过，最后表现为"任务成功、整天配额没了、什么也没产出"。

要跑超过 100 条，有两条路（尚未选定）：

- **收窄目录**到 100 条以内；
- **分批轮换**：每次只刷一批、与 `data` 分支上已有的 feed 合并，代价是批次之间要共享状态。

联调时可以 `refresh --limit 10` 只刷前 10 条，花 1,000 units 就能拿到一份可用的 feed。

`mine` 是按关键词计费的：78 个关键词 = 7,800 units，一天跑得完但没有重跑余量，所以脚本会提示分两天。

## 文件

| 文件 | 谁维护 | 说明 |
|---|---|---|
| `keywords.json` | 手工 | 挖掘用的关键词表，78 条 |
| `candidates.json` | `mine` 生成 | 候选池，已去重、已按真实观众数排序、已过三道校验。人工在这里筛 |
| `curation.json` | 手工 | 人工筛选：`exclude`（channelId → 剔除原因）与 `country`（channelId → 正确国家）。`curate` 读它 |
| `seeds-overrides.json` | 手工 | 人工编辑层：`name` / `city` / `coordinate` / `category` / `isLandmark`。`promote` 读它 |
| `channels-source.json` | 手工 | **策展清单，唯一的输入**。筛完之后填这里 |
| `live-youtube.json` | `refresh` 生成 | App 读的产物，只在 CI 里生成，推 `data` 分支，不进 main |
| `Scripts/youtube.swift` | 手工 | 两个子命令都在这一个文件里 |

## 三道校验

每一条流都要过：

| 关 | 查什么 | 字段 |
|---|---|---|
| 1 | 正在直播 | `snippet.liveBroadcastContent == "live"` |
| 2 | **允许嵌入** | `status.embeddable == true` |
| 3 | 没有被参照市场屏蔽 | `contentDetails.regionRestriction`（参照市场见脚本里的 `Region.reference`，目前是 `US`） |

第 2 关最容易出事：`search.list` 必须带 `videoEmbeddable=true`，漏了就会拿到一批所有者关闭了嵌入的频道，播放器一律报 **152**，看起来像"YouTube 嵌入不可用"，其实是筛错了。

## `channels-source.json` 的字段

```json
[
  {
    "id": "yt-pompano-beach",
    "channelId": "UCxxxxxxxxxxxxxxxxxxxxxx",
    "name": "Pompano Beach",
    "country": "US",
    "city": "Pompano Beach",
    "coordinate": { "latitude": 26.2379, "longitude": -80.1248 },
    "category": "beach",
    "isLandmark": false,
    "source": "YouTube · City of Pompano Beach"
  }
]
```

几条口径：

- **`id` 绑定频道，不是 `videoId`**。直播重开一次 videoId 就变，`id` 跟着变会让 App 的观看历史断掉。用 `yt-<slug>` 这种稳定形式。
- **`category` 只取四个值**：`cityscape` / `beach` / `nature` / `scenic`。
- **地标不是 `category`，是 `isLandmark` 布尔**——排序和筛选都走它。
- **`coordinate` 能查到就填，查不到就留空，不要估算**。留空时 App 会按国家中心落点。
- **`country` 必须人工填**。YouTube 接口不给视频的地理位置，这点没有捷径。
- **`source` 是合规展示用的**，App 的播放页会印它。

## `live-youtube.json` 的形状

```json
{
  "schema": 1,
  "generatedAt": "2026-10-13T08:00:00Z",
  "streams": [
    {
      "id": "yt-pompano-beach",
      "name": "Pompano Beach",
      "country": "US",
      "city": "Pompano Beach",
      "coordinate": { "latitude": 26.2379, "longitude": -80.1248 },
      "category": "beach",
      "isLandmark": false,
      "videoId": "AbCdEf12345",
      "watchUrl": "https://www.youtube.com/watch?v=AbCdEf12345",
      "thumbnail": "https://i.ytimg.com/vi/AbCdEf12345/hqdefault.jpg",
      "source": "YouTube · City of Pompano Beach",
      "viewers": 1240
    }
  ]
}
```

`schema` 是版本号。两个仓库独立演进，服务端加字段时老版本 App 不该解崩。

`viewers` 是 YouTube 报的**真实同时观看人数**（`liveStreamingDetails.concurrentViewers`）。只在直播进行中有值，拿不到就不填——App 那边是"没有就不印观众数"。

## 分发

`data` 分支的根目录由 GitHub Pages 发布，每次成功运行会 force push 一个孤儿提交上去（分支上永远只有一个提交，不留历史）。

**定时任务暂时没挂**：目录 138 条超过单次配额上限，挂上去只会每两天失败一次。现在只手动触发（支持只刷前 N 条）。等第二轮挖掘完、目录定型后，再决定是收窄到 100 条以内还是改成分批轮换，然后把 `schedule` 加回 `refresh.yml`。

```
https://<用户名>.github.io/globe-shot-feeds/live-youtube.json
```

GitHub Pages 自带 HTTPS 和约 10 分钟缓存。**App 侧不开 ATS 例外**。

> 这里曾经考虑过 jsDelivr，被否掉了：它对分支文件的缓存长达 12 小时，而"是否还在播"是会变的状态，滞后半天没法用。

## 合规红线

- 只走**官方 IFrame 播放器嵌入**和**官方 Data API v3**。抓 `googlevideo` 的 m3u8、第三方解析库、代理转发流一律不做。
- **不做**去广告、不做后台音频、不把内容放进付费墙。
- App 侧必须标 YouTube 品牌并链回观看页。
- 只收录**允许嵌入**且**未被参照市场屏蔽**的流。
