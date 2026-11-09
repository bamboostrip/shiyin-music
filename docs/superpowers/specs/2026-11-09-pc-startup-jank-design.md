# PC 端启动卡顿修复（prefs 膨胀 + 整文件重写 + 窗口早显示）

- 状态：已实现
- 日期：2026-11-09
- 反馈：用户上手即感知「双击后要等一会窗口才出来，出来之后还要卡十几秒」
- 相关代码：`lib/services/prefs_compaction.dart`、`lib/services/lyric_cache_service.dart`、
  `lib/services/prefs_write.dart`、`lib/services/cache_service.dart`、
  `lib/services/legacy_migration.dart`、`lib/controllers/player_controller.lyrics.dart`、
  `lib/ui/desktop/desktop_window.dart`、`lib/main.dart`

## 1. 现象与实测

用户机器（Windows 11，release 构建）实测：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 双击 → 主窗可见 | 1182–1296 ms | **609–755 ms** |
| 主入口 → 通知渠道初始化（内部初始化阶段） | 765–1038 ms | **267 ms** |
| 启动后前 12 秒内 prefs 全量重写次数 | 12–15 次 | **1 次** |
| 单次 `prefs.setX` 阻塞时长 | 550–1050 ms | **~40 ms** |
| `shared_preferences.json` 体积 | **18.3 MB**（632 key） | **1.5 MB** |

修复前 18.3MB 的构成：`cache_lyric_*` 548 条 / 14.26MB（每首歌一条歌词）、
`cache_playlist_collection_*` 17 条 / 0.62MB、首页/电台等 0.4MB、播放历史
0.19MB。歌词缓存只增不减（30 天 TTL 只影响读取，从不删除），两个月内从
2.9MB 涨到 18.3MB。

## 2. 根因（三层叠加）

1. **缓存无上限**：歌词（每首歌一条）与详情类 JSON 全部塞进
   SharedPreferences，长期使用后无界增长。
2. **Windows 的 prefS 实现是"整文件重写"**：`shared_preferences_windows`
   是纯 Dart 实现，`setValue` 会对整张 map 做 `json.encode` +
   `writeAsStringSync`，**同步跑在 UI 线程**。18MB 时单次写入约 550–600ms；
   启动还先要 `readAsStringSync` + `jsonDecode`（约 560ms）。
3. **启动阶段写入风暴 + 空窗**：
   - 启动流程（登录态恢复、资料刷新、歌单缓存、首页 SWR、歌词缓存）一共
     触发 15 次 prefs 写，每次整文件重写 → 前 10~13 秒 UI 线程几乎被写满；
   - 窗口在 `runApp` 之前就被 `show()`，初始化那 1 秒多用户看到的是一扇
     空白窗口。

## 3. 方案

### 3.1 歌词缓存迁到文件（治本）

新增 `LyricCacheService`：`<应用支持目录>/lyric_cache/<songHash>.json`，
内容 `{savedAt, lines}`（与旧 prefs 缓存同构），TTL 30 天、总量上限 32MB、
启动首帧后按「最后访问时间」淘汰到 80%。所有 IO 失败静默降级。

- `player_controller.lyrics.dart` 的读写改走该服务，不再产生
  `cache_lyric_*` 这类大 key；
- 缓存目录/裁剪与 `ImageDiskCache` 同款：`configure` 只登记上限（无 IO），
  `prune` 放到首帧之后（`main.dart` 的 postFrame 回调）。

### 3.2 存量 prefs 一次性瘦身

新增 `PrefsCompaction`，由 `LegacyMigration.run` 在**第一次
`SharedPreferences.getInstance()` 之前**、平台目录搬移之后调用：

- 删除 `cache_lyric_*`（已迁文件缓存）；
- 其余按条缓存按 `AppConfig.dataCachePrefixCaps` 保留最新 N 条
  （歌单/专辑/歌手详情各 30 条，本地歌词匹配 200 条）；**前缀按最长匹配
  分组**（`cache_playlist_collection_*` 不占 `cache_playlist_*` 的名额）；
- 所有 `cache_*` 合计超过 `dataCacheMaxChars`（4MB）时，按 `savedAt`
  从旧到新淘汰到预算内（条数上限管不住"条数没超但单条很大"）；
- 文件 > 4MB 触发；**小于 4MB 但残留旧版 `cache_lyric_*` 时也触发**
  （一次便宜字符扫描，命中才解码）；
- 写临时文件后原子 rename，失败静默。

**为什么不逐键 `prefs.remove()`**：在 18MB 文件上每删一个 key 都是一次
整文件重写，548 个 key ≈ 5 分钟启动卡死；直接改原始 JSON 只需一次解码 +
一次编码。

### 3.3 写去重与条数上限

- `prefs_write.dart`：`setStringIfChanged` 等扩展，值没变直接跳过；
  用于 `AuthController` 的登录态（token/t1/sessionId/userId）、收藏列表、
  歌单缓存、登出清理等启动高频写点——第二次启动起这些写入全部消失；
- `CacheService.write`：payload 与已缓存内容一致且 10 分钟内校验过则跳过；
  写后按 `dataCachePrefixCaps` 淘汰最旧条目（**每次最多 3 条**，历史积压
  分批收敛，避免一次性几十次整文件重写）；单条编码后超过 2MB 直接不缓存；
- 几何/最大化状态落盘同样走 IfChanged（窗口每次启动少 4-5 次无谓写盘）。

### 3.4 窗口首帧后再显示

`DesktopWindow.ensureInitialized` 只恢复几何/尺寸、记录"上次是否最大化"。
复位逻辑必须**顺序 await**：原先塞进 `waitUntilReadyToShow(callback)` 里是
`VoidCallback`，内部 await 链不会被执行方等待，`revealAfterFirstFrame` 会
抢跑读到未就绪的状态（最大化/位置丢失）。

`main()` 在 `runApp` 之后调用 `DesktopWindow.revealAfterFirstFrame()`：
post-frame 回调里调用 `revealWithOps`——先等原生首帧真正呈现（runner 的
`SetNextFrameCallback` 会 `Show()`，早于它的 Dart `show()` 可能显示空白
客户区），等不到再手动 `show()` 兜底；抢焦点；若上次是最大化，
**窗口可见后**再 `maximize()`（实测 `SC_MAXIMIZE` 对隐藏窗口是空操作）并
轮询确认。带 2s 兜底，首帧迟迟不来（构建异常）也保证窗口出现。

## 4. 关键权衡

- **去重 + 定期刷新 savedAt**：payload 未变且 10 分钟内校验过才跳过；超过
  10 分钟仍写一次只刷新 savedAt——否则"内容未变但已过期"的条目会被永远
  判过期（歌单详情每次打开都全量重拉所有分页）。
- **阈值 + 歌词残留双触发**：瘦身后文件 ~1.5MB，后续启动不再解码；阈值
  4MB 给正常增长留余量。低于阈值但仍有 `cache_lyric_*` 时也清理（一次
  字符扫描，命中才解码）。
- **保留 SharedPreferences 承载其余缓存**：首页/歌单/详情缓存有 TTL 与
  条数上限后总量可控（~1.5MB），改造成本与收益不成正比；歌词（无界、
  体积占 78%）才是必须迁走的部分。
- **失败全部静默**：缓存都是可重建数据，任何 IO/解析异常都不能影响启动。

## 5. 兼容与回滚

- 迁移只依赖 prefs 原始 JSON 格式（插件文件名固定），不改变任何业务
  key 的语义；settings/token/播放状态原样保留。
- 瘦身只删「可重建缓存」：旧版本回退后重新联网播放即可重新生成歌词缓存。
- 迁移逻辑失败（文件损坏、权限异常）时保持原文件不动，行为与修复前一致。
- 阈值判断在文件 ≤4MB 时零开销（只有一次 `exists` + `length`）。

## 6. 验证

- 新增单测：`prefs_compaction_test`（规则/阈值/非法 JSON/原子写/预算淘汰/
  低阈值歌词清理）、`lyric_cache_service_test`（读写/穿越防护/TTL/容量
  淘汰/禁用态）、`cache_service_write_test`（去重/前缀上限/定期刷新）、
  `prefs_write_test`（IfChanged 系列）、`desktop_window_reveal_test`
  （显示/最大化/兜底顺序）。
- 全量 `flutter test`：1830 passed / 1 skipped；`flutter analyze` 0 issue。
- 真机实测（用户真实 18MB prefs）：首次启动触发瘦身后 18.3MB → 1.5MB，
  第二次起窗口可见时间 609–755ms，启动 12 秒内 prefs 重写 1 次。

## 7. 后续可做

- 其余数据缓存（首页/歌单详情等）如需进一步降低写盘成本，可同样迁到
  文件缓存，把 SharedPreferences 收敛为"只存设置"。
- 若后续引入 `SharedPreferencesAsync`，仍建议保持"小文件 + 少写"的约束。
