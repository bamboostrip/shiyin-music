# 上游同步第二批交付报告（5 项功能/修复 + CI）

> 生成时间：2026-10-26。
> 任务书：[2026-10-26-next-batch-tasks.md](./2026-10-26-next-batch-tasks.md)（本批 5 项任务全部完成）。
> 集成分支：`chore/sync-upstream-3.2.0`（本地基于 `main` 3561c7f 的同步分支，本批在其上继续开发）。
> 每项任务独立分支开发、独立提交，最后合入集成分支；分支未 push（如需 PR 可直接从本地分支推送）。

## 1. 交付概览

| # | 任务 | 分支 | 提交 | 状态 |
|---|---|---|---|---|
| 0 | 共用基础件：本地歌曲元数据匹配 | chore/sync-upstream-3.2.0 | `08870b1` | 完成 |
| 1 | 本地歌曲歌词匹配与缓存 | `feat/local-lyrics-matching` | `edc7874` + `aa5360f`（附带修复） | 完成 |
| 2 | QQ 歌单导入匹配增强 | `feat/qq-playlist-import` | `1b4f737` | 完成 |
| 3 | 首页「推荐歌曲」6 组（`/top/card`） | `feat/home-recommend-cards` | `7452d81` | 完成 |
| 4 | iOS 状态栏两行修复 + AppBarTheme | chore/sync-upstream-3.2.0 | `66750b1` | 完成 |
| 5 | CI 补 `flutter analyze` + `flutter test` | chore/sync-upstream-3.2.0 | `527c312` | 完成 |

集成提交（merge 顺序）：`5a7353e`（任务 1）→ `5fc7197`（任务 3）→ `57e4631`（任务 2）。

## 2. 全量验证（集成分支最终状态）

```text
flutter analyze --no-pub   → No issues found（12.7s）
flutter test               → 1346 passed / 1 skipped / 0 failed（1:18）
cd rust && cargo check --offline → Finished dev profile
cd rust && cargo fmt --check     → exit 0
```

- 本批前基线：1218 passed / 1 skipped。
- 本批新增测试 128 项：matcher 21、本地歌词服务 34、逐字歌词缓存 3、推荐歌曲 21、QQ 导入 47、主题/状态栏 2。
- 未做真机/桌面手测（当前环境无设备、无酷狗登录账号），手测清单见任务书 8.2 与本文第 4 节。

## 3. 各任务要点

### 3.1 任务 1：本地歌曲歌词匹配与缓存

- `lib/services/local_lyrics_service.dart`（新）：加载顺序 同名 `.lrc`（`.lrc`/`.LRC`、2MB 上限）→ 音频内嵌歌词（注入 `embeddedLyricsReader`，走 fork 的 Rust `readLocalLyrics` / Android MethodChannel，**未引入** `audio_metadata_reader`）→ 本地缓存 → 元数据在线匹配（`searchSongs` + `matchCandidates.take(3)` 逐个拉歌词）→ 纯文本内嵌兜底；失败静默返回空、不缓存空结果。
- `.lrc` 编码：UTF-16LE/BE BOM → UTF-8 严格 → GBK fallback（新增唯一依赖 `charset: ^2.0.1`）。
- 缓存：key = `cache_local_lyric_v1_<sha1(文件绝对路径)>`；signature = 歌名/歌手/时长/文件大小/修改时间，文件替换或元数据变化自动失效；同歌并发 load 共享 Future。
- `player_controller.lyrics.dart` 本地分支改为懒建 service 调用，保留 `currentSong?.hash` 守卫与桌面歌词同步；修复「空/无效 `.lrc` 压住内嵌与在线歌词」旧回归。
- 附带修复（`aa5360f`）：`LyricWord.fromCache` 不再 trim，缓存往返保留 KRC 词间空格（上游 87c35a1 同提交修复）。

### 3.2 任务 2：QQ 歌单导入匹配增强

- `lib/services/qq_playlist_service.dart`（新）：分享文本提取 QQ 链接（host 白名单、拒绝 userInfo/非 http(s)）→ 最多 6 跳 302 解析歌单编号 → `u.y.qq.com/cgi-bin/musicu.fcg` 分页（100 首/页、上限 100 页、mid 去重、空页/重复页/超页/空歌单报错、`singer` 数组/对象/字符串容错）。
- `MusicApi.parseExternalPlaylist`：QQ 链接 Dart 直连公开接口（无需登录、非酷狗接口，注释写明例外依据），其余平台继续走 Rust `/playlist/external/parse` 双路径。
- `lib/services/playlist_import_service.dart`（新）：复用 `local_song_matcher.dart` 按「歌名 + 歌手 + 时长」匹配；旧数据（无歌手无时长）要求标题完全相等；逐首去重/写入/失败分类/进度快照/每首检查取消；写操作不加超时（避免结果未知导致重复添加）。
- `lib/ui/widgets/import_playlist_sheet.dart` 重写（保留 fork 设计风格，入口签名不变）：输入 → 解析 → 选目标歌单（新建/已有自建）→ 导入进度可停止 → 完成统计 + 未匹配清单可复制；未登录提示且禁止写操作；解析失败保留输入；异常/取消保留已成功部分。
- 额外真实网络验证：真实公开 QQ 歌单（223 首）3 页合并解析，歌单名/总曲数/多歌手/时长正确。

### 3.3 任务 3：首页「推荐歌曲」6 组（`/top/card`）

- Rust：`engine.rs` 新增 `("GET", "/top/card")` 路由（`card_id` 缺省 1），`discover.rs` 的 `top_card` 去掉 `#[allow(dead_code)]`；未重生成 FRB。
- 模型/API：`Song.fromTopCard`、`durationFromTopCardSeconds`（小数秒 → 毫秒，62ae541 修复）、`RecommendedSongCard`（fromJson/fromCache/toCache + barrel export）、`MusicApi.recommendedSongCards()`（6 组并发 + 单组 try/catch + 空组过滤）。
- 首页：`HomeData`/`encodeCache`/`decodeCache`/`hasContent`/`fetchData` 同步新字段；`_RecommendedSongCardRail` 紧邻「大家都在听」，手机 sliver / 车机 Column / 桌面宽窗 asSlivers 三形态接入；点击进入只读歌单页。
- `PlaylistDetailPage`：`initialSongs` 非空即通用静态集合 + `readOnly`（隐藏收藏/多选/更多），每日推荐分支复用；`ListStickyBar.showSelect` 默认 true 不影响其他页面。
- 测试替身：13 个渲染 HomePage 的测试 fake 补 `recommendedSongCards()` 覆写。

### 3.4 任务 4：iOS 状态栏

- `statusBarBrightness`（iOS，背景明暗）与 `statusBarIconBrightness`（Android，前景明暗）语义相反：修正 `main.dart` 首页壳、`comment_page.dart`、`player_page.dart`（播放页固定深色底 → `dark`）。
- `app_theme.dart` 全局 `AppBarTheme.systemOverlayStyle`：透明 AppBar 下显式给出镜像亮度 + 导航栏跟随 `scheme.surface`。
- 全量核对 6 处 `statusBarBrightness`：settings/audio_effects/audio_interruption 三处原已是镜像值，未动；新增 `test/ui/app_theme_overlay_test.dart` 锁定镜像关系。
- iOS 实机视觉验收需有设备的人复核（Android 不受影响：`statusBarBrightness` 仅 iOS 生效）。

### 3.5 任务 5：CI 校验流水线

- 新增 `.github/workflows/flutter-ci.yml`（`Flutter Analyze & Test`）：push `main` / `pull_request` / `workflow_dispatch`，同分支并发取消，`FLUTTER_VERSION: 3.44.8` + pub cache，执行 `flutter analyze --no-fatal-infos --no-fatal-warnings` 与 `flutter test`。
- 不改现有 4 条打包流水线；`docs/release-process.md` 的 CI 清单补该流水线说明。
- 本机无法触发 GitHub Actions，workflow 语法与命令按现有打包流水线同构；首次 PR 推送后需确认 check 全绿（预期命中 pub cache 后 <10 分钟）。

## 4. 手测矩阵（未执行，需真机补充）

| 场景 | 任务 | 说明 |
|---|---|---|
| Android / Windows：本地无 `.lrc`/内嵌歌词、酷狗有同名歌 → 播放页出现歌词 | 1 | 需真实酷狗登录态 |
| 替换/改名本地文件 → 缓存失效重新匹配；飞行模式 → 无歌词不报错不阻塞 | 1 | |
| 真实 QQ 歌单分享链接 → 解析 → 新建/已有歌单导入；未匹配清单；取消；重复导入不重复；网易云链接回归 | 2 | 需登录酷狗账号；建议抽查 10 首 |
| 登录态首页出现 6 组推荐横轨；点击只读页播放/加队列；单组失败降级；手机/车机/桌面宽窗/深色 | 3 | `/top/card` 契约未真机验证 |
| iOS 浅色/深色：设置、已下载、本地音乐、播放历史、评论、播放页状态栏文字可见 | 4 | 需 iOS 设备/模拟器 |

## 5. 已知遗留与后续建议

1. `/top/card` 响应形态按上游 `song_list`/`rec_desc` + transport 解包实现，未真机验证；若形态不符表现为 rail 静默不显示（不报错），届时优先在 Rust 侧解包调整。
2. QQ 公开接口存在改版/风控风险（Referer/UA/频率）；失败均有中文错误提示，测试使用 MockClient，真实网络仅做过一次解析手测。
3. 大歌单（1000 首）导入未实测：沿用逐首 search + add，预计数分钟；如需提速可改 50 首/批 add（会牺牲逐首失败分类）。
4. `LyricWord` 空格修复后，已存在的旧缓存（写入时已丢空格）不会自动恢复，重进播放页/清数据缓存后重新拉取即可。
5. 任务 2 可选入口（「我的」歌单区导入按钮，上游 `library_page` +13 行）未做，当前入口仍在歌单详情页溢出菜单；导入完成后歌单详情页缓存失效语义未补（最长需下拉刷新可见新歌）。
6. 桌面宽窗下推荐卡片封面固定 120（未像新歌速递撑满格宽），功能不受影响，可按视觉反馈微调。
7. 分支未 push、未建 PR；远程 `origin/chore/sync-upstream-3.2.0` 仍指向上一位用户的 docs 提交，本批完成后如需同步远程需 force push（不覆盖他人提交）。

## 6. 回滚

本批无数据迁移/无破坏性变更：`git revert` 对应 merge/提交即可（各任务分支独立，也可只回退单个任务）。
