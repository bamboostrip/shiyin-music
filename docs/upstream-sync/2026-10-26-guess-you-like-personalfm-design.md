# 「猜你喜欢（红心 Radio / 私人 FM）」移植设计（上游 3.2.0 → fork）

- 日期：2026-10-26
- 关联 issue：[bamboostrip/shiyin-music#5](https://github.com/bamboostrip/shiyin-music/issues/5)「体验很好，希望加上红心猜你喜欢的功能，目前的猜你喜欢只是一个歌单」
- 上游参考：`umr-xiaomai/kgka_Music_hl` 3.1/3.2，`master` tip `4ae26cc`（3.2.0stable），merge-base `e644a9e`
- 本文用途：功能架构与可落地实施方案；**同时记录实现现状与遗留风险**（实现已由 lead 落在同步分支，见 §5「实施现状」）。

---

## 0. 结论摘要（TL;DR）

1. **Dart-only 可落地**。fork 无远程后端，但 Rust 引擎已有同路径路由 `GET /personal/fm`
   （`rust/src/engine.rs:399` → `rust/src/services/discover.rs:273 personal_fm`，
   上游 `persnfm.service.kugou.com /v2/personal_recommend`），且 `kugou/api_response.rs`
   已把 `data` 提升为根节点（与上游 .NET 后端的透传语义一致）。**无需改 Rust、无需重新生成 FRP 代码**。
2. **唯一必须改写的契约点是查询参数命名**：上游 Dart 客户端发 camelCase（`songPoolId` /
   `isOverplay` / `remainSongCnt`，由 .NET 后端吃下），fork 的 Rust 路由按 **snake_case**
   精确取键（`song_pool_id` / `is_overplay` / `remain_song_cnt`，见 `engine.rs:408-419`）。
   另：`action` 上游依赖后端默认值 `play`（`api.json`），Rust 路由缺省是 `refresh`
   （`engine.rs:403-406`）→ **Dart 侧显式传 `action=play`** 对齐两端。
3. **必须改的核心文件 6 个**：`lib/models/song.dart`、`lib/services/music_api_rank.dart`、
   `lib/services/music_api_song.dart`（`hashOnly`）、`lib/controllers/player_controller.dart`
   （+ 新分片 `player_controller.personalfm.dart`）、`lib/controllers/player_controller.queue.dart`、
   `lib/controllers/player_controller.playback.dart`、`lib/ui/pages/home_page.dart`。
4. **最大风险 = 响应字段契约未在真机验证**：`song_list` 键名/字段来自上游 .NET 后端 OpenAPI
   （`api.json` 的 `PersonalFmResponse` / `PersonalFmSong`），Rust 是透传，理论上一致，但
   **没有一次登录态真机抓包确认**。若酷狗实际返回 `songlist`/`list` 或失败信封，当前实现会
   静默表现为「暂时没有推荐」（无报错、无日志）。→ 见风险 **R1**，必须做一次契约验证 +
   容错解析，这是 10 分钟成本的兜底。
5. **实现已覆盖**：`MusicApi.personalFm` / `Song.fromPersonalFm` / `songUrl.hashOnly` /
   私人 FM 会话状态机（`player_controller.personalfm.dart`）/ 首页卡片预览与刷新联动 /
   会话内线性上一首下一首 / 播完续批 / 退出会话启发式。单测 3 个文件已存在。
6. **仍建议收尾（按优先级）**：R2 每日推荐入口丢失（产品回归）→ R3 「无队列点歌」残留会话
   → R1 契约容错 → R8 首页 widget 测试替身缺失（会红）→ R5 续批失败无提示 → R4 队列无限增长。

---

## 1. 背景与问题定性

### 1.1 用户到底在抱怨什么

| 现象 | 事实 |
| --- | --- |
| 首页「猜你喜欢」卡片 | fork 里数据源是 `DailyRecommend`（`/recommend/songs` 每日推荐），文案却叫「猜你喜欢」 |
| 点卡片 | 进入 `PlaylistDetailPage`（`_openDailyRecommend`，`home_page.dart` 旧 970-990），即「只是一个歌单」 |
| 用户期望 | 酷狗官方「猜你喜欢」= 红心 Radio + 口味私人 FM：**一直播、不重样、能红心** |

上游 3.1 起把该入口整体换成官方私人 FM（`33403a8`），fork 未同步，所以体验缺失。

### 1.2 上游实现（可移植基线）

| 提交 | 内容 | 对本 fork 的处置 |
| --- | --- | --- |
| `33403a8` | 新增 `MusicApi.personalFm()`、`Song.fromPersonalFm`、`PlayerController` 私人 FM 会话（start/续批/竞态）、home_page 卡片改造、`music_audio_handler` 4 行 | **主体，全部移植**（会话拆到新 part） |
| `2c1e07c` | ① 刷新首页时联动刷新「猜你喜欢」；② `songUrl(hashOnly:)` 开启；③ `fromPersonalFm` 的 id/albumAudioId 映射对调（`id=songid`、`albumAudioId=mixsongid`）；④ 续批去重策略改为「仅排除当前歌」+ 空则退回纯刷新；⑤ `currentIndex` 增加 identical 快路径 | ①②③⑤ 移植；④ **改进为「队列近 30 首去重」**（见 §6.4） |
| `62ae541` | `Song.fromTopCard` 的 `time_length` 按「带小数的秒」解析 | fork 无 `/top/card`（无 `fromTopCard`），**不直接移植**；但同类隐患成立 → 对 `fromPersonalFm` 用「宽容秒解析」（风险 R9） |
| `0194282` | 「在同一队列里切歌」不再退出 FM 会话（`_isSameQueue` 启发式） | 移植，但修掉 `queue == null` 分支的误判（风险 R3） |
| `bf264d9` | 随机播放"上一首"修复时顺带给 `_previousSong()` 加 FM 线性分支；歌名去前缀、VIP 领取等周边修复 | FM 相关部分：fork 的 `previous()` 已是显式线性分支（等价）；歌名前缀用 fork 已有 `cleanSongTitle` |

上游没有做、也不该照抄的部分：3.2 首页改版（`LiquidGlassCard`、短视频热歌卡、推荐单曲卡网格）、播放页小游戏/液态玻璃开关、`player_game_enabled` 设置项。

---

## 2. 本 fork 架构适配结论

### 2.1 数据链路（关键：参数命名与解包位置）

```
Dart  MusicApi.personalFm()                     ← lib/services/music_api_rank.dart（part mixin）
  └─ ApiClientInterface.get('/personal/fm', {snake_case 参数})
       └─ RustApiClient._request()
            ├─ query JSON → stringify 每个 value（bool → "true"/"false"）
            └─ engineRequest(method,path,query,body)
                 └─ rust/src/engine.rs ("GET","/personal/fm")
                      ├─ 取 hash/songid/playtime/action/mode/
                      │   song_pool_id/is_overplay/remain_song_cnt  （snake_case，精确匹配）
                      └─ discover::personal_fm() → POST persnfm.service.kugou.com/v2/personal_recommend
                           └─ transport::send()
                                ├─ 成功：api_response::parse() 把 data 提升为根（并把 status/error_code 补回根）
                                └─ 失败：**不透传 data，原样返回 root**（status/error_code/msg，无 song_list）
```

由此得到三条硬约束：

1. **参数键必须 snake_case**，且 Boolean 以字符串 `true/false` 传入（Rust 判定 `s=="1" || s=="true"`，见 `engine.rs:412-415`）。
2. **`action` 必须显式传 `play`**：初始刷新与播放反馈都传，避免 Rust 缺省 `refresh` 与上游后端缺省 `play` 的语义漂移。
3. **失败是"成功返回 + 无数据"**：Dart 必须自行识别失败信封，否则用户只看到"没有推荐"。

### 2.2 参数映射表（Dart → Rust 路由 → 酷狗 body）

| 语义 | 上游 Dart | **fork Dart（必须）** | Rust 路由键 | Rust → 酷狗 body 字段 |
| --- | --- | --- | --- | --- |
| 模式（红心） | `mode=normal` | `mode=normal` | `mode` | `mode` |
| AI 策略池（口味 Alpha） | `songPoolId=0` | **`song_pool_id=0`** | `song_pool_id` | `song_pool_id` |
| 行为 | 缺省（后端默认 play） | **`action=play`（显式）** | `action` | `action` |
| 上报当前歌 hash | `hash` | `hash` | `hash` | `hash` |
| 上报当前歌 songid | `songid` | `songid` | `songid` | `songid`（字符串） |
| 已播秒数 | `playtime` | `playtime` | `playtime`（i64） | `playtime` |
| 是否自然播完 | `isOverplay` | **`is_overplay`** | `is_overplay` | `is_overplay`（1/0） |
| 队列剩余数（0=要歌） | `remainSongCnt=0` | **`remain_song_cnt=0`** | `remain_song_cnt` | `remain_songcnt` |

### 2.3 响应与字段映射

`api.json`（fork main 已含，与 upstream 同版本）`PersonalFmResponse` / `PersonalFmSong` / `TransParam`：

| 目标字段（`Song`） | 来源 JSON | 说明 |
| --- | --- | --- |
| `hash` | `hash` | **播放/去重/身份主键**（必须非空，否则丢弃） |
| `id` | `songid`（回退 `mixsongid`、`hash`） | 播放反馈上报用 `songid`（上游 2c1e07c 起） |
| `albumAudioId` | `mixsongid`（回退 `songid`） | 加入收藏/歌单时作 MixSongID（`_songAddPayload`） |
| `albumId` | `album_id` | 仅展示/兜底 |
| `title` / `rawTitle` | `songname` | 经 fork 的 `cleanSongTitle` 去「歌手 - 」前缀 |
| `artist` / `artists` | `singerinfo[]`（`id`/`name`/`avatar`），回退 `author_name` | `parseArtists` 已支持 `singerinfo` |
| `coverUrl` | `trans_param.union_cover`（回退 `sizable_cover`/`cover`） | `normalizeImageUrl` 处理 `{size}` |
| `duration` | `time_length`（秒，`int32`） | 见 R9：宽容解析小数/字符串 |
| `albumName` | `album_name`（上游模型未声明，可空） | 缺失为 null |

> **播放地址**：FM 歌曲一律走 `hashOnly=true`（不传 `album_id`/`album_audio_id`，Rust 侧缺省 `"0"`），
> 因为 FM 下发的专辑/音频 id 不可靠；这是上游 `2c1e07c` 的关键修复。

### 2.4 fork 代码组织映射

| 上游位置 | fork 落点 | 说明 |
| --- | --- | --- |
| `MusicApi.personalFm`（`music_api.dart` 单体） | `lib/services/music_api_rank.dart`（`_MusicApiRank` mixin，紧跟 `dailyRecommend`） | part 混入，偏好放推荐域 |
| `Song.fromPersonalFm`（`music_models.dart`） | `lib/models/song.dart`（紧随 `fromDaily`） | 模型已拆文件 |
| `PlayerController` 单体 | **新增 part** `lib/controllers/player_controller.personalfm.dart`（`mixin _PlayerPersonalFm`） | 与 queue/playback/lyrics 分片风格一致；基类声明字段与成员契约 |
| `_nextSong`/`_handleCompleted`/`playSong` | `player_controller.dart`（基类）/ `player_controller.playback.dart` | 跨分片契约在基类显式声明 |
| `home_page` 单体 | `lib/ui/pages/home_page.dart`（4000+ 行，含手机/平板/车机/超宽屏） | 只改推荐区卡片与状态，不碰布局分支 |
| `music_audio_handler` 4 行 | `lib/services/music_audio_handler.dart:572` 起 `play()` | `dart:async` 已导入，只需 `unawaited`（可选，见 R10） |

---

## 3. 会话状态机（实现蓝图）

### 3.1 状态与不变量

```
状态：IDLE ──startPersonalFm──▶ LOADING ──首批到位──▶ ACTIVE(播放中/暂停)
                 ▲                    │                     │
                 │                    └──空/失败──▶ IDLE(错误横幅)
                 └────────playSong(队列外点歌) / stopPersonalFm─────────┘
ACTIVE 内：队列末尾 next()/自然播完 → BATCH_LOADING → 追加 5 首 → 播放第一名（仍 ACTIVE）
```

不变量：

1. `_isPersonalFmActive == true` 时 **`next()/previous()/完成推进一律线性**：不随机、不循环、不进单曲循环。
2. `_personalFmRequestSerial` 只在「会话状态被改写」或「发起新请求」时自增；晚到响应靠序号丢弃。
3. 任何时候最多一个在途 FM 请求（`_isLoadingPersonalFm` 重入保护）。
4. 会话内 `queue` 只追加、不回绕；`_isAtQueueEnd` 是"续批触发器"。
5. `playSong` 是唯一出口：非会话内点歌自动退出会话（`preservePersonalFmSession` / 同队列启发式）。

### 3.2 迁移矩阵（用户动作 → 结果）

| 用户动作 | 判定 | 结果 |
| --- | --- | --- |
| 首页点「猜你喜欢」 | `!isActive` | 用预览批次秒开播；无预览则现拉 |
| 首页点「猜你喜欢」（会话中） | `isActive` | `togglePlay()`（卡片同时显示 ⏸/▶ 与「播放中/已暂停」） |
| 队列中段「下一首」 | `isActive && !atEnd` | 线性下一首（`preserve`）|
| 队尾「下一首」 | `isActive && atEnd` | 续批（`isOverplay=false`），播新批第一首 |
| 自然播完 | `isActive && atEnd`（在 `singleLoop` 判定之前） | 续批（`isOverplay=true`） |
| 「上一首」 | `isActive` | 线性回退；首曲则回零，**不退出会话** |
| 队列弹层点同队列其它歌 | `queue` 为当前队列实例 | 保持会话 |
| 歌单/搜索/首页其它卡片点歌 | 传入新队列 | **退出会话**，走普通播放 |
| 已下载/本地/历史点单曲（`playSong(song)` 无 queue） | ⚠️ 见 R3 | 设计上应退出会话；当前实现会误保留 |
| 清空队列（仅留当前歌） | `replaceQueue([current])` | 不退出会话；下次队尾触发续批 |
| 删除当前歌 | 新队列 | 退出会话（当前实现） |
| 登出 | ⚠️ 见 R6 | 建议退出会话并清预览 |

### 3.3 播完续批的插入位置（照上游）

`_handleCompleted()` 内顺序必须是：

```dart
if (_sleepFinishCurrentSong) { ...暂停... return; }         // 睡眠定时优先，保持 fork 既有语义
if (_isPersonalFmActive && _isAtQueueEnd) {                 // ★ FM 续批
  await _loadNextPersonalFmBatch(isOverplay: true);
  return;
}
if (!_isPersonalFmActive && playbackMode == PlaybackMode.singleLoop) { ... }
```

理由：单曲循环在 FM 会话内不成立（FM 是电台语义），但**睡眠定时"播完这首停"必须仍然优先**——
这是 fork 独有逻辑（上游无），移植时容易错序。

---

## 4. 与 fork 既有机制的交互

| 机制 | 交互结论 |
| --- | --- |
| `_nextSong({peek})` | FM 分支置于 shuffle 之前；队尾返回 null。`_maybePrecacheNext` 因此队尾不预取（可接受）。 |
| `currentIndex` | 仍按 hash 定位；FM 歌曲 hash 必非空。**不要**改成 `_songIdentity`（会影响非 FM 的既有行为）。 |
| `_isSameQueue`（新增） | 按 `hash/albumAudioId/id` 身份逐项比较；`playSong` 用它判定是否"同一队列里切歌"。 |
| `playSong(..., preservePersonalFmSession)` | 作为基类契约新增命名参数；所有内部调用（重试/VIP 领取/切音质/恢复）通过 `_isSameQueue` 启发式自动保持会话，**无需逐点透传**。 |
| `_resolvePlayUrl` / `_tryClaimVipAndRetry` | 三处 + VIP 重试处都要传 `hashOnly: isPersonalFmActive`（漏一处即 FM 内切音质/领 VIP 后取不到地址）。 |
| 智能音质降级 | 与 hashOnly 正交，降级链继续生效（`lossless→high→standard`）。 |
| 播放历史/统计 | `playSong` 内既有 `record` 调用自动记录 FM 歌；**但历史页回放走非 hashOnly**（R7）。 |
| 红心/收藏 | 加收藏用 `albumAudioId`(=mixsongid) → `_songAddPayload` 正确；取消收藏依赖 `_hashToFileId`（加成功后回填），FM 歌可正常取消。 |
| 系统媒体会话 | `loadSong(queueSongs: queue, queueIndex: currentIndex)` 每批都会刷新系统队列；通知栏上一首/下一首 → `next()/previous()` → FM 语义 ✔ |
| 桌面播放栏/迷你播放器 | 无需改动，随控制器状态刷新。 |
| 音频 handler `play()` | fork 已有 `_kPlayConfirmTimeout`（2s）兜底 Android `play()` 挂到曲末；上游的 `unawaited` 优化可选（R10）。 |
| 播放模式按钮 | FM 会话期间切随机/单曲循环不生效（上游一致）→ R12 建议提示。 |
| 队列持久化 | `_savePlaybackState` 写 `queue`(前 200)+`currentIndex`；冷启动 `_isPersonalFmActive=false` → FM 队列按普通歌单循环。可接受（R13）。 |

---

## 5. 实施现状（已由 lead 落在同步分支，供核对）

| # | 文件 | 内容 | 状态 |
| --- | --- | --- | --- |
| C1 | `lib/models/song.dart:231` | `Song.fromPersonalFm`（id=songid、albumAudioId=mixsongid、union_cover、singerinfo） | ✅ |
| C2 | `lib/services/music_api_rank.dart:19` | `personalFm({hash,songId,playtime,isOverplay})`，snake_case 映射、单批 ≤5、按 hash 去重 | ✅ |
| C3 | `lib/services/music_api_song.dart:53` | `songUrl(..., hashOnly)` | ✅ |
| C4 | `lib/controllers/player_controller.dart:533/366/896/923` | 会话字段 + getters + `playSong` 参数契约 + `_nextSong` FM 线性分支；`personalfm` part 注册进 `with` | ✅ |
| C5 | `lib/controllers/player_controller.personalfm.dart`（新分片） | `startPersonalFm` / `_loadNextPersonalFmBatch` / `_personalFmAdditions` / `_isAtQueueEnd` / `_isSameQueue` / `_songIdentity` | ✅ |
| C6 | `lib/controllers/player_controller.playback.dart:56/611-666/909` | `playSong` 会话保持判定、4 处 `hashOnly`、`_handleCompleted` FM 续批 + `singleLoop` 互斥 | ✅ |
| C7 | `lib/controllers/player_controller.queue.dart:106/139` | `next()` 队尾续批、`previous()` FM 线性回退 | ✅ |
| C8 | `lib/ui/pages/home_page.dart:167/778/996/1002/1032/1869+` | 预览拉取、登录态联动、手动刷新联动、`_FeatureShelf`/`_FeatureCard` 播放态与 loading、`_CirclePlayButton.icon` | ✅ |
| C9 | `test/controllers/player_personal_fm_test.dart` 等 3 个测试 | 启动/导航/退出/空批/模型解析/API 参数 | ✅ |
| C10 | 首页 widget 测试替身 | 仅改了 `home_page_tabs_swipe_test.dart` | ⚠️ 见 R8 |
| C11 | `music_audio_handler.play()` unawaited | 未做 | 可选（R10） |
| C12 | `_openDailyRecommend` | **已删除且无替代入口** | ❌ 见 R2 |

---

## 6. 遗留风险与补丁（按优先级）

### R1【高】响应契约未验证 + 失败信封静默

**现象**：`MusicApi.personalFm` 只读 `json['song_list']`；若键名不符或上游返回失败信封
（Rust 失败时返回 root：`status/error_code/msg`，无 `song_list`），结果都是空列表 → 上层显示
「暂时没有新的私人 FM 推荐」，**无日志、无错误码**，线上无法定位。

**验证步骤（10 分钟，必须做一次）**：

1. 登录真机/桌面，首页触发一次 `personalFm()`。
2. 看日志：`adb logcat -s flutter | findstr shiyin`（Windows 桌面直接看控制台）。
3. 期望：无异常；卡片副标题变为预览首曲名（说明 `song_list` 解析成功）。
4. 若要更强证据，临时在 `personalFm()` 加一行
   `debugPrint('[shiyin][fm] keys=${json.keys.toList()} n=${asList(json['song_list']).length}')`。

**补丁（推荐直接合入）**：

```dart
    final json = asMap(raw);
    // 兼容三种键名（上游 .NET 模型是 song_list；酷狗原始 data 偶见 songlist/list）。
    final items = asList(
      json['song_list'] ?? json['songlist'] ?? json['list'] ?? _firstListValue(json),
    );
    if (items.isEmpty) {
      // Rust 对非成功 status 透传 root 信封：这里必须把错误码翻出来，
      // 否则登录失效/风控会被伪装成「没有推荐」。
      final status = asInt(json['status']);
      final errorCode = asInt(json['error_code'] ?? json['errcode']);
      final ok = (status == null || status == 1 || status == 200) &&
          (errorCode == null || errorCode == 0);
      final rawKeys = json.keys.join(',');
      debugPrint('[shiyin][fm] 空推荐 status=$status err=$errorCode keys=[$rawKeys]');
      if (!ok) {
        final msg = asString(json['msg'] ?? json['error'] ?? json['message']);
        throw ApiException(
          msg?.isNotEmpty == true
              ? '猜你喜欢加载失败：$msg'
              : '猜你喜欢加载失败（错误码 ${errorCode ?? status}）',
        );
      }
    }
```

> 若真机验证发现键名是第三种（如 `data.song_list`）：Rust 已提升 `data`，Dart 也可用
> `asMap(json['data'])['song_list']` 兜底；**不要为此改 Rust**（改 Rust 需要 `cargo build` 重编
> 各平台动态库，但不需要 frb codegen——`engineRequest` 签名不变）。

### R2【高】每日推荐入口丢失（产品回归）

`_openDailyRecommend` 已被删除，`data.daily.songs` 只剩「大家都在听」区块在用；用户再也进不去
每日推荐歌单页。上游是把入口整体换掉了，但 fork 的每日推荐是**自有数据源**（`/recommend/songs`），
不该丢。

**补丁（最小改动，两处调用点 + 一个可选参数）**：

1. `_SongSection` 增加可选 `onTitleTap`，两处 `_SectionHeader` 传入：

```dart
class _SongSection extends StatefulWidget {
  const _SongSection({
    ...
    this.onTitleTap,
  });
  final VoidCallback? onTitleTap;
```

```dart
// build 内（boxed 分支）:
              _SectionHeader(
                title: widget.title,
                action: _CirclePlayButton(...),
                onTap: widget.onTitleTap,
              ),
// _buildDesktopSlivers 内同款加 onTap: widget.onTitleTap
```

2. 两个调用点（`home_page.dart` 约 1442 / 1629）：标题 `'大家都在听'` → `'每日推荐'`，并传 `onTitleTap`：

```dart
                      _SongSection(
                        key: ValueKey('song_section_$railResetEpoch'),
                        asSlivers: true,
                        title: '每日推荐',
                        songs: data.daily.songs,
                        onTitleTap: () => _openDailyRecommend(data.daily),   // 恢复旧入口
                        ...
```

3. `_openDailyRecommend` 原实现恢复（标题改为「每日推荐」，避免与 FM 卡片重名）：

```dart
  /// 每日推荐歌单页（原「猜你喜欢」卡片入口）：FM 接管卡片后保留为一级入口。
  void _openDailyRecommend(DailyRecommend daily) {
    final playlist = PlaylistSummary(
      id: 'daily_recommend',
      title: daily.title,                       // '每日推荐' / '每日推荐 yyyy-MM-dd'
      subtitle: daily.subtitle ?? '根据你的听歌偏好，每日精心推荐',
      coverUrl: daily.coverUrl ??
          (daily.songs.isNotEmpty ? daily.songs.first.coverUrl : null),
      songCount: daily.songs.length,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api, auth: widget.auth, player: widget.player,
          playlist: playlist, initialSongs: daily.songs,
        ),
      ),
    );
  }
```

4. 同步改测试里对文案的引用：`大家都在听` → `每日推荐`
   （`test/ui/pages/car_mode_tab_restore_test.dart:269,286`、
   `test/ui/pages/car_mode_desktop_suppression_test.dart:179,181`、
   `test/ui/pages/home_desktop_lazy_sections_test.dart` 注释与断言、
   以及所有 `find.text('大家都在听')`）。

> 备选（若不想动 section 标题）：在 FM 卡片 hint 行右侧加一个「每日推荐 ›」小按钮。
> 但信息密度更高、车机触控目标更小，不推荐。

### R3【高】`queue == null` 的会话保持误判 → 「播完停住」

当前 `playSong` 判定：

```dart
    final isPlayingWithinCurrentQueue = _isPersonalFmActive &&
        (queue == null || identical(queue, this.queue) || _isSameQueue(queue, this.queue));
```

`queue == null` 本意是覆盖「网络恢复自动重播 / 内部重试」（此时 `song == currentSong`）。但
`playSong(song)` 也被**用户单曲入口**使用：`downloaded_songs_page.dart:322/323/490`、
`local_songs_page.dart`、`playback_history_page.dart` 等。若 FM 会话中点这类入口：

- 会话未退出 → `currentSong` 不在 `queue` 里 → `currentIndex == -1`；
- `_nextSong()` 走 FM 分支 `index >= 0` 不成立 → 返回 null → `next()` 无反应；
- 播完时 `_isAtQueueEnd` 为 false（index=-1）→ 不进续批；落 `_nextSong()` 为 null → `seek(0)` 停住；
- 用户感觉「猜你喜欢播到一半就死了」。

**补丁**（加一个"歌在当前队列里"的前置条件，语义更准确）：

```dart
    bool isSongInCurrentQueue(String identity) =>
        identity.isNotEmpty && queue.any((item) => _songIdentity(item) == identity);
    final songIdentity = _songIdentity(song);
    final isPlayingWithinCurrentQueue = _isPersonalFmActive &&
        (queue == null || identical(queue, this.queue) || _isSameQueue(queue, this.queue)) &&
        isSongInCurrentQueue(songIdentity);
```

配套：`startPersonalFm` / `_loadNextPersonalFmBatch` 已显式传 `preservePersonalFmSession: true`，
不受影响；`player_controller.dart:188` 的网络恢复重播（`song == currentSong`，在队列里）仍保留会话 ✔。

### R4【中】FM 队列无上限增长 / 冷启动恢复错位

`_loadNextPersonalFmBatch` 只做 `queue = [...queue, ...additions]`，长时收听（睡前电台是典型场景）
每 5 首 +1 项、永不裁剪：

- 内存与系统媒体队列线性增长；
- 每次切歌 `loadSong(queueSongs: queue)` 全量重建系统队列；
- `_savePlaybackState` 只写前 200 首但 `currentIndex` 写真实下标 → 冷启动
  `_restorePlaybackState` 用 `.clamp(0, queueList.length - 1)` 会把"第 250 首"恢复成"第 200 首"，
  **播错歌**（这是既有隐患，FM 长会话把它放大成常态）。

**补丁**：

```dart
  /// 追加 FM 歌曲并做软上限裁剪：会话可无限播放，queue 不能无限增长。
  /// 只裁「当前歌之前」的已播部分（保留 30 首供"上一首"回退），
  /// 当前歌及之后不动，`currentIndex` 按 hash 重新定位后仍指向同一首。
  List<Song> _appendPersonalFm(List<Song> additions) {
    final next = [...queue, ...additions];
    const softLimit = 120;
    const keepPlayed = 30;
    if (next.length <= softLimit) return next;
    final index = currentIndex;
    if (index < keepPlayed) return next;
    return next.sublist(index - keepPlayed);
  }
```

调用点：`queue = _appendPersonalFm(additions);`。

另建议（独立小修）：`_restorePlaybackState` 恢复 `currentSong` 时优先用持久化的 `currentSong`
条目本身（`Song.fromCache` 后的 hash 匹配），而不是 `currentIndex` 下标；或保存时把
`currentIndex` 与实际截断后的队列对齐。此项可单独提 issue，不阻塞本功能。

### R5【中】续批失败无提示 + 完成标记残留

`_handleCompleted` 在进 FM 分支前已置 `_completedSongHash = song.hash`；`_loadNextPersonalFmBatch`
失败时只设 `errorMessage`，`_completedSongHash` 仍保留 → 之后即使再次收到 completed 也会被
`_willHandleCompletion` 去重；而且首页/播放页未必展示 `errorMessage`，用户只看到"停在最后一首"。

**补丁**：

```dart
    } catch (error) {
      if (requestSerial == _personalFmRequestSerial) {
        errorMessage = error.toString();
        // 允许下一次 completed/兜底再次尝试续批；否则队尾被永久锁死。
        _completedSongHash = null;
        if (!_disposed) {
          Toast.error('猜你喜欢加载失败，点下一首重试');
          notifyListeners();
        }
      }
    }
```

### R6【中】缺显式退出入口 + 登出态

- 目前**没有** `stopPersonalFm()`：用户想"退出电台"只能去点别的歌/歌单；卡片/播放页都没有"结束"。
- 登出后会话继续；下一批请求缺 `token/userid`（Rust `personal_fm` 里 `userid=="0"` 时不下发用户域
  参数）→ 大概率失败，落 R5 的错误态。

**补丁**：

```dart
  /// 主动结束私人 FM 会话（保留当前歌与队列，仅停止"续批"。
  /// 退出后按当前 playbackMode 正常推进）。
  void stopPersonalFm() {
    if (!_isPersonalFmActive && !_isLoadingPersonalFm) return;
    _isPersonalFmActive = false;
    _isLoadingPersonalFm = false;
    _personalFmRequestSerial++;
    notifyListeners();
  }
```

- 入口建议：播放页/队列弹层「猜你喜欢」标签旁放「结束电台」；或卡片长按菜单。
- 登出联动（`home_page._handleAuthChanged` 已有登出分支）：追加
  `if (widget.player.isPersonalFmActive) widget.player.stopPersonalFm();`

### R7【中】播放历史/其它入口回放 FM 歌可能取不到音源

FM 会话内播 URL 走 `hashOnly=true`；但同一首 `Song` 落进播放历史后，在历史页点播走
`playSong(song, queue: ...)`（非会话）→ `hashOnly=false` → 会带上 `album_id`/`album_audio_id`
（=mixsongid）。若该组合在 `/v5/url` 取不到地址（上游正是因为这一点才加 hashOnly），历史回放会报
「暂时没有可播放地址」。

**补丁（二选一）**：

- A（推荐，低风险）：`_resolvePlayUrl` 在非 FM 路径首次返回空地址时，**用 hashOnly 再试一次**再走音质降级：

```dart
      final playUrl = await _api.songUrl(song, quality: audioQuality, hashOnly: _isPersonalFmActive);
      if (playUrl.url.isEmpty && !_isPersonalFmActive) {
        final hashOnlyUrl = await _api.songUrl(song, quality: audioQuality, hashOnly: true);
        if (hashOnlyUrl.url.isNotEmpty) return hashOnlyUrl;
      }
```

- B：给 `Song` 加 `bool isPersonalFmSource`，历史/缓存持久化该标记，播放时据此 hashOnly。
  成本更高（要改 `toCache/fromCache` 与历史服务），收益有限，暂不推荐。

**手测必做**：FM 中红心/播放过的歌 → 去播放历史点播 → 能否出声。

### R8【中】渲染首页的 widget 测试替身缺新 getter（会红）

`_FeatureShelf` 在 `AnimatedBuilder(player)` 里读 `player.isPersonalFmActive` / `isLoadingPersonalFm`；
测试里的 `class _FakePlayerController extends ChangeNotifier implements PlayerController` 大多没有这两个
成员（`noSuchMethod => super.noSuchMethod(...)` 会在运行期抛 `NoSuchMethodError`，**analyze 不报**）。
已确认需要补的文件（导入 `home_page.dart` 且自带 fake player）：

```
test/ui/pages/car_display_integration_test.dart
test/ui/pages/car_mode_desktop_suppression_test.dart
test/ui/pages/car_mode_tab_restore_test.dart
test/ui/pages/car_recommend_equalizer_test.dart
test/ui/pages/home_desktop_lazy_sections_test.dart
test/ui/pages/home_desktop_refresh_test.dart
test/ui/pages/home_header_tab_switch_test.dart
test/ui/pages/home_page_tabs_swipe_test.dart          （已改，核对是否补齐）
test/ui/pages/home_sections_navigation_test.dart
test/ui/pages/home_scroll_to_top_test.dart            （经 AppShell 间接渲染首页）
```

统一补丁（每个 fake 加 6 行）：

```dart
  @override
  bool get isPersonalFmActive => false;

  @override
  bool get isLoadingPersonalFm => false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;
```

定位命令：`git grep -l "implements PlayerController" main -- test` 后按「是否渲染 HomePage/AppShell」筛。

### R9【低】`time_length` 小数/字符串解析

`durationFromSeconds` → `asInt` → `int.tryParse`，遇到 `259.16` / `"259.16"` 返回 null（列表显示 `--:--`）。
上游 `62ae541` 修复的是同类问题（`/top/card`）。`api.json` 标注 FM 的 `time_length` 是 `int32`，
但**同族推荐接口曾出现过小数**，成本极低建议兜底：

```dart
// lib/models/model_parsing.dart
/// 秒（可带小数 / 字符串）→ Duration；与 durationFromSeconds 并存，供推荐类接口使用。
Duration? durationFromFlexibleSeconds(Object? value) {
  if (value == null) return null;
  final seconds = value is num ? value.toDouble() : double.tryParse(value.toString());
  return seconds == null ? null : Duration(milliseconds: (seconds * 1000).round());
}
```

`Song.fromPersonalFm` 改为 `duration: durationFromFlexibleSeconds(json['time_length'])`。

### R10【低】`music_audio_handler.play()` 仍无界等待（上游 33403a8 的 4 行）

fork 已用 `_kPlayConfirmTimeout`（2s）兜住 Android `play()` 挂到曲末的问题（`player_controller.dart:739-787`
有完整论证），所以**不移植也正确**，只是每次起播多等 2s 才进"确认成功"分支，FM 连续切歌的体感延迟更明显。
若要移植（`music_audio_handler.dart:572` 起，`dart:async` 已导入）：

```dart
      // 上游 33403a8：Android 原生 play(Result) 会挂到曲末才回执，
      // 无界 await 会拖住 handler 的调用方；起播错误另有 errorStream 兜底。
      unawaited(
        audioPlayer.play().catchError((Object error, StackTrace stack) {
          debugPrint('[AudioHandler][ERROR] play 失败: $error');
        }),
      );
```

风险：`catchError` 后错误不再走 `_requestPlayback` 的 try/catch，但 fork 的 `errorStream`
监听（`_errorSub` → `_handleMidPlaybackError`）覆盖播放中错误，加载期错误在 `playSong` 的 try 内。
建议单独 commit + 全量回归后再合。

### R11【低】车机/平板形态细节

- `_FeatureCard` 的 hint 不再有车机专属 `· 右侧播放` 后缀（原逻辑写死在 card 内，现由调用方给 hint）。
  车机是横屏触控，建议 `_FeatureShelf.build` 内按 `isCarMode` 追加提示：
  `hint: isCarMode ? '$hint · 右侧按钮播放/暂停' : hint`。
- 平板：`_FeatureShelf` 仍被 `ConstrainedBox(maxWidth: tabletShell ? 620 : ∞)` 限宽 ✔；
  但卡片内文案变长（「私人 FM 播放中 · 点击暂停」）需在 360dp 窄屏与车机放大字号下各看一眼，确认单行省略不截断关键字。
- 超宽车机（ultrawide）`_RecommendHeader` 中卡片与统计 pills 并排（flex 6:4），FM 卡片变高不变宽 ✔。

### R12【低】会话期间播放模式按钮"看起来失效"

FM 会话内 `cyclePlaybackMode()` 仍可切换并高亮，但推进逻辑忽略它（上游一致）。建议在
`cyclePlaybackMode()` 里对会话态加一次 Toast：
`if (_isPersonalFmActive) Toast.info('猜你喜欢为顺序推荐，播放模式暂不生效');`
（或在播放页把模式按钮置灰 + tooltip）。

### R13【低】会话不持久化（接受）

冷启动后 FM 队列按 `playbackMode` 普通循环；若恢复时模式是 `singleLoop`，会在 FM 队列里单曲循环。
建议**接受**（电台本来就是"这一次会话"语义），文档与 FAQ 说明即可；若要更干净，可在
`_savePlaybackState` 时不写会话标记（现状本来就没写）而在 `_restorePlaybackState` 强制
`playbackMode = playlistLoop`（不建议，会改既有行为）。

### R14【低】队尾无预缓存

`_maybePrecacheNext` 在 FM 队尾 `_nextSong(peek:true)` 返回 null → 下一批首曲不预缓存音频/歌词，
续批首曲起播略慢（一次网络解析）。可选：续批成功后 `unawaited(loadLyrics(additions.first))` 预热歌词。

---

## 7. UI 形态与文案（已实现，供验收对照）

| 形态 | 状态 | 标题 | 副标题/hint | 右侧按钮 |
| --- | --- | --- | --- | --- |
| 手机/平板/桌面 | 未登录 | 猜你喜欢 | 「红心 Radio · 根据口味」+ hint「红心 Radio · 点击播放猜你喜欢」；点击 → Toast「登录后才能使用红心猜你喜欢」 | ▶ |
| 同上 | 已登录未播放（有预览） | 猜你喜欢 | 预览首曲名 + hint 同上 | ▶ |
| 同上 | 拉起中 | 猜你喜欢 | 预览首曲名 / 兜底文案 | 转圈（点按禁用） |
| 同上 | FM 播放中 | 猜你喜欢 | 当前歌名 + hint「私人 FM 播放中 · 点击暂停」 | ⏸ |
| 同上 | FM 暂停 | 猜你喜欢 | 当前歌名 + hint「私人 FM 已暂停 · 点击继续」 | ▶ |
| 车机 | 任意 | 同上 | 同上（建议补「· 右侧按钮」后缀，R11） | 同上 |
| 播放页/迷你播放器 | FM 会话中 | 无新增元素 | ——（可选：队列弹层标题旁加「猜你喜欢」标签，P2） | —— |

文案用词约定：入口统一叫「猜你喜欢」（与 issue 用户词汇一致），解释性文案用「红心 Radio」
「私人 FM」；**错误提示同时给两类词**（如「猜你喜欢（私人 FM）加载失败」）以免用户以为换了功能。

---

## 8. 边界与降级

| 场景 | 期望行为 | 现状 |
| --- | --- | --- |
| 未登录 | 不请求、不播放；点击 Toast 提示 | ✅（预览与启动均 gated） |
| 登录后恢复 | `auth.isRestoring` 期间不请求；`isLoggedIn` 变真后拉预览 | ✅（`_handleAuthChanged`） |
| 断网 | 预览失败静默（卡片留文案，点按再拉）；播放中失败走 fork 既有自动重试/跳过 | ✅ |
| 断网恢复 | `NetworkMonitor` 恢复 → 自动重播当前歌（`player_controller.dart:182-190`，会话因 `song==currentSong` 保留） | ✅（R3 补丁后更稳） |
| 边界（队列末） | 自动续批；失败提示 + 可重试 | ⚠️ R5 补丁 |
| 连续播放 | 无限续批；队列需软上限 | ❌ R4 |
| VIP/无版权歌 | `songUrl` 抛 `VipRequiredException` → fork 既有领 VIP 重试 → 仍失败则自动跳下一首（不计入 FM 特殊逻辑） | ✅ |
| 首曲就失败 | 连续 3 次失败后自动 `next()`；FM 队尾时会触发续批尝试新批 | ✅（受 R5 影响） |
| 会话中点别的歌 | 退出会话，普通播放 | ⚠️ R3 |
| 红心 | 可加/可取消，列表红心状态与 `_likedHashes` 一致 | ✅（`hash` 为主键） |
| 历史/统计 | 计一次播放/听歌时长，与普通歌一致 | ✅ |
| 多端并发（同账号另一设备换推荐池） | 服务端返回值变化，无需特殊处理 | ✅ |
| 应用重启 | 队列恢复为普通歌单语义（不续批） | ✅（R13 说明） |

---

## 9. 测试计划

### 9.1 已覆盖（lead 已提交）

- `test/models/song_from_personal_fm_test.dart`：完整字段、字段缺失降级、作者名兜底、union_cover 优先。
- `test/services/music_api_personal_fm_test.dart`：纯刷新只传 `mode/song_pool_id`、带反馈传 snake_case、
  按 hash 去重且单批 ≤5、空响应不抛错；`songUrl` 的 `hashOnly` 开/关参数。
- `test/controllers/player_personal_fm_test.dart`：有/无预览启动、空批错误态、队尾下一首续批并保持会话、
  中段线性前进、上一首线性回退、首曲回零、替换队列退出会话、同队列点歌保持会话、续批为空保留会话。

### 9.2 建议补充（按"能挡住一个真实 bug"排序）

| # | 层级 | 用例 | 对应风险 |
| --- | --- | --- | --- |
| T1 | 单测 `personalFm` | 失败信封（`status/error_code != 0`、无 `song_list`）→ 抛 `ApiException`，消息含错误码 | R1 |
| T2 | 单测 `personalFm` | 响应键为 `songlist` / 嵌套 `data.song_list` 时仍能解析（若采纳容错） | R1 |
| T3 | 单测 `PlayerController` | 会话中 `playSong(songOutOfQueue)`（无 queue）→ `isPersonalFmActive == false`，且随后 `next()` 走普通模式推进 | R3 |
| T4 | 单测 `PlayerController` | 模拟引擎 `completed`（`processingStateStream` 发 `completed`，参考 `player_completion_fallback_test.dart` 的 `_Engine`）→ 续批一次、`isOverplay=true`、新歌起播 | 续批主链路 |
| T5 | 单测 `PlayerController` | 续批抛错 → `errorMessage != null`、会话仍 active、再次 `next()` 可以成功续批（验证 `_completedSongHash` 复位） | R5 |
| T6 | 单测 `PlayerController` | 会话中 `cyclePlaybackMode()` 到 `singleLoop` 后自然播完 → 仍续批（不重播本曲）；`shuffle` 下 `next/previous` 仍线性 | §3.3 |
| T7 | 单测 `PlayerController` | 连续追加 30 批 → `queue.length` 受软上限约束、`currentIndex` 指向当前歌、`previous()` 仍可回退 30 首 | R4 |
| T8 | 单测 `Song.fromCache` 往返 | FM `Song`（id/albumAudioId/cover/duration）持久化-恢复不丢字段（历史/队列恢复前置） | R7/R13 |
| T9 | widget `home_page` | 未登录点卡片 → Toast、`api.personalFm` 未被调用；登录 → 预览首曲显示；点卡片 → `startPersonalFm(initialSongs: 预览)` 被调用一次 | C8 |
| T10 | widget `home_page` | FM active（fake player 返回 true + currentSong）→ 卡片显示当前歌名与 ⏸ hint | C8 |
| T11 | widget `home_page` | 手动刷新（双击首页/下拉）且 FM 未激活 → `personalFm` 调用次数 +1；FM 激活 → 不增加 | 2c1e07c 联动 |
| T12 | widget `home_page` | 每日推荐区块标题点击 → 进入 `PlaylistDetailPage`（`每日推荐` 文案） | R2 |
| T13 | widget 车机 | `_RecommendHeader` 在车机形态下渲染 FM 卡片；loading 态出现转圈且点按不触发 | R11 |
| T14 | 单测 `_resolvePlayUrl` 回退 | 非 FM 首次 `songUrl` 返回空地址 → 用 `hashOnly=true` 重试成功（若采纳 R7-A） | R7 |

> 测试替身统一改造见 R8；`_MockMusicApi` 增加 `personalFm` 计数与可控批次（`List<List<Song>> batches`
> 队列），便于 T3/T5/T7 断言调用次数。

### 9.3 手测清单（真机，必须）

1. 未登录：卡片不显示预览曲；点击弹 Toast；不产生 `/personal/fm` 请求（抓日志）。
2. 登录：卡片出现预览首曲与封面；点击秒播（不等网络）；播放页/通知栏信息正确（歌名/歌手/封面/时长）。
3. 连续听 ≥15 首（触发 2~3 次续批）：不重复、不中断、不回到第一批。
4. 队尾手动点「下一首」→ 续批且新歌起播；队尾暂停后再点播放 → 正常续播。
5. 会话中「上一首」多次 → 线性回退，首曲回零不退出。
6. 会话中在首页点其它歌单/搜索点歌 → FM 退出，普通队列播放；再点「猜你喜欢」→ 新会话。
7. 会话中从「已下载/本地/历史」点一首单曲 → 不应出现"播完停住"（R3 验收点）。
8. 断网 → 队尾续批失败提示可重试；恢复网络后点下一首可续批。
9. 车机模式：横屏卡片布局、播放/暂停、超宽屏并排布局、触控目标不误触。
10. 平板/窄屏（360dp）：hint 文案不截断关键字；字号放大（系统字体 1.3x）不溢出。
11. 红心：FM 中红心一首 → 我的-喜欢的音乐出现；取消红心生效（重启后仍一致）。
12. 播放历史：FM 听过的歌在历史页点播能出声（R7 验收点）。
13. 长会话（放 1 小时以上）：内存曲线平稳；退出重进 App 播放状态可恢复。
14. 桌面端（Windows/Linux）：卡片 hover/点击、双击刷新联动、迷你播放器/播放栏切歌正常。

---

## 10. 实施步骤与验收标准（按 commit 拆分）

> 现状：C1–C8 已落地（§5）。下表给出**推荐提交顺序**；`[TODO]` 为待补项。

| 顺序 | 建议 commit（中文提交信息） | 文件 | 验收标准 |
| --- | --- | --- | --- |
| 1 | `feat(fm): 猜你喜欢接入酷狗私人FM（模型/接口/会话核心）` | `song.dart`、`music_api_rank.dart`、`music_api_song.dart`、`player_controller*.dart` | `flutter analyze` 无 issue；3 个新增单测文件全绿；手测 1/2/3 通过 |
| 2 | `feat(home): 首页猜你喜欢卡片改为私人FM（预览/播放态/加载态）` | `home_page.dart`、相关 widget 测试替身 | 手测 1/2/9/10；T9/T10/T13 绿 |
| 3 | `feat(home): 刷新联动猜你喜欢预览` | `home_page.dart`（`onManualRefreshStart`） | T11 绿；手测双击刷新时 FM 未激活会换一批预览 |
| 4 `[TODO]` | `fix(home): 恢复每日推荐入口（猜你喜欢卡片改为FM后）` | `home_page.dart`（`_SongSection.onTitleTap`、`_openDailyRecommend`）、受影响的 widget 测试文案 | R2：每日推荐区块标题可点击进入歌单页；T12 绿；`find.text('大家都在听')` 全部更新 |
| 5 `[TODO]` | `fix(fm): 无队列点歌时退出私人FM会话` | `player_controller.playback.dart` | R3/T3 绿；手测 7 通过 |
| 6 `[TODO]` | `fix(fm): 空推荐响应的错误识别与容错键` | `music_api_rank.dart` | R1/T1/T2 绿；真机日志打印 keys 并确认 `song_list` |
| 7 `[TODO]` | `test: 首页/车机测试替身补齐私人FM成员` | 10 个测试文件（R8 清单） | `flutter test` 全绿 |
| 8 `[TODO]` | `fix(fm): 续批失败提示与完成标记复位` | `player_controller.personalfm.dart` | R5/T5 绿；手测 8 有 Toast 且可重试 |
| 9 `[TODO]` | `perf(fm): 私人FM队列软上限裁剪` | `player_controller.personalfm.dart` | R4/T7 绿；长会话内存平稳 |
| 10 `[TODO]` | `fix(fm): 播放历史回放私人FM歌曲时回退 hashOnly` | `player_controller.playback.dart` | R7/T14 + 手测 12 |
| 11 `[TODO]` | `feat(fm): 主动结束私人FM + 登出联动` | `player_controller.personalfm.dart`、`home_page.dart`、`queue_sheet.dart`/播放页入口 | R6；手测 6（主动结束）与登出场景 |
| 12 `[TODO]` | `fix(models): 推荐接口 time_length 宽容解析` | `model_parsing.dart`、`song.dart` | R9 单测（小数/字符串/空） |
| 13 可选 | `perf(audio): handler.play() 不再无界等待` | `music_audio_handler.dart` | R10；全量回归 + 手测 3/5 |
| 14 可选 | `feat(fm): 会话内播放模式提示` | `player_controller.queue.dart` | R12 |

**每个 commit 的通用验收**：`flutter analyze` 无 issue；`flutter test` 全绿；手测对应条目；不修改
`rust/`（若必须改，另起 commit 并 `cargo test` + 各平台重编动态库验证）。
**分支策略**：在同步分支上按序提交，每步可独立 revert；R1 的契约验证结论写进 commit message
（`personal/fm 响应确认为 song_list`），便于后续回溯。

---

## 11. 回退方案

| 级别 | 操作 | 影响 |
| --- | --- | --- |
| 单点回退 | revert §10 第 4–12 项任一 commit | 其余功能不受影响（各项独立） |
| 功能回退（推荐） | revert 第 1–3 项（控制器+卡片），恢复 `_FeatureShelf(daily/onDailyPlay/onDailyTap)` 与 `_openDailyRecommend` | 首页回到「猜你喜欢=每日推荐歌单」旧行为；测试替身若已改（R8）无副作用，可保留 |
| 紧急兜底（不改代码） | 服务端/账号侧：未登录用户不触发（已 gated）；或在 `home_page` 把卡片 `onPersonalFmPlay` 临时指向 `_openDailyRecommend` | 30 秒热修，用户体验回到旧版 |
| 不做 Rust 回退 | 本方案未改 Rust，无动态库回退需求 | —— |

**回退判定阈值**：真机验收出现「无法起播」「连续续批失败」「崩溃」任一，先 revert 第 1–3 项，
保留 R1 验证分支；不要在 FM 会话路径上叠加临时特判。

---

## 12. 附录

### 12.1 文件-行号索引（当前实现，main + 同步分支）

| 关注点 | 位置 |
| --- | --- |
| 模型 | `lib/models/song.dart:231`（`Song.fromPersonalFm`） |
| 接口 | `lib/services/music_api_rank.dart:19`（`personalFm`）；`lib/services/music_api_song.dart:53`（`hashOnly`） |
| 会话状态字段/契约 | `lib/controllers/player_controller.dart:533`（字段）、`:366`（getters）、`:896`（`playSong` 契约）、`:923`（`_nextSong` FM 分支） |
| 会话实现 | `lib/controllers/player_controller.personalfm.dart`（start/续批/去重/队尾判定/队列等价） |
| 播放保持与 hashOnly | `lib/controllers/player_controller.playback.dart:56`、`:611-666`、`:909` |
| 切歌导航 | `lib/controllers/player_controller.queue.dart:106`（next）、`:139`（previous） |
| 首页 | `lib/ui/pages/home_page.dart:167/778`（预览触发）、`:996`（刷新联动）、`:1002`（预览）、`:1032`（启动）、`:1869+`（卡片） |
| Rust 路由 | `rust/src/engine.rs:399-433`；`rust/src/services/discover.rs:273`；`rust/src/kugou/api_response.rs:64` |
| 契约定义 | `api.json`：`/personal/fm`（约 1658 行）、`PersonalFmResponse`/`PersonalFmSong`/`TransParam`/`SingerLite` |

### 12.2 上游对照命令

```bash
git show 33403a8 -- lib/services/music_api.dart lib/models/music_models.dart \
    lib/controllers/player_controller.dart lib/ui/pages/home_page.dart lib/services/music_audio_handler.dart
git show 2c1e07c -p          # 刷新联动 / hashOnly / id 映射 / 去重策略
git show 0194282 -p -- lib/controllers/player_controller.dart   # 会话保持启发式
git show bf264d9 -p -- lib/controllers/player_controller.dart   # _previousSong 的 FM 分支
git show main:api.json | sed -n '8742,8870p'                     # PersonalFm 契约
```

### 12.3 不做清单（避免范围蔓延）

- 上游 3.2 首页视觉改版（`LiquidGlassCard`、短视频热歌卡、推荐单曲卡网格）；
- 播放页小游戏 / 液态玻璃 / `player_game_enabled` 设置项；
- FM 模式切换（`mode=small` 小众、`mode=peak` 30s 速览、`song_pool_id=1/2` AI 池）——可作为后续
  设置项「猜你喜欢强度」，本方案固定 `normal` + `song_pool_id=0`；
- 「不喜欢/标记 garbage」（`action=garbage`）——服务端已支持（`api.json` 注释），但需要 UI 设计，
  建议独立 issue；
- FM 队列持久化续批（R13，接受现状）。
