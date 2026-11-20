# 下载文件命名模板设置 · 设计文档

日期：2026-11-20
分支：`feat/download-name-template`
状态：已获用户批准（方案 A）

## 背景与目标

当前下载文件命名固定为 `{歌手}-{歌名}.{ext}`（`DownloadService.fileNameFor`）。
本功能增加一个用户设置，可选择命名顺序模板：

- `artistTitle`（默认）：`歌手-歌名` —— 与现状一致；
- `titleArtist`：`歌名-歌手`。

不做的（YAGNI）：自定义模板串（foobar2000 式 `%artist%`）、带空格分隔符变体、
已下载文件的批量重命名/迁移。

## 方案要点（A：模板枚举 + 服务按需读 prefs）

### 1. 模板定义与存储

- 枚举 `DownloadNameTemplate { artistTitle, titleArtist }`，定义在
  `lib/services/download_service.dart`（命名逻辑所在文件，无跨文件依赖）。
- prefs key：`settings.download_name_template`，值 `'artist-title'` /
  `'title-artist'`。缺失、脏值一律回退 `artistTitle`（与
  `settings.download_quality` 的脏值策略一致）。
- 分隔符固定 `-`，不开放配置。

### 2. 命名逻辑

- `fileNameFor(Song song, AudioQuality quality,
  {DownloadNameTemplate template = DownloadNameTemplate.artistTitle})`：
  加可选参数，默认值保证既有调用点与既有测试零改动。
  - `artistTitle`：`$safeArtist-$safeTitle`（现状）；
  - `titleArtist`：`$safeTitle-$safeArtist`；
  - 空段回退 hash、`_sanitizeFileName` 清洗、120 码点截断：全部不动
    （两段各自清洗后再按模板拼接）。
- `_executeTask` 仅在 `task.kind == DownloadTaskKind.download` 时读一次
  模板并传入；**播放缓存（playCache）恒用默认模板**：
  - 内部缓存按 codec 探测的路径匹配索引，混入模板徒增索引失配风险；
  - 播放缓存文件名用户不可见，无产品价值。
- `DownloadService` 提供 `loadNameTemplate()`（`SharedPreferences.getInstance`
  按需读，与 `downloadDir()` 同模式；getInstance 有内存缓存，无性能问题）。
- 自动跟随、零改动的下游：`.lrc` 边车路径（从落盘路径派生）、
  `_correctExtension`（在已有路径上改扩展名，不重推文件名）、
  `resolveNonCollidingPath` 防覆盖 `(n)` 序号。

### 3. 生效语义

- 仅影响设置之后的新下载；已下载文件不改名、不迁移。
- UI 选项文案明确注明「仅对新下载生效」。
- 下载队列执行中途切换模板：后续任务用新模板（按任务粒度读 prefs，
  行为合理无需额外处理）。

### 4. 设置 UI

- 新文件 `lib/ui/settings/download_name_template_settings.dart`：
  `DownloadNameTemplateSettings`，形态仿 `DownloadQualitySettings`——
  `SettingsTile` + radio choice dialog（`showDialog` + `RadioListTile`）。
  - 标题：「下载文件名」；
  - 副标题：当前模板预览 + 真实示例文件名（如 `周杰伦-晴天.mp3` /
    `晴天-周杰伦.mp3`）；
  - 选项副文本注明「仅对新下载生效，已下载文件不改名」。
- 直接读写 prefs：initState 异步读 + 写入成功后 setState；不经
  `DownloadController`（模板不进控制器状态）。写入失败（prefs 异常）时
  选项不生效并保持原值——对齐 quality 设置的失败语义。
- 挂载点：`StorageSettingsSection`（`lib/ui/settings/storage_settings_section.dart`）
  下载分节，紧跟 `DownloadQualitySettings` 之后，全平台同位。

### 5. 测试

- Service 单测（`test/services/download_service_name_template_test.dart` 或
  并入既有命名测试）：
  - 两种模板的拼接结果（含清洗交互：非法字符、超长截断）；
  - 空歌手/空歌名 → hash 回退不受模板影响；
  - prefs 脏值/缺失 → 回退 `artistTitle`；
  - 播放缓存路径恒默认模板（`_executeTask` 分支）。
- Widget 测试：设置项渲染当前模板 subtitle；选择另一模板后 prefs 写入
  成功且 subtitle 更新。

## 验收标准

1. 设置里可在两种模板间切换，副标题实时反映；
2. 新下载文件名按所选模板落盘；播放缓存不受影响；
3. 既有下载行为（清洗、截断、防覆盖、`.lrc`、扩展名纠正）回归不变；
4. `flutter analyze` 0 告警、`flutter test` 全绿。
