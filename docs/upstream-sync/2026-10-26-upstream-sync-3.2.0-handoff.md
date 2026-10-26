# 上游 3.2.0 同步交接说明（chore/sync-upstream-3.2.0）

> 生成时间：2026-10-26。配套文档：
> - 逐提交梳理（108/108 覆盖）：[2026-10-26-upstream-3.2.0-triage.md](./2026-10-26-upstream-3.2.0-triage.md)
> - 猜你喜欢/私人 FM 移植设计（含 R1–R14 风险与补测清单）：[2026-10-26-guess-you-like-personalfm-design.md](./2026-10-26-guess-you-like-personalfm-design.md)

## 1. 背景与结论

用户反馈 [issue #5](https://github.com/bamboostrip/shiyin-music/issues/5)：希望「猜你喜欢」不是歌单，而是红心猜你喜欢。上游 `umr-xiaomai/kgka_Music_hl` 在 3.1 已把「猜你喜欢」改成酷狗官方猜你喜欢（`/personal/fm`，mode=normal 即「红心 Radio」+ 口味私人 FM）。

- 基线：`main`（3561c7f，fork v3.0.13）↔ `upstream/master`（4ae26cc，3.2.0 stable），merge-base `e644a9e`，上游未同步 **108 个提交**。
- 结论：**上游「猜你喜欢」确实在这批未同步提交里**（33403a8 核心 + 2c1e07c / 0194282 / bf264d9 相关修复）。
- 同步策略：本 fork 已去后端化（Rust 引擎 + 拆分后的 controller/home_page 架构），与上游整分支 merge 不可行（实测 65 文件冲突、`-X ours` 仍有 684 个编译错误）。因此本次按 **功能级回移（backport）** 落地 P0 批次，其余见 triage 文档第 5–7 节。
- 上游 `upstream/codex/optimize-and-features` 分支另有 3.3.0 与未合并提交（含播放页封面二级菜单等），不在本次范围，后续可单独评估。

## 2. 分支与提交

分支：`chore/sync-upstream-3.2.0`（基于 `main` 3561c7f）。

| 提交 | 内容 | 对应上游 |
| --- | --- | --- |
| `1a493aa` | feat(player): 同步上游酷狗官方「猜你喜欢」私人FM（红心 Radio，issue #5） | 33403a8 / 2c1e07c / 0194282 |
| （本次后续提交） | fix(lyric): 歌词解析对齐与候选兜底（P0-2） | bf264d9 拆件 |
| （本次后续提交） | fix(player): 私人 FM 健壮性 + 播放缓存流量优化（P0-3） | bf264d9 拆件 + 修复 |
| （本次后续提交） | feat(home): 猜你喜欢卡片保留「每日推荐」次级入口 | —— |
| （本次后续提交） | docs(upstream-sync): 同步梳理/设计/交接文档 + update.md | —— |

验证命令与结果见第 4 节。

## 3. 本次已同步内容

### 3.1 「猜你喜欢」= 酷狗官方私人 FM（红心 Radio）— issue #5

行为：

- 首页「猜你喜欢」卡片改为私人 FM 入口：登录后自动预取一批推荐作预览（未登录不请求、点按提示登录），点按开播；会话中卡片实时展示当前 FM 歌曲与播放/暂停态。
- 会话内一首自然播完（`isOverplay=true`）或队列末尾点「下一首」（`isOverplay=false`）时，带当前歌曲 hash/songid/playtime 播放反馈续拉下一批（单批最多 5 首、去重当前歌与队列已有歌）。
- 私人 FM 下「下一首」严格线性、不随机/不单曲循环；「上一首」可在线性回退，首曲回零不退出。
- 从歌单/搜索/下载/历史等其它入口切歌（队列被替换或歌曲不在当前队列）自动退出 FM 会话，避免 `currentIndex=-1` 后播完停住。
- FM 歌曲播放地址走 `hashOnly`（不传专辑/音频 id）；续批失败 Toast 提示并清完成标记可重试；队列软上限 200（与播放状态持久化窗口对齐）。
- 原「猜你喜欢 = 每日推荐歌单」入口降级为卡片内「每日推荐」次级入口保留。

代码位置：

- `lib/services/music_api_rank.dart`：`MusicApi.personalFm`（Rust `/personal/fm`，参数 snake_case：mode/song_pool_id/action/hash/songid/playtime/is_overplay/remain_song_cnt；响应 `song_list`，失败信封抛 `ApiException`）。
- `lib/models/song.dart`：`Song.fromPersonalFm`。
- `lib/services/music_api_song.dart`：`songUrl(..., hashOnly:)`。
- `lib/controllers/player_controller.personalfm.dart`（新）：`_PlayerPersonalFm` 会话分片。
- `lib/controllers/player_controller.dart`：`part`/mixin 注册、会话字段与 getter、`_nextSong` FM 分支、契约声明。
- `lib/controllers/player_controller.playback.dart`：`playSong` 会话保持判定、`hashOnly` 解析、完成处理续批分支；`player_controller.queue.dart`：FM 下一首/上一首；`player_controller.settings.dart`：切音质缓存调度。
- `lib/ui/pages/home_page.dart`：卡片/预览/刷新联动/每日推荐次级入口。

> Rust 引擎 `GET /personal/fm` → `rust/src/services/discover.rs::personal_fm` 早已存在，本次 **无需改 Rust / 重生成 FRB**。

### 3.2 播放缓存流量优化（P0-3）

- 首播/切音质不再立即下载缓存：稳定播放 **15 秒**后才调度后台缓存；切歌/换源/销毁时取消未到点的调度与在途缓存传输（`DownloadController.cancelActivePlayCache`）。
- 已下载/正在下载的歌曲跳过重复缓存；缓存文件大小 ≤0（半成品）不写入索引；蜂窝网络门控保持不变。

### 3.3 歌词解析与候选兜底（P0-2）

- KRC `[language:...]` 翻译/音译：空行保留占位、只对 `[时间, 文本]` 双元素行取时间；变体行数与原始歌词行数一致时按**原始行号**直挂 translation/romanization，修复翻译/音译整体错位。
- 歌词候选：先 `hash + album_audio_id` 精确查询，失败用「歌手 + 歌名」`keywords` 兜底；Rust `/search/lyric` 增加 `keywords`→`keyword` 别名（无需重生成 FRB）。
- 新增 `test/services/lyric_parser_test.dart`、`test/services/lyric_candidate_test.dart`。

## 4. 验证

```bash
flutter analyze --no-pub          # No issues found
flutter test                      # 全量通过（见下）
```

- 全量测试：**1218 项通过、1 项跳过、0 失败**（`test-run-3.log`），其中新增私人 FM 会话/API/模型测试 24 项、歌词解析/候选兜底新增 12 项，既有歌词相关测试全绿。
- Rust：`cargo check --offline`、`cargo fmt --check` 通过（歌词 `keywords` 别名改动）。
- 未做真机手测（需登录态）：手测清单见 personalfm 设计文档第 8 节，重点：登录后首页预览是否出歌、点按开播、播完自动续批、暂停/继续、切到其它歌单后退出会话、车机/平板卡片布局。

## 5. 未同步清单（后续批次，详见 triage 文档）

**P1（建议下一批）**

1. 本地歌词匹配缓存（87c35a1 + c60a92f）：本地歌曲自动匹配并缓存歌词。
2. QQ 歌单导入匹配（dc92cfd + c60a92f）：外部歌单解析与歌曲匹配增强。
3. 首页推荐歌曲 6 组（f230444 + 62ae541）：需新增 Rust `/top/card` 路由。
4. 恢复上次播放列表开关（4d9618e）。
5. 评论翻页 / 小屏评论详情（26ea575、f955d9a）。
6. 播放进度 `positionNotifier` 独立推送（c833a4d）：消除高频全量 rebuild（fork 已有 `positionListenable` 等价实现，需评估差异）。

**P2**

- iOS 状态栏两个小补丁（bc90352 / 98ef8e1 / 03737b5，仅 iOS 生效）。
- 其余 2 项「需人工确认」、15 项「暂缓」、29 项「跳过」（架构/品牌/发布体系冲突）见 triage 文档。

**明确不建议整分支 merge 的理由**：本 fork 的 `home_page` / 播放页 / 设置页 / 通知与音频链路已全面重写（车机、平板、桌面、媒体会话、音效），上游大量 UI 重构与 fork 定制互斥；triage 文档已逐条给出「跳过/暂缓」依据。

## 6. 已知边界与风险

1. **契约未真机验证**：`/personal/fm` 参数与 `song_list` 字段基于 fork Rust 路由 + api.json 后端契约推断；若服务端返回形态有出入，按 `_debugLyric*` 同款思路加日志（当前失败信封已抛错，不会伪装成空推荐）。
2. **续批 isOverplay 语义**：自然播完传 true、手动下一首传 false，与上游一致。
3. **队列软上限**：长会话丢弃最老推荐，回退深度最多 200 首。
4. **keywords 兜底**可能命中同名不同版本（上游同行为），未做时长/歌手二次校验。
5. **变体行数对齐遗留边界**：变体行数==原始行数且中间夹空文本行时，legacy indexed 兜底仍可能给 direct 为 null 的行猜测值（上游同一边界）。

## 7. 继续同步的操作建议

1. 从 `chore/sync-upstream-3.2.0` 切新分支，按 triage 文档第 5 节 P1 逐项回移；每项一个提交，保持「先移植测试、再改实现、analyze + 定向测试」节奏。
2. 涉及 Rust 新路由时（如 `/top/card`），先补 `rust/src/engine.rs` 路由与 service，再改 Dart；`cargo check --offline`。
3. UI 改动不要整文件覆盖上游版本——本 fork 的 home/player/settings 已重写，按功能点改。
4. 全部完成后可让 `main` 快进合并该分支（本分支基于 main，无反向冲突）。
