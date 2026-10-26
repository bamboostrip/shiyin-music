# 上游同步第二批任务书（5 项功能/修复 + CI）

> 交接对象：接手开发的同学。
> 目标：按本文任务拆解，完成 5 项从上游 kgka_Music_hl 3.2.0 回移/补齐的工作。
> 本批不做：上游整体 merge、其余暂缓项（见 [triage 文档](./2026-10-26-upstream-3.2.0-triage.md)）、`/top/card` 之外的推荐流扩展。
>
> 配套文档（先读）：
> - [2026-10-26-upstream-sync-3.2.0-handoff.md](./2026-10-26-upstream-sync-3.2.0-handoff.md)：上一批已同步内容、验证方式、仓库架构差异
> - [2026-10-26-upstream-3.2.0-triage.md](./2026-10-26-upstream-3.2.0-triage.md)：108 个上游提交逐条梳理（本批任务对应 P1-1/P1-2/P1-3/P2 部分）

---

## 0. 开工前必读（基线与环境）

### 0.1 代码基线

- 仓库：`D:\AllCode\flutter\shiyin-music`（远程 `origin` = bamboostrip/shiyin-music，`upstream` = umr-xiaomai/kgka_Music_hl）。
- **基线分支：`chore/sync-upstream-3.2.0`**（已推送 origin）。该分支已包含上一批同步：猜你喜欢私人 FM、歌词解析/候选兜底、播放缓存流量优化，以及测试替身适配。
- 本批每个任务从该分支切独立分支开发，示例：
  - 任务 1：`feat/local-lyrics-matching`
  - 任务 2：`feat/qq-playlist-import`
  - 任务 3：`feat/home-recommend-cards`
  - 任务 4：`fix/ios-status-bar`
  - 任务 5：`ci/flutter-test`
- 若 `chore/sync-upstream-3.2.0` 尚未合并进 `main`，先在该分支上工作，不要直接基于旧 `main`（`main` 与同步分支在 `home_page.dart`/`player_controller*.dart` 上有差异，基于旧 main 会产生无谓冲突）。

### 0.2 本地环境

- Flutter：`3.44.8 stable`（与仓库 CI workflow `FLUTTER_VERSION` 一致）；Dart SDK `^3.11.5`。
- Rust：`cd rust && cargo check --offline && cargo fmt --check`（本批仅任务 3 改 Rust 路由）。
- 上游代码查阅：`git fetch upstream` 后 `git show <hash>` / `git show upstream/master:<path>`。

### 0.3 基线验证（开工前先跑一遍，确认环境正常）

```bash
flutter pub get
flutter analyze --no-pub              # 期望：No issues found
flutter test                          # 期望：All tests passed（基线 1218 passed / 1 skipped）
```

### 0.4 通用硬性规则（每个任务都要遵守）

1. **不整分支 merge 上游**。本 fork 已去后端化 + 重写首页/播放页/设置页/音频链路，按功能回移，禁止整文件覆盖上游版本。
2. **酷狗接口必须走 Rust engine**：Dart 侧只经 `ApiClientInterface`（`lib/core/api_client_interface.dart`）→ `rust/src/engine.rs` 路由。禁止 Dart 直连酷狗、禁止在 Dart 里做签名。
   - 唯一例外：任务 2 的 QQ 公开接口直连（见任务 2 说明，无需登录、不涉酷狗）。
3. **不引入 `audio_metadata_reader`**：本 fork 内嵌歌词读取已由 Rust `readLocalLyrics`（`rust/src/api.rs:101`）+ Android MethodChannel 提供；任务 1 允许按需新增 `charset` 依赖（GBK `.lrc` 解码）。
4. **不要动上一批已验证的功能**：`lib/controllers/player_controller.personalfm.dart`、猜你喜欢卡片/每日推荐次级入口、歌词解析器（`music_api_lyric_parser.dart`）、`songUrl hashOnly` 等，避免回归。任务 3 的「推荐歌曲」横轨是新增区块，不要挤压/改动猜你喜欢卡片。
5. **每个任务独立提交/PR**，使用仓库既有 conventional commit 风格（中文 body 可）：
   - `feat(lyrics): ...`、`feat(import): ...`、`feat(home): ...`、`fix(ios): ...`、`ci: ...`
6. **完成定义（DoD）**（每个任务都必须满足）：
   - `flutter analyze --no-pub` → No issues found
   - 全量 `flutter test` 通过（不得低于基线 1218 passed / 1 skipped；新增测试计入）
   - 新增/更新的单测（模板见各任务「测试」）
   - `update.md` 的「未发布」段补充对应条目
   - 手测记录（模板见附录 C）
   - 涉及 Rust：`cargo check --offline`、`cargo fmt --check` 通过
7. 不新增无关重构/格式化；不改 `packages/` 下 vendored 代码；不改 `.github/workflows` 中已存在的 4 条构建流水线（任务 5 只新增一条校验流水线）。

---

## 1. 任务总览

| # | 任务 | 上游参考 | 预估 | 依赖 | 建议分支 |
|---|---|---|---|---|---|
| 1 | 本地歌曲歌词匹配与缓存 | `87c35a1` + `c60a92f` | 1.5–2.5 天 | 无 | `feat/local-lyrics-matching` |
| 2 | QQ 歌单导入匹配增强 | `dc92cfd` + `c60a92f` | 2–3 天 | 任务 1 的 `local_song_matcher.dart`（可先 cherry-pick/复制） | `feat/qq-playlist-import` |
| 3 | 首页「推荐歌曲」6 组（`/top/card`） | `f230444` + `62ae541` | 2–3 天 | 无（Rust 已有 `top_card` 实现，仅需接路由） | `feat/home-recommend-cards` |
| 4 | iOS 状态栏两行修复 + AppBarTheme `systemOverlayStyle` | `bc90352` / `98ef8e1` / `03737b5` | <0.5 天 | 无 | `fix/ios-status-bar` |
| 5 | CI 补 `flutter test`（+ analyze） | `f955d9a` 的 CI 部分 | <0.5 天 | 无 | `ci/flutter-test` |

**建议实施顺序**：4 → 5（快速见效、低风险）→ 1 → 2（复用 matcher）→ 3（Rust + UI 最重）。
允许并行：4/5 可与 1/3 并行；2 必须在 1 的 `local_song_matcher.dart` 落地后合并（或提前复制该文件）。

---

## 2. 任务 1：本地歌曲歌词匹配与缓存

### 2.1 背景与价值

本地音乐（`SongSource.local`）当前歌词来源只有两条：同名 `.lrc` 文件、音频内嵌歌词。大多数本地歌两者都没有，导致「本地音乐没歌词」。上游 3.2.0 增加了「按元数据匹配酷狗同名歌曲 → 拉在线歌词 → 缓存」链路，本地音乐用户价值高。

### 2.2 fork 现状（关键代码位置，行号可能漂移）

- `lib/controllers/player_controller.lyrics.dart` 的 `loadLyrics()`（约 L32）：本地歌分支目前为
  1) 同名 `.lrc`（仅 UTF-8 解码，失败 `allowMalformed`）；
  2) `localMusic?.getEmbeddedLyrics(song.id)`（Android MethodChannel / 桌面 Rust `readLocalLyrics`）；
  3) 都没有 → `lyrics = const []` 并返回。
- `lib/controllers/local_music_controller.dart:253` `getEmbeddedLyrics()`。
- `lib/services/music_api_search.dart:37` `Future<List<Song>> searchSongs(String keywords, {int page = 1, int pageSize = 30})`（内部已过滤不可播放结果，走 Rust `/search`）。
- `lib/services/music_api_lyric.dart` `Future<List<LyricLine>> lyrics(Song song)`（按 hash 查 KRC/LRC）。
- `lib/services/cache_service.dart:48/79` `CacheService.read<T>(key, {required decode, ttl})` / `write(key, Map payload)`，底层 SharedPreferences，带 `savedAt/payload` 包装。
- `lib/models/song.dart:926/935` `LyricLine.toCache()` / `LyricLine.fromCache()` 已有。
- 上游参考实现：`git show 87c35a1:lib/services/local_song_matcher.dart`、`git show 87c35a1:lib/services/local_lyrics_service.dart`。

### 2.3 实现要求

1. **新增 `lib/services/local_song_matcher.dart`**（移植上游，适配 fork）：
   - `LocalSongIdentity`：title/artist/duration；从 `Song` 构造时清洗：未知值归空、文件名去扩展名、文件名 `歌手 - 歌名` 拆分、`stripArtistNamePrefix`（fork 用 `cleanSongTitle`/等价逻辑）。
   - `query`（`"artist title"`）、`isSearchable`。
   - `matchCandidates(List<Song>)` 打分规则（照上游，宁缺毋滥）：
     - 只接受 `song.source == SongSource.kugou && song.hash.isNotEmpty`；
     - 标题 normalize 后必须完全相等；
     - 已知歌手：候选歌手集合需包含全部期望歌手；未知歌手：必须有时长且差值 ≤ 3s；
     - 有时长时差值 > 8s 丢弃；按时长差升序返回。
2. **在线匹配与缓存**（建议独立 service 便于单测，也可作为 lyrics mixin 内的私有方法；推荐 `lib/services/local_lyrics_service.dart`）：
   - 输入 `Song`（local）、`MusicApi`、`CacheService?`；
   - 步骤：
     a. 计算 `signature = [title, artist, durationMs, fileSize, fileModifiedMs]`（文件替换/改名后缓存失效）；
     b. 缓存 key 建议 `cache_local_lyric_v1_<文件绝对路径的稳定哈希>`（不要直接拼路径当 key，避免超长）；先读缓存，payload 含 `signature/matchedHash/lines(LyricLine.toCache)`，signature 不匹配视为未命中；TTL 可设 30 天或忽略 TTL（本地文件不变就一直可用，与上游一致）；
     c. `identity.isSearchable` → `searchSongs(identity.query, pageSize: 20).timeout(10s)` → `matchCandidates().take(3)` 逐个 `api.lyrics(candidate).timeout(10s)`，首个非空即返回并写缓存；
     d. 全部失败 → 返回空（不抛错，不影响播放）。
   - 在 `loadLyrics()` 本地分支「内嵌歌词失败」后调用；成功后与现有逻辑一致：`currentSong?.hash == song.hash` 守卫 → `lyrics = lines; notifyListeners(); _syncDesktopLyrics();`。
   - 防止重复请求：同一首歌并发调用 `loadLyrics` 时加 in-flight 去重（参考 `_lyricsFetchInFlightHash` 的现有做法）。
3. **`.lrc` 编码增强**（推荐做）：移植上游 `decodeLocalLyricBytes`：UTF-16 BOM（LE/BE）→ UTF-8（严格）→ GBK fallback。需要 `charset: ^2.0.1`（`pubspec.yaml`；本批唯一允许新增依赖）。若不加依赖，退化为 UTF-8+allowMalformed 并在 PR 说明取舍。
4. 不改播放主链路、不改歌词渲染；网络失败/超时只记录 `debugPrint`。

### 2.4 测试要求

- `test/services/local_song_matcher_test.dart`：标题/歌手前缀剥离、文件名拆分、未知歌手+时长阈值、Live/伴奏/Remix 保留、时长差排序、非酷狗/空 hash 过滤。
- `test/services/local_lyrics_service_test.dart`：
  - fake api（`searchSongs`/`lyrics`）+ fake cache；
  - 顺序：`.lrc` 命中不请求网络（若 service 覆盖该层）→ 内嵌命中不请求 → 在线匹配 → 缓存命中（同 signature 不发请求）→ signature 变化重新匹配 → 搜索失败静默空 → 首个候选歌词为空继续下一个 → 超时不崩。
- 编码单测：UTF-8 / UTF-16LE / UTF-16BE / GBK（`decodeLocalLyricBytes`）。
- 可复用上游用例与 fixture：
  ```bash
  git show 87c35a1:test/fixtures/lyrics.mp3  > test/fixtures/lyrics.mp3
  git show 87c35a1:test/fixtures/lyrics.flac > test/fixtures/lyrics.flac
  git show 87c35a1:test/local_lyrics_test.dart   # 参考，按 fork 实现改写
  ```
  （注意：`test/fixtures/` 若不存在需新建；二进制文件要能正常 git add 提交。）

### 2.5 验收标准

- `flutter analyze` 无问题；新增测试 + 全量 `flutter test` 通过。
- 手测（Android 与 Windows 桌面各一遍）：
  - 本地无 `.lrc`/内嵌歌词、酷狗有同名的歌 → 进入播放页后出现歌词；
  - 修改本地文件（替换/改名）后重进 → 缓存失效并重新匹配；
  - 飞行模式 → 无歌词、不报错、不阻塞播放；
  - 原本有 `.lrc`/内嵌歌词的歌行为不变（仍优先本地）。

### 2.6 风险与注意

- 匹配错误是最大风险（同名不同版本）：严格标题 + 歌手/时长阈值，宁缺毋滥；不要放宽到「取第一个搜索结果」。
- `CacheService` 基于 SharedPreferences，单首歌词 JSON 约 5–50KB 可接受；若后续发现写放大明显，可改为文件缓存（不在本任务范围）。
- 歌词接口可能因权限返回空/VIP 限制，属正常降级。

---

## 3. 任务 2：QQ 歌单导入匹配增强

### 3.1 背景与价值

当前导入面板（fork 已有）解析分享链接后只有**纯歌名**，匹配逻辑是「按歌名搜索取第一个有 hash 的结果」，同名异版/翻唱/纯音乐场景大量导错歌、漏导。上游 3.2.0 改为：
- QQ 分享链接**直连 QQ 公开接口**解析，拿到「歌名 + 歌手 + 时长」；
- 用统一 matcher 打分匹配酷狗歌曲；
- 导入流程支持去重、未匹配/失败清单、进度、取消。

### 3.2 fork 现状

- 入口：`lib/ui/pages/playlist_detail_page.dart:1361`（`showImportPlaylistSheet`）。
- `lib/ui/widgets/import_playlist_sheet.dart`：`_parse()` → `api.parseExternalPlaylist(text)`；`_matchSong(String name)`（约 L138）按歌名 `searchSongs(keyword, pageSize: 5)` 取第一个 hash 非空；逐首 `addSongsToPlaylist(listId, [song])`；仅有 `_matched/_done/_total`。
- `lib/models/netease_external.dart:94` `ExternalPlaylistParseResult` 仅 `sourcePlatform/playlistName/songNames`。
- `lib/services/music_api_playlist.dart:134` `parseExternalPlaylist()` 调 Rust `/playlist/external/parse`（`rust/src/services/external_playlist.rs` 已支持网易云/QQ 分享链接，但只返回 `songNames`）。
- 已有能力：`searchSongs`、`createPlaylist`、`addSongsToPlaylist(listId, List<Song>)`、`auth.playlists`（自建歌单列表）、`auth.isLoggedIn`。
- 上游实现参考：
  ```bash
  git show dc92cfd:lib/services/qq_playlist_service.dart
  git show dc92cfd:lib/services/playlist_import_service.dart
  git show dc92cfd:lib/services/local_song_matcher.dart
  git show dc92cfd -- lib/ui/widgets/import_playlist_sheet.dart
  git show dc92cfd:test/playlist_import_test.dart
  ```

### 3.3 实现要求

1. **模型扩展**（`lib/models/netease_external.dart`）：
   - 新增 `ExternalPlaylistTrack { title, artist, duration, displayName }`；
   - `ExternalPlaylistParseResult` 增加 `tracks`（默认 const []）、`totalSongCount`、`importTracks`（`tracks` 为空时回退 `songNames.map(title)`，兼容旧 Rust 返回）；`fromJson` 同时解析 `tracks`（可选字段，缺失不影响）。
2. **新增 `lib/services/qq_playlist_service.dart`**（移植上游，注入 `http.Client` 便于测试）：
   - `static Uri? shareUri(String text)`：从任意分享文本中提取 QQ 音乐链接（host 白名单 `y.qq.com` / `*.y.qq.com`，拒绝 userInfo、非 http(s)）；
   - `_resolveId`：最多跟随 6 跳 302，解析 `disstid` / `id` / `/playlist/(\d+)`；
   - `load(Uri share)`：请求 `u.y.qq.com/cgi-bin/musicu.fcg`（`music.srfDissInfo.aiDissInfo` / `uniform_get_Dissinfo`，带 `Referer: https://y.qq.com/`、15s 超时），分页（上限 100 页）取 `songlist`，字段：`name`（标题）、`singer[].name`（歌手，join ' / '）、`interval`（秒）→ `ExternalPlaylistTrack`；去重（同标题+歌手）；空页/新增为 0 时报错防死循环；`totalSongCount` 回填。
3. **`MusicApi.parseExternalPlaylist` 增加 QQ 直连分支**（`lib/services/music_api_playlist.dart`）：
   - 先 `QqPlaylistService.shareUri(text)`，非空则用 `http.Client()` 调 `load`（用后 `close`）；否则保持现有 Rust `/playlist/external/parse`（网易云等）。
   - 代码注释写明：QQ 公开接口无需登录、非酷狗接口，故允许 Dart 直连；酷狗请求仍必须走 engine。
4. **新增 `lib/services/playlist_import_service.dart`**（移植上游）：
   - `match(ExternalPlaylistTrack)`：`LocalSongIdentity(title, artist, duration)` → `searchSongs(identity.query, pageSize: 20).timeout(20s)` → `matchCandidates` 取首个；旧数据（无歌手无时长）要求标题完全相等，避免静默导错。
   - `import({listId, tracks, existingHashes, onProgress, shouldCancel})`：逐首 match → 已存在 hash 计 duplicate → `addSongsToPlaylist(listId, [song])`（写操作不要加超时；失败计 failed）→ 进度快照（processed/added/duplicates/unmatched/failed）→ `shouldCancel()` 每首检查、写操作完成后停止。
   - 复用任务 1 的 `local_song_matcher.dart`（若任务 1 未先行，先复制该文件并标注来源）。
5. **重写 `lib/ui/widgets/import_playlist_sheet.dart`**（保留 fork 设计风格：`design_tokens.dart`/`toast.dart`，不要照抄上游 UI）：
   - 流程：输入 → 解析中 → 已解析（显示平台/歌单名/总曲数）→ 选择目标歌单（已有自建歌单 / 新建并输入名称）→ 导入中（进度 + 取消按钮）→ 完成（成功/重复/未匹配/失败清单，未匹配可复制）。
   - 未登录：提示先登录酷狗账号，禁止写操作。
   - 失败处理：解析失败显示原因并保留输入；导入中失败不清空已成功部分。
6. **入口**：保留 `playlist_detail_page` 现有入口；可选在「我的」歌单区增加「导入 QQ / 网易云歌单」按钮（上游 `library_page` +13 行），按 fork 我的页面结构决定，非必需。

### 3.4 测试要求

- `test/services/qq_playlist_service_test.dart`（不联网，MockClient）：
  - `shareUri`：纯链接/带文案/短链/非 QQ 域名/恶意 userInfo；
  - `_playlistId`：`disstid`、`id`、路径 `/playlist/123`；
  - 302 解析（MockClient 返回 Location）；
  - 分页：多页合并、`songlist` 字段 title/artist/interval 正确、空页停止、重复曲目去重、超页上限报错、空歌单报错。
- `test/services/playlist_import_service_test.dart`（fake `MusicApi`）：
  - 匹配成功 / 无匹配 / duplicate（existingHashes 大小写）/ 添加失败 →
    `added/duplicates/unmatched/failed` 分类正确；
  - `shouldCancel` 中途取消后不再新增；
  - 进度回调次数/字段。
- `test/ui/widgets/import_playlist_sheet_test.dart`：解析 → 选择新歌单 → 导入（fake api/注入 service）→ 完成态展示；未登录提示。
- 参考上游 `test/playlist_import_test.dart`（421 行）改写为 fork 版。

### 3.5 验收标准

- `flutter analyze` 无问题；新增测试 + 全量 `flutter test` 通过。
- 手测（真实公开 QQ 歌单分享链接，需登录酷狗账号）：
  - 解析出歌单名与总曲数，导入到新建歌单/已有歌单成功；
  - 未匹配歌曲有清单，不再「导错同名歌」明显（抽查 10 首）；
  - 取消按钮生效；重复导入不重复添加；网易云链接仍可用。
- 导入 1000 首以内不失败、UI 不卡死（进度可见；必要时 `addSongsToPlaylist` 分批 50 首/批）。

### 3.6 风险与注意

- QQ 公开接口可能改版/风控（Referer、频率、短链跳转）：做好错误提示，测试用 MockClient，真实网络只做手测。
- 请求频率：每首 1 次 search + 1 次 add；大歌单可加 100–200ms 间隔或批量 add（`addSongsToPlaylist` 支持 List），PR 说明实测耗时。
- 歌单曲目解析结果依赖 QQ 接口字段（`singer` 可能是 `singer` 数组/对象），按上游实现处理并加容错。
- 不要修改 Rust `/playlist/external/parse`（网易云继续走它）；QQ 改走 Dart 直连，这是本任务刻意保留的双路径。

---

## 4. 任务 3：首页「推荐歌曲」6 组（`/top/card`）

### 4.1 背景与价值

上游 3.2.0 之前新增了首页「推荐歌曲」6 组横滑卡（私人专属好歌 / 经典怀旧金曲 / 热门好歌精选 / 小众宝藏佳作 / 潮流尝鲜 / VIP 专属推荐），数据来自酷狗 `/top/card` 的 6 个 card_id。fork 缺失该功能，属于推荐流增强。

### 4.2 重要发现（Rust 已有实现，别重复造轮子）

- `rust/src/services/discover.rs:165` 已有 `pub async fn top_card(client, session, card_id) -> AppResult<Value>`（当前带 `#[allow(dead_code)]`），请求酷狗 `singlecardrec.service/v1/single_card_recommend`，与上游 .NET 后端 `/top/card` 同源。
- `rust/src/engine.rs` 路由表 **缺少** `("GET", "/top/card")`，本任务只需补路由（字符串路由，**无需重新生成 FRB**）。
- 后端契约：`api.json:1519` `/top/card` GET 参数 `card_id`（默认 1）；上游 Dart 解析响应根上的 `song_list` 与 `rec_desc`（`transport` 已把 `data` 提升为根）。
- 上游参考：
  ```bash
  git show f230444    # 6 组推荐（models/music_api/home_page/playlist_detail）
  git show 62ae541    # /top/card time_length 为小数秒的时长解析修复
  git show f230444:lib/services/music_api.dart | sed -n '/recommendedSongCards/,/^  }/p'
  ```

### 4.3 实现步骤

1. **Rust 路由**（`rust/src/engine.rs`，插在 `/top/album` 附近）：
   ```rust
   ("GET", "/top/card") => {
       let card_id = params.get("card_id")
           .and_then(|s| s.parse().ok())
           .unwrap_or(1i64);
       discover::top_card(client, session, card_id).await
   }
   ```
   同时移除 `discover.rs` 中 `top_card` 上的 `#[allow(dead_code)]`。
   验证：`cd rust && cargo check --offline && cargo fmt --check`。**不需要** `flutter_rust_bridge_codegen generate`。
2. **Dart API**（`lib/services/music_api_rank.dart`，跟随现有 method 风格）：
   ```dart
   Future<List<RecommendedSongCard>> recommendedSongCards() async {
     const definitions = <(int, String)>[
       (1, '私人专属好歌'), (2, '经典怀旧金曲'), (3, '热门好歌精选'),
       (4, '小众宝藏佳作'), (5, '潮流尝鲜'), (6, 'VIP 专属推荐'),
     ];
     final cards = await Future.wait(definitions.map((d) async {
       try {
         final json = asMap(await _client.get('/top/card', {'card_id': d.$1}));
         final card = RecommendedSongCard.fromJson(
           cardId: d.$1, title: d.$2, json: json,
         );
         return card.songs.isEmpty ? null : card;
       } catch (_) { return null; }   // 单组失败不影响整组/首页
     }));
     return cards.whereType<RecommendedSongCard>().toList();
   }
   ```
3. **模型**：
   - `lib/models/song.dart` 增加 `Song.fromTopCard`（照上游，但 fork 无 `releaseDate` 字段：省略；标题用 `cleanSongTitle`；`id: mixSongId ?? songId ?? hash`、`albumAudioId: mixSongId ?? songId`、`coverUrl: sizable_cover`、`duration: durationFromTopCardSeconds(time_length)`）。
   - `lib/models/model_parsing.dart` 增加 `durationFromTopCardSeconds(Object?)`（小数秒 → 毫秒，上游 62ae541 修复，必带）。
   - 新文件 `lib/models/recommend_card.dart`：`RecommendedSongCard { cardId, title, description, coverUrl, songs, songSummary }` + `fromJson/fromCache/toCache`（照上游）；在 `lib/models/music_models.dart` barrel 增加 `export 'recommend_card.dart';`。
4. **首页数据**（`lib/ui/pages/home_page.dart`）：
   - `HomeData`（约 L4259）加 `final List<RecommendedSongCard> recommendedSongCards;`（默认 const []）。
   - `decodeCache`（约 L853）/`encodeCache`（约 L869）/`hasContent`（约 L878）同步该字段（缓存 key `recommendedSongCards`）。
   - `fetchData`（约 L884）的 `Future.wait` 加一项：`_loadRecommendedSongCardsSafe()`（try/catch 返回 const []，参考现有 `_loadTopSongsSafe()` 模式）。
   - UI：新增 `_RecommendedSongCardRail`（复用 `AppHorizontalRail`，`lib/ui/widgets/app_section.dart:58`）：
     - 标题「推荐歌曲」；单元卡 120×~150：封面 + 歌单标题 + `songSummary`/描述截断；
     - 点击 → `PlaylistDetailPage(playlist: PlaylistSummary(id: 'recommended-card-${card.cardId}', title: card.title, subtitle: desc/summary, coverUrl: card.coverUrl, songCount: card.songs.length), initialSongs: card.songs, readOnly: true)`；
     - 放置位置：推荐 tab 现有内容之后（「大家都在听」/「新歌速递」之后都可，建议紧邻「大家都在听」下方），手机 sliver、车机 Column、桌面宽窗 `asSlivers` 懒构建三种形态都要接（参考 `_TopSongRail` 的 `asSlivers` 写法与间距规范）。
5. **PlaylistDetailPage 静态集合支持**（`lib/ui/pages/playlist_detail_page.dart`）：
   - 新增 `this.readOnly = false;` 参数；`_isStaticCollection = widget.initialSongs?.isNotEmpty == true`（通用化，不再仅 `_isDailyRecommend`）。
   - 静态集合：直接用 `initialSongs` 填充，不请求 `_loadAllSongs`/相似歌单/收藏状态/编辑操作；`readOnly` 隐藏收藏/编辑/更多入口。
   - 现有「每日推荐」分支的 initialSongs 兜底逻辑改为复用该通用分支（注意回归现有行为）。
6. **测试替身修复（重要）**：所有渲染 `HomePage` 的测试里 `_FakeMusicApi implements MusicApi`（用 `noSuchMethod` 兜底）会在 `fetchData` 调用 `recommendedSongCards()` 时抛错，导致大批测试失败。需给这些 fake 增加：
   ```dart
   @override
   Future<List<RecommendedSongCard>> recommendedSongCards() async => const [];
   ```
   涉及（以全量测试实际报错为准）：`home_desktop_refresh_test`、`home_sections_navigation_test`、`home_header_tab_switch_test`、`home_page_tabs_swipe_test`、`home_scroll_to_top_test`、`home_desktop_lazy_sections_test`、`car_mode_tab_restore_test`、`car_display_integration_test`、`car_recommend_equalizer_test` 等。

### 4.4 测试要求

- `test/models/song_from_top_card_test.dart`：完整字段、hash 空过滤、时长小数秒（259.16s → 259160ms）、封面归一化、title 清洗。
- `test/services/recommended_song_cards_test.dart`：fake `ApiClientInterface` 记录 6 次 `/top/card` 请求（card_id 1..6）；某组抛错时其余组正常返回；空 `song_list` 组被过滤；`rec_desc` 进 description。
- Home 数据缓存 roundtrip：`encodeCache/decodeCache` 含新字段（可直接在现有 home 测试里补断言）。
- 跑全量测试确认 fake 修复无遗漏。

### 4.5 验收标准

- `cargo check/fmt` 通过；`flutter analyze` 无问题；全量 `flutter test` 通过。
- 手测：登录态首页出现「推荐歌曲」6 组横滑；点击进入只读歌单页且可播放/加队列；未登录或单组接口失败时其余组正常/整体降级不报错；手机/车机/桌面宽窗布局正常；深色模式正常。

### 4.6 风险与注意

- `/top/card` 可能要求登录态：未登录返回空 → rail 不显示（可接受，不要报错弹窗）。
- Rust 返回形态未真机验证：先按上游 `song_list`/`rec_desc` 实现；如实际嵌套在其他字段，用临时日志确认后调整（优先在 Rust 侧解包对齐）。
- 不要把 6 组请求串行（`Future.wait` 并发）+ 每组单独 `try/catch`，避免一组失败拖垮首页首屏。
- 首页 `_checkAndAutoPlay` 逻辑与 `HomeData` 构造会受影响：加字段后务必跑全量测试。

---

## 5. 任务 4：iOS 状态栏两行修复 + AppBarTheme `systemOverlayStyle`

### 5.1 背景

Flutter 中：
- `statusBarIconBrightness`（Android）描述**前景**（图标/文字）明暗；
- `statusBarBrightness`（iOS）描述**背景**明暗，系统据此自动选反色前景。
两者语义相反，必须取镜像值。fork 有多处写成同向，导致 iOS 浅色页面白字白底（不可见）、深色页面黑字黑底。

### 5.2 现状与修改清单（fork 当前）

| 文件 | 现状 | 修改 |
|---|---|---|
| `lib/main.dart:702-705` | `statusBarBrightness: isDark ? light : dark`（与 icon 同向） | 改为 `statusBarBrightness: isDark ? Brightness.dark : Brightness.light` |
| `lib/ui/pages/comment_page.dart:17-20` | 两值同向 | 同上反转 `statusBarBrightness` |
| `lib/ui/pages/player_page.dart:316-319` | `statusBarIconBrightness: light; statusBarBrightness: light`（播放页固定深色底） | `statusBarBrightness: Brightness.dark`（深色背景 → iOS 白字） |
| `lib/ui/app_theme.dart:106-114` | `AppBarTheme` 无 `systemOverlayStyle`（背景 transparent 会推断深色 → iOS 白字不可见） | 补 `systemOverlayStyle`（见下） |
| 已正确、勿改 | `settings_page.dart:224-228`、`audio_effects_sheet.dart:41-45`、`audio_interruption_settings_page.dart:18-22` | 对照参考，已是镜像值 |

`app_theme.dart` 修改（需 `import 'package:flutter/services.dart';`）：
```dart
appBarTheme: AppBarTheme(
  // ...现有字段不动...
  systemOverlayStyle: SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    // iOS：描述背景明暗；浅色背景用 light（黑字）
    statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    // Android：描述前景图标/文字明暗，与上者相反
    statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    systemNavigationBarColor: scheme.surface,
    systemNavigationBarIconBrightness:
        isDark ? Brightness.light : Brightness.dark,
  ),
),
```
（注意 `AppTheme` 内已有的 `isDark`/`scheme` 变量名以实际代码为准。）

- fork 没有 `status_bar_overlay.dart` 组件（上游后来新增），**不引入**；逐页修即可。其余 `AnnotatedRegion<SystemUiOverlayStyle>` 站点用 `git grep -n 'statusBarBrightness:' lib` 扫一遍，确认无同向写法遗漏。

### 5.3 测试要求

- 新增 `test/ui/app_theme_overlay_test.dart`（纯 Dart，无需 iOS 运行环境）：
  - 用 `AppTheme.build(...)`（或现有主题构建入口）分别构建 light/dark `ThemeData`，断言 `appBarTheme.systemOverlayStyle!.statusBarBrightness` 与 `statusBarIconBrightness` 互为镜像；
  - 断言 `systemNavigationBarColor` 与主题 surface 一致。
- 全量 `flutter test` 无回归（主题相关测试 `test/theme_mode_test.dart` 等）。

### 5.4 验收标准

- `flutter analyze` 无问题；全量测试通过。
- iOS 手测（模拟器/真机，若手头没有 iOS 设备则在 PR 注明「未在 iOS 实机验证」并请有设备的人复核）：
  - 浅色主题：设置、已下载、本地音乐、播放历史、评论、播放页状态栏文字为深色可见；深色主题为浅色可见；
  - AppBar 页面标题栏不再出现白字白底。
- Android 不受影响（`statusBarBrightness` 仅 iOS 生效；Android 多出 systemNavigationBar 样式属预期）。

### 5.5 风险

- 极低，纯视觉；唯一风险是漏掉某处同向写法，用 `git grep 'statusBarBrightness:' lib` 全量核对。

---

## 6. 任务 5：CI 补 `flutter test`（+ analyze）

### 6.1 背景

fork 现有 `.github/workflows/` 只有 `build-android.yml` / `build-linux.yml` / `build-windows.yml` / `publish-release.yml`，均为 tag/手动触发的打包流水线，**没有 PR 校验**（无 analyze/test），上游 `f955d9a` 已把 `flutter test` 纳入 CI。本任务新增一条独立校验流水线。

### 6.2 实现要求

新建 `.github/workflows/flutter-ci.yml`：

```yaml
name: Flutter Analyze & Test

# PR / 主干推送时做静态检查与单测；打包仍由 build-*.yml 在 tag 时负责。
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

# 同一分支新提交取消上一次运行，省 Actions 额度。
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

env:
  FLUTTER_VERSION: '3.44.8'

jobs:
  verify:
    name: analyze + test
    runs-on: ubuntu-latest
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@v4

      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_VERSION }}
          channel: stable
          cache: true

      - name: Disable analytics
        run: flutter config --no-analytics

      - name: Cache pub packages
        uses: actions/cache@v4
        with:
          path: ~/.pub-cache
          key: pub-${{ runner.os }}-${{ hashFiles('pubspec.lock') }}
          restore-keys: |
            pub-${{ runner.os }}-

      - name: Pub get
        run: flutter pub get

      - name: Analyze
        run: flutter analyze --no-fatal-infos --no-fatal-warnings

      - name: Test
        run: flutter test
```

要求：
- 触发分支写 `main`（fork 主分支；不要照抄上游 `master`）。
- 不修改现有 4 条打包 workflow；不改 tag/release 流程。
- 首次跑通后确认：PR 页面出现 `analyze + test` check，全绿，缓存命中后总时长 < ~10 分钟。
- 若 Linux runner 上出现个别平台相关用例失败（Windows 特有路径/字体/FFI 等），**先定位原因**：能用 `skip: Platform.isWindows` / 条件跳过并注明原因的才跳过；禁止整文件/整组跳过；修复后重跑。
- 注意：Dart 单测不初始化 Rust FFI，`flutter test` 不需要构建 Rust（与本地一致的 1218 passed / 1 skipped 基线）；如 CI 报 RustLib/FFI 相关失败，检查是否新测试引用了未 stub 的 Rust 调用。

### 6.3 验收标准

- 新建 workflow 在 PR 上实际运行一次并全绿（可用本批某个任务分支开 PR 验证）。
- `flutter analyze` 与 `flutter test` 均执行；失败时能定位到具体命令。
- 文档：在 `docs/release-process.md` 或 PR 描述中说明新增的 CI 校验与触发条件（可选，推荐）。

### 6.4 风险

- Actions 额度/排队：`concurrency` + pub cache 已缓解；如担心成本，可将 `flutter test` 只在 `pull_request` 与 `push main` 触发（本模板已如此）。
- CI 与本地平台差异：以 PR 实测为准；不要为了让 CI 变绿而降低测试覆盖。

---

## 7. 实施顺序、里程碑与依赖

```
第 1 天    任务 4（iOS 状态栏）+ 任务 5（CI）     → 各开 PR
第 2-4 天  任务 1（本地歌词匹配）                  → matcher 落地后合入
第 4-6 天  任务 2（QQ 歌单导入，复用 matcher）
第 6-8 天  任务 3（/top/card 6 组推荐，Rust + 首页 UI）
第 8-9 天  全量回归 + 手测 + 收尾（update.md / PR 汇总）
```

- 任务 1 与 2 强依赖：`lib/services/local_song_matcher.dart` 只允许有一份实现（由任务 1 提供；任务 2 从任务 1 分支 cherry-pick 或等其合并后再 rebase）。
- 任务 3 的 Rust 路由改动独立，可先合入。
- 任务 4/5 与其它任务无冲突，可最先合入。
- 全部完成后可整体合入 `chore/sync-upstream-3.2.0` → 再进 `main`。

---

## 8. 全量回归与手测清单（每个任务完成后 + 最终合并前）

### 8.1 自动验证（必须执行并贴结果到 PR）

```bash
flutter analyze --no-pub
flutter test
cd rust && cargo check --offline && cargo fmt --check   # 仅任务 3 需要
```

### 8.2 手测矩阵（按任务勾选）

| 场景 | 任务 1 | 任务 2 | 任务 3 | 任务 4 |
|---|---|---|---|---|
| Android 手机浅色/深色 | ✓ 歌词 | ✓ 导入 | ✓ 6 组推荐 | ✓ 状态栏 |
| Android 车机横屏 | — | — | ✓ 布局 | — |
| Windows 桌面 | ✓ 歌词（本地） | ✓ 导入 | ✓ 宽窗懒构建 | — |
| 平板/窄屏 | — | — | ✓ | — |
| iOS（如有设备） | — | — | — | ✓ 状态栏（必须） |
| 断网/接口失败降级 | ✓ 无歌词不报错 | ✓ 解析失败提示 | ✓ 单组失败不拖垮首页 | — |
| 登录态缺失 | — | ✓ 提示登录 | ✓ rail 不显示 | — |

### 8.3 既有功能回归关注点

- 猜你喜欢私人 FM：预取预览、开播/暂停、播完续批、卡片内「每日推荐」入口（上一批已验证，本批不得回退）。
- 播放主链路：本地歌/网络歌切歌、歌词加载与翻译/音译对齐（上一批修复）。
- 首页缓存：冷启动磁盘缓存 → 网络刷新；「大家都在听/新歌速递/推荐歌单」正常。
- 播放页/设置页主题与状态栏。

---

## 9. 交付物与完成检查表

每个任务 PR 必须包含：

- [ ] 代码（按任务文件清单；无无关重构）
- [ ] 新增/更新测试（命名与现有 `test/**` 风格一致）
- [ ] `update.md`「未发布」段条目（新功能/修复/优化对应段落）
- [ ] PR 描述：背景 / 上游参考 hash / 改动点 / 测试命令与结果 / 手测记录 / 风险与回滚
- [ ] 自动验证结果（analyze、全量 test；任务 3 附 cargo check/fmt）
- [ ] 若涉及未完成或需产品决策的点，显式列为「未做/遗留」

PR 描述模板：

```markdown
## 背景
（一句话说明需求与上游参考提交）

## 改动
- 文件级改动列表（含新增文件）
- 关键设计取舍（匹配阈值/缓存策略/接口路径/UI 形态）

## 验证
- flutter analyze --no-pub →
- flutter test →  （总数/失败数；新增测试文件）
- （任务3）cargo check --offline / cargo fmt --check →
- 手测：设备/场景/结果（附截图可选）

## 风险与回滚
- 风险点 / 回滚方式（revert 本 PR 即可，无迁移/数据破坏）
```

---

## 10. 附：上游参考提交与常用命令

```bash
git fetch upstream

# 任务 1
git show --stat 87c35a1
git show 87c35a1:lib/services/local_song_matcher.dart
git show 87c35a1:lib/services/local_lyrics_service.dart
git show 87c35a1:test/local_lyrics_test.dart
git show c60a92f

# 任务 2
git show --stat dc92cfd
git show dc92cfd:lib/services/qq_playlist_service.dart
git show dc92cfd:lib/services/playlist_import_service.dart
git show dc92cfd:lib/models/music_models.dart
git show dc92cfd:lib/ui/widgets/import_playlist_sheet.dart
git show dc92cfd:test/playlist_import_test.dart

# 任务 3
git show --stat f230444
git show f230444 -- lib/ui/pages/home_page.dart
git show f230444 -- lib/ui/pages/playlist_detail_page.dart
git show f230444:lib/services/music_api.dart | sed -n '/recommendedSongCards/,/^  }/p'
git show 62ae541

# 任务 4
git show bc90352 -- lib/main.dart lib/ui/pages/comment_page.dart
git show 98ef8e1
git show 03737b5

# 任务 5
git show f955d9a -- .github/workflows/flutter-ci.yml
git show f955d9a:.github/workflows/flutter-ci.yml
```

## 11. 附：关键代码位置索引（fork 当前基线）

| 用途 | 位置 |
|---|---|
| 本地歌词加载入口 | `lib/controllers/player_controller.lyrics.dart` `loadLyrics()` |
| 内嵌歌词读取 | `lib/controllers/local_music_controller.dart:253`；`rust/src/api.rs:101` |
| 歌曲搜索 / 歌词获取 | `lib/services/music_api_search.dart:37`；`lib/services/music_api_lyric.dart` |
| 缓存 | `lib/services/cache_service.dart:48/79`；`LyricLine.toCache/fromCache` `lib/models/song.dart:926/935` |
| 导入面板 / 解析 / 加歌 | `lib/ui/widgets/import_playlist_sheet.dart`；`lib/services/music_api_playlist.dart:134/171`；`rust/src/services/external_playlist.rs` |
| 外部歌单模型 | `lib/models/netease_external.dart:94` |
| `/top/card` Rust 实现 | `rust/src/services/discover.rs:165`（`top_card`，当前 unused） |
| Rust 路由表 | `rust/src/engine.rs`（`/top/album` 附近插入 `/top/card`） |
| 首页数据/缓存/UI | `lib/ui/pages/home_page.dart` `fetchData`(≈884)/`decodeCache`(≈853)/`encodeCache`(≈869)/`hasContent`(≈878)/`HomeData`(≈4259)；`AppHorizontalRail` `lib/ui/widgets/app_section.dart:58` |
| 歌单详情静态集合 | `lib/ui/pages/playlist_detail_page.dart` 构造器/`initialSongs`/`_isDailyRecommend` 分支 |
| 状态栏 | `lib/main.dart:702`；`lib/ui/app_theme.dart:106`；`lib/ui/pages/comment_page.dart:17`；`lib/ui/pages/player_page.dart:316` |
| CI | `.github/workflows/`（4 条打包流水线；新增 `flutter-ci.yml`） |

---

## 12. 需与需求方确认的点（开工前）

1. 任务 1 是否接受新增 `charset` 依赖（GBK `.lrc` 解码）；若不接受则只支持 UTF-8/UTF-16。
2. 任务 2 是否允许 Dart 直连 QQ 公开接口（无需登录、非酷狗；不破坏「酷狗请求必须走 Rust」的约束）。
3. 任务 3 的「推荐歌曲」横轨放在推荐 tab 的哪个位置（建议「大家都在听」下方）；是否需要同步到车机/桌面宽窗（默认按现有形态全接）。
4. 任务 4 是否有 iOS 真机/模拟器可做最终视觉验收；没有则 PR 注明由有设备的人复核。
