# 下载旧库迁移/补扫 + 扫描顺序测试 交接说明

> 状态：待排期（非阻塞缺陷）
>
> 背景提交：`0a06c90`（FLAC/ID3 标签、按字节纠正扩展名、可选 LRC）、`5ccfac2`（媒体库扫描移到写标签之后）
>
> 当前基线：`main`（下载相关代码见文末「代码入口」）

## 0. 一句话

这两项是「下载标签/扩展名/媒体库」功能的**收尾**：

- **旧下载 byte-level 迁移/补扫**：让升级前已经下载的文件也补上「按真实字节纠正扩展名 + 内嵌标签 + 重新扫描媒体库」。
- **扫描顺序测试**：给「先写标签、后扫描媒体库」这条顺序加防回归测试（目前零覆盖）。

## 1. 现状：为什么只有新下载受益

新下载的收尾链路（`DownloadController._download` → `_enrichDownload`）：

1. `DownloadService.download()` 落盘，`_executeTask` 里对 `DownloadKind.download` 调 `_correctExtension()`：用 `inspectAudioFile()` 按**文件头字节**识别真实格式，把 `.flac`（实为 MP3）改名为 `.mp3`，反向同理；
2. 控制器在标记「已下载」之前调 `DownloadMetadataWriter.write()`：MP3 写 ID3v2.3、FLAC 写 Vorbis comment（标题/歌手/专辑/歌词/封面），按需另存 `.lrc`；
3. 标签写完后调 `DownloadService.scanForMediaLibrary()` → 原生 `MediaScannerConnection.scanFile()`，让系统音乐库/车机蓝牙列表刷新；
4. 最后才写下载索引（`DownloadEntry.filePath` 指向纠正后的最终路径）。

**升级前的旧文件完全不走上述 2-4 步**：

- `_correctExtension()` 只在 `DownloadService._executeTask` 对新下载调用；
- `DownloadMetadataWriter` 只在 `_enrichDownload` 里调用；
- 启动时的 `reconcileDownloads()` 只按 basename 搬目录/找回文件，**不读字节、不写标签、不扫描**。

用户可见症状（按影响面排序）：

1. 旧文件扩展名撒谎：`.flac` 里实际是 MP3（丢码率降级后常见），第三方播放器/车机按扩展名选解析器，轻则不显示时长/封面，重则判损坏不播；
2. 旧文件没有内嵌标签/封面/歌词：系统音乐库、车机蓝牙列表显示「未知艺人/未知专辑」；
3. MediaStore 里已经缓存了「未知艺人」快照，不重扫不会更新；
4. Android 默认下载目录是 App 专属目录（`Android/data/<包名>/files/shiyin_downloads`），系统不索引，标签/扫描对这类用户只有把文件拷出去才受影响；**只有用户自定义到公共目录（需要「所有文件访问」）时，媒体库问题才直接可见**。

## 2. 任务 A：旧下载 byte-level 迁移/补扫

### 2.1 目标 / 非目标

- 目标：对下载索引里状态为 `downloaded` 且文件存在的条目，补做「字节判型 → 扩展名纠正 → 写标签 → 更新索引 → 媒体库扫描」。
- 非目标：
  - 不重新下载、不改音质；
  - 不处理播放缓存目录（`playCache`）；
  - 不扫描用户手动放进目录、但不在索引里的未知文件（除非产品另提「目录扫描」需求）；
  - 不删除任何用户文件。

### 2.2 触发方式（建议先做可控版本）

二选一，推荐先 **B** 再考虑 **A**：

- **A. 首启后空闲时静默跑一次**：用 prefs 版本标记 gate（如 `settings.download_migration_version`），只跑一次；后台串行/低并发，完成后 Toast 汇总。
- **B. 设置页手动入口**：下载管理里加「修复已下载文件（标签/扩展名）」按钮 + 进度与结果汇总。风险可控，出问题用户可重试。

### 2.3 单文件流程（建议实现顺序）

1. 跳过正在播放的文件（`_isPlayingFile`），下次再处理；文件不存在跳过（交给 `reconcileDownloads`）。
2. `inspectAudioFile(path)` 按字节判定；`unsupported`（AAC/APE/WAV 等）不处理，只记录日志。
3. 扩展名纠正：把 `DownloadService._correctExtension()` 抽成可复用方法（或加 public wrapper）；目标已存在时仍走 `resolveNonCollidingPath`；rename 成功后**立即更新索引**，不要等整批结束。
4. 写标签：`DownloadMetadataWriter.write(filePath: 最终路径, song, lyricsText, saveLyricsFile: 当前设置, coverBytes: 从 ImageDiskCache 读)`。
   - 歌词可选：迁移时**建议跳过联网歌词**（避免一次性几十首 ×8s），只写已有封面/文本；或提供开关。
5. 更新索引：`DownloadEntry.filePath = 最终路径`，`_persistDownloads()`。
6. 媒体库：**只对公共目录**调用 `scanForMediaLibrary(最终路径)`（App 专属目录调用无副作用，但也没意义）。
7. 汇总：成功/跳过/失败计数，失败只记日志并可重试；不要因为单个失败中断整批。

### 2.4 MediaStore 旧条目（最大难点，需真机验证）

- 现状：`AndroidStorageAccess.scanFile()` → `MediaScannerConnection.scanFile(path, ...)`，**没有删除能力**。
- 扩展名 rename 后，旧路径文件不存在，但 MediaStore 里的旧条目可能残留（表现为重复/幽灵条目，艺人可能还是未知）。
- 可选处理，按风险从低到高：
  - a. rename 后同时扫一次旧路径（部分 ROM 在路径不存在时会移除条目，**行为不保证**）；
  - b. 原生新增 `deleteMediaByPath`（MediaStore query + delete），需要处理分区存储/权限/失败回滚，风险较高；
  - c. 接受「可能残留旧条目」，文档说明，等用户清理媒体库或系统全盘扫描；
  - d. 不 rename，只写标签（不解决扩展名撒谎）。
- 建议：先按 **a + c** 实现，真机验证后再决定是否做 b。

### 2.5 执行控制

- 并发：复用/降低 `DownloadController._metadataConcurrency`（当前 3），迁移建议 1-2，避免批量重写大 FLAC 打满 IO。
- 磁盘：标签写入是「临时文件 + rename」，峰值约 2× 文件大小；失败时原文件保留。大文件前建议至少做一次可用空间粗检（无现成 API 可先 catch 失败并提示）。
- 中断恢复：每处理完一个文件就落盘索引/进度，杀进程后重跑应幂等（已正确的文件再处理一遍结果不变，但 FLAC 会重写，可先按扩展名 + 版本标记过滤）。
- 幂等：不修改音频帧；重复处理不产生 `(n)` 副本（依赖 `resolveNonCollidingPath` 的音频字节比较）。
- 回滚：不删除文件；writer 自身临时文件+rename，失败保留原文件。

### 2.6 验收标准

单元测试（临时目录 + 真实字节样本，参考 `test/services/download_metadata_test.dart` 的构造方式）：

- `.flac` 里是 MP3 → 改名 `.mp3` + 写 ID3；
- `.mp3` 里是 FLAC → 改名 `.flac` + 写 Vorbis comment；
- 扩展名已正确 → 只补标签/扫描；
- 目标名已存在且内容不同 → `(n)` 备份名；
- unsupported / 文件被占用 / 读失败 → 原文件与索引不变，后续可重试；
- 索引 `filePath` 更新、prefs 持久化、第二次执行无变化；
- 扫描调用顺序在写标签之后（和任务 B 共用 fake）。

真机（Android 10/13/14，各一次）：

- 默认 App 专属目录：迁移可完成，媒体库无新增条目（符合预期）；
- 自定义公共目录：系统音乐/车机蓝牙/文件管理器显示正确艺人/专辑/封面，无重复条目或已接受残留；
- 迁移中杀进程后重启可继续，不产生重复文件；
- 桌面（Windows/Linux）：含中文/空格/超长文件名的目录可处理。

### 2.7 工作量与风险

- 预估 **1.5–3 人日**（含单测与 Android 真机）；MediaStore 旧条目是主要不确定项。
- 主要风险：大文件重写（磁盘/IO/中断）、rename 被占用失败、媒体库残留、误处理非索引文件（务必只遍历索引）。
- 不做的影响：功能只覆盖新下载；主要影响「下载到公共目录/拷到车机/U 盘」的用户，App 内播放不受影响。

## 3. 任务 B：扫描顺序测试

### 3.1 现状

`5ccfac2` 把扫描从 `DownloadService._executeTask` 挪到 `DownloadController._enrichDownload` 的写标签之后；但 `test/` 里没有任何 `scanForMediaLibrary`/`scanFile` 引用。实测把该提交整体回滚，现有测试仍全绿——顺序一旦被改回去，只有真机 MediaStore/车机才能发现。

### 3.2 建议测试（控制器层，无需 Android 真机）

- 需要专用 fake `DownloadService`（现有 `test/controllers/download_quality_test.dart:365` 的 fake 是 `implements DownloadService` + `noSuchMethod` 抛错，`_enrichDownload` 会把异常吞掉，走不到写标签/扫描），记录调用序列：
  - `download()` 返回临时文件路径；
  - `writeDownloadMetadata()` 记录被调用（可返回成功/抛错两种配置）；
  - `scanForMediaLibrary()` 记录被调用。
- 用例：
  1. 下载成功 → 断言顺序 `download → writeDownloadMetadata → scanForMediaLibrary`；
  2. 写标签抛异常 → 断言扫描是否仍发生（若把扫描移进 `finally`/`_enrichDownload` 末尾，则必须扫描；若保持现状，则明确断言不扫描并在注释写清原因）；
  3. `_disposed`/代际过期 → 不写索引（现有代际用例可复用，重点补扫描断言）。
- 预期改动：如果按「写标签失败也要扫描」的语义，把 `_enrichDownload` 里的 `unawaited(scanForMediaLibrary(path))` 移到标签写入之后的 `finally`/统一出口，并加对应断言。

### 3.3 工作量

- **0.5–1 小时**；建议合并进下一次下载相关改动一起做，也可独立提交。

## 4. 代码入口（当前 main）

- `lib/controllers/download_controller.dart`
  - `_download` → `_enrichDownload`（歌词 + 写标签 + `scanForMediaLibrary`）
  - `reconcileDownloads`（只按 basename 搬目录/找回）
  - `_metadataConcurrency`、`_persistDownloads`、`_downloadsIndexKey`
- `lib/services/download_service.dart`
  - `_executeTask`（新下载完成后 `_correctExtension`）、`_correctExtension`
  - `writeDownloadMetadata`、`scanForMediaLibrary`
  - `resolveNonCollidingPath`、`_audioContentLength`、`_flacMetadataLength`
- `lib/services/download_metadata_writer.dart`（`write`、`lyricsFilePath`、`downloadLyricsText`）
- `lib/services/id3_tag_writer.dart`（`tempSuffix = '.id3.tmp'`，要求路径 `.mp3`）
- `lib/services/flac_tag_writer.dart`（`tempSuffix = '.tag.tmp'`）
- `lib/services/audio_file_format.dart`（`inspectAudioFile`）
- `lib/services/android_storage_access.dart`（`scanFile`）
- 原生：`android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt` 的 `"scanFile"` 分支（`MediaScannerConnection.scanFile`，无删除）
- 测试参考：`test/services/download_metadata_test.dart`、`test/services/download_service_id3_test.dart`、`test/controllers/download_quality_test.dart`

## 5. 顺手可修的已知小问题（不阻塞）

- `.tag.tmp` / `.id3.tmp` 崩溃残留没有清理器（`clearPlayCacheDir` 只清播放缓存目录的 `.part`；下载目录无对应清理）。
- `DownloadMetadataResult` 被调用方丢弃：标签失败/已另存 `.lrc` 目前无 UI 提示，迁移时可以接汇总 Toast。
- `id3_tag_writer.dart` 要求路径以 `.mp3` 结尾，与 `DownloadMetadataWriter` 按字节分派不一致：`_correctExtension` 的 rename 若失败（占用/权限），文本标签会全丢。
- `flac_tag_writer.dart` 的封面字节 > 0xffffff（约 16MB）会让整次标签写入失败；ID3 侧只是跳过封面，两端不对称，建议先判断封面长度、超限只跳封面。
- 网易云下架曲：`_resolvePlayUrl` 的网易分支永远返回非空外链，load 失败走普通重试/3 次阈值，不参与「无音源一次即跳」；错误文案「网易云歌曲暂时没有可播放地址」实际是死代码。
- 重下同歌且未开「保存 LRC」时，旧 `.lrc` 不会被删除/覆盖（可能读到旧歌词）。

## 6. 决策建议

- **扫描顺序测试**：低成本，建议做（可独立提交，不依赖真机）。
- **旧库迁移/补扫**：不是必须。判断标准：
  - 有较多「下载到公共目录给车机/第三方播放器」的用户，或收到过「已下载的歌显示未知艺人/扩展名错打不开」反馈 → 值得做，按任务 A 排期；
  - 用户主要 App 内播放、默认目录 → 优先级低，可先只做「设置页手动修复」的最小版本。
- 无论是否做迁移，都建议先补任务 B 的测试，避免现有顺序被无意识改回去。
