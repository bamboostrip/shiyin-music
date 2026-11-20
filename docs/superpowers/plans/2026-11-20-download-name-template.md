# 下载文件命名模板设置 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 下载文件命名增加用户可选模板（`歌手-歌名` 默认 / `歌名-歌手`），设置入口在「设置 → 存储与下载」。

**Architecture:** 枚举模板 + `DownloadService` 按需读 prefs（`_executeTask` 时逐任务读取，仅用户下载应用模板，播放缓存恒默认）；设置项为独立 StatefulWidget 直接读写 prefs，不经 `DownloadController`。

**Tech Stack:** Flutter/Dart、shared_preferences、flutter_test（`SharedPreferences.setMockInitialValues`）。

**Spec:** `docs/superpowers/specs/2026-11-20-download-name-template-design.md`

## Global Constraints

- 模板仅对**新下载**（`DownloadTaskKind.download`）生效；播放缓存（`playCache`）恒用默认模板 `artistTitle`。
- 分隔符固定 `-`；清洗（`_sanitizeFileName`）、120 码点截断、空段回退 hash 逻辑一律不动。
- prefs key `settings.download_name_template`；存储值 `'artist-title'` / `'title-artist'`；缺失或脏值回退 `artistTitle`。
- UI 选项文案必须注明「仅对新下载生效，已下载文件不改名」。
- 写 prefs 失败时保持原值并 `Toast.error`（对齐下载音质设置的失败语义）。
- 环境：Windows + Git Bash；测试命令用 `flutter test <path>`，全量 `flutter test`。

---

### Task 1: 模板枚举 + 命名逻辑（service 层）

**Files:**
- Modify: `lib/services/download_service.dart`（`fileNameFor` 约 :483、`_executeTask` 约 :601、枚举加在 `DownloadTaskKind` 约 :21 附近）
- Test (Create): `test/services/download_service_name_template_test.dart`

**Interfaces:**
- Produces（Task 2 与测试依赖，签名逐字）:
  - `enum DownloadNameTemplate { artistTitle, titleArtist }`，字段 `storedValue`/`label`/`example`（String）；
  - `static const String downloadNameTemplateKey = 'settings.download_name_template';`（DownloadService 静态成员）;
  - `static DownloadNameTemplate nameTemplateFromStored(String? stored)`；
  - `static String storedNameTemplateValue(DownloadNameTemplate template)`；
  - `static Future<DownloadNameTemplate> loadNameTemplate()`；
  - `Future<String> fileNameForTask(Song song, AudioQuality quality, DownloadTaskKind kind)`（实例方法）;
  - `String fileNameFor(Song song, AudioQuality quality, {DownloadNameTemplate template = DownloadNameTemplate.artistTitle})`（签名向后兼容）。

- [ ] **Step 1: 写失败测试**

创建 `test/services/download_service_name_template_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/download_service.dart';

void main() {
  const song = Song(id: 'hash1', title: '晴天', artist: '周杰伦', hash: 'hash1');

  group('fileNameFor 模板', () {
    test('默认与显式 artistTitle = 现状命名', () {
      final service = DownloadService();
      expect(service.fileNameFor(song, AudioQuality.lossless), '周杰伦-晴天.flac');
      expect(
        service.fileNameFor(song, AudioQuality.standard,
            template: DownloadNameTemplate.artistTitle),
        '周杰伦-晴天.mp3',
      );
    });

    test('titleArtist = 歌名在前', () {
      final service = DownloadService();
      expect(
        service.fileNameFor(song, AudioQuality.standard,
            template: DownloadNameTemplate.titleArtist),
        '晴天-周杰伦.mp3',
      );
    });

    test('模板作用于各自清洗后的段', () {
      final service = DownloadService();
      const dirty =
          Song(id: 'h', title: 'Tra?g|edy', artist: 'AC/DC', hash: 'h');
      expect(
        service.fileNameFor(dirty, AudioQuality.standard,
            template: DownloadNameTemplate.titleArtist),
        'Tra_g_gedy-AC_DC.mp3',
      );
    });

    test('空段回退 hash 不受模板影响', () {
      final service = DownloadService();
      const noTitle = Song(id: 'h', title: '', artist: '周杰伦', hash: 'ab-1');
      expect(
        service.fileNameFor(noTitle, AudioQuality.standard,
            template: DownloadNameTemplate.titleArtist),
        'ab-1.mp3',
      );
    });
  });

  group('prefs 读取', () {
    test('nameTemplateFromStored：合法/缺失/脏值', () {
      expect(DownloadService.nameTemplateFromStored('title-artist'),
          DownloadNameTemplate.titleArtist);
      expect(DownloadService.nameTemplateFromStored('artist-title'),
          DownloadNameTemplate.artistTitle);
      expect(DownloadService.nameTemplateFromStored(null),
          DownloadNameTemplate.artistTitle);
      expect(DownloadService.nameTemplateFromStored('garbage'),
          DownloadNameTemplate.artistTitle);
    });

    test('storedNameTemplateValue 与 nameTemplateFromStored 互逆', () {
      for (final t in DownloadNameTemplate.values) {
        expect(DownloadService.nameTemplateFromStored(
            DownloadService.storedNameTemplateValue(t)), t);
      }
    });

    test('loadNameTemplate 读 prefs', () async {
      SharedPreferences.setMockInitialValues({
        DownloadService.downloadNameTemplateKey: 'title-artist',
      });
      expect(await DownloadService.loadNameTemplate(),
          DownloadNameTemplate.titleArtist);
      SharedPreferences.setMockInitialValues({});
      expect(await DownloadService.loadNameTemplate(),
          DownloadNameTemplate.artistTitle);
    });
  });

  group('fileNameForTask 按任务类型分流', () {
    test('playCache 恒默认模板（prefs 里设了 title-artist 也不影响）', () async {
      SharedPreferences.setMockInitialValues({
        DownloadService.downloadNameTemplateKey: 'title-artist',
      });
      final service = DownloadService();
      expect(
        await service.fileNameForTask(
            song, AudioQuality.standard, DownloadTaskKind.playCache),
        '周杰伦-晴天.mp3',
      );
    });

    test('download 按设置模板', () async {
      SharedPreferences.setMockInitialValues({
        DownloadService.downloadNameTemplateKey: 'title-artist',
      });
      final service = DownloadService();
      expect(
        await service.fileNameForTask(
            song, AudioQuality.lossless, DownloadTaskKind.download),
        '晴天-周杰伦.flac',
      );
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/services/download_service_name_template_test.dart`
Expected: FAIL——`DownloadNameTemplate`、`downloadNameTemplateKey`、`nameTemplateFromStored` 等未定义（编译错误）。

- [ ] **Step 3: 实现 service 层**

`lib/services/download_service.dart` 三处改动：

(a) `DownloadTaskKind` 枚举旁（约 :21）新增模板枚举：

```dart
/// 下载文件命名模板：`{歌手}-{歌名}`（默认，历史行为）或 `{歌名}-{歌手}`。
///
/// 只作用于**新下载**；播放缓存恒用默认模板——内部缓存按 codec 探测的
/// 路径匹配索引，模板混入只会制造索引失配，且缓存文件名用户不可见。
enum DownloadNameTemplate {
  artistTitle('artist-title', '歌手-歌名', '周杰伦-晴天.mp3'),
  titleArtist('title-artist', '歌名-歌手', '晴天-周杰伦.mp3');

  const DownloadNameTemplate(this.storedValue, this.label, this.example);

  /// prefs 存储值（settings.download_name_template）。
  final String storedValue;

  /// 设置项展示名。
  final String label;

  /// 示例文件名（真实感展示，帮用户理解两种顺序的差别）。
  final String example;
}
```

(b) `DownloadService` 类内（`downloadDirOverrideKey` 约 :65 附近）新增静态成员与辅助：

```dart
  /// 下载文件命名模板 prefs key（见 [DownloadNameTemplate]）。
  static const String downloadNameTemplateKey = 'settings.download_name_template';

  /// prefs 存储值 → 模板。缺失/脏值一律回退默认 [DownloadNameTemplate.artistTitle]
  /// （与 `settings.download_quality` 的脏值策略一致：手改/旧数据不能把下载锁死）。
  static DownloadNameTemplate nameTemplateFromStored(String? stored) =>
      DownloadNameTemplate.values.firstWhere(
        (t) => t.storedValue == stored,
        orElse: () => DownloadNameTemplate.artistTitle,
      );

  /// 模板 → prefs 存储值。
  static String storedNameTemplateValue(DownloadNameTemplate template) =>
      template.storedValue;

  /// 读取当前命名模板（按需 getInstance：SharedPreferences 有内存缓存，
  /// 与 [downloadDir] 的读取模式一致；逐任务读取使队列中途改模板对后续
  /// 任务立即生效）。
  static Future<DownloadNameTemplate> loadNameTemplate() async {
    final prefs = await SharedPreferences.getInstance();
    return nameTemplateFromStored(prefs.getString(downloadNameTemplateKey));
  }

  /// 任务落盘文件名：用户下载按设置模板；播放缓存恒默认模板（见
  /// [DownloadNameTemplate] 的说明）。
  Future<String> fileNameForTask(
    Song song,
    AudioQuality quality,
    DownloadTaskKind kind,
  ) {
    if (kind != DownloadTaskKind.download) {
      return Future.value(fileNameFor(song, quality));
    }
    return loadNameTemplate().then(
      (template) => fileNameFor(song, quality, template: template),
    );
  }
```

(c) `fileNameFor`（约 :483）加可选参数并按模板拼接（默认值保证既有调用点零改动）：

```dart
  /// 文件命名：模板决定 `{歌手}-{歌名}` 或 `{歌名}-{歌手}`；`{ext}` 按音质。
  String fileNameFor(
    Song song,
    AudioQuality quality, {
    DownloadNameTemplate template = DownloadNameTemplate.artistTitle,
  }) {
    final ext = quality == AudioQuality.lossless ? 'flac' : 'mp3';
    final safeArtist = _sanitizeFileName(song.artist);
    final safeTitle = _sanitizeFileName(song.title);
    final name = (safeArtist.isNotEmpty && safeTitle.isNotEmpty)
        ? switch (template) {
            DownloadNameTemplate.artistTitle => '$safeArtist-$safeTitle',
            DownloadNameTemplate.titleArtist => '$safeTitle-$safeArtist',
          }
        : song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '$name.$ext';
  }
```

(d) `_executeTask`（约 :601）把 `final fileName = fileNameFor(task.song, task.quality);` 改为：

```dart
    final fileName = await fileNameForTask(task.song, task.quality, task.kind);
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/services/download_service_name_template_test.dart`
Expected: PASS（全部用例）。

- [ ] **Step 5: 回归既有下载测试**

Run: `flutter test test/services/download_service_resume_test.dart test/controllers/download_hash_normalization_test.dart`
Expected: PASS（零改动兼容验证）。

- [ ] **Step 6: Commit**

```bash
git add lib/services/download_service.dart test/services/download_service_name_template_test.dart
git commit -m "feat(download): 文件命名模板枚举与落盘分流（歌手-歌名/歌名-歌手，播放缓存恒默认）"
```

---

### Task 2: 设置项 UI + 挂载

**Files:**
- Create: `lib/ui/settings/download_name_template_settings.dart`
- Modify: `lib/ui/settings/storage_settings_section.dart`（约 :36-47 的下载分节 + 顶部 import）
- Test (Create): `test/ui/settings/download_name_template_settings_test.dart`

**Interfaces:**
- Consumes（Task 1 产物，逐字）: `DownloadService.downloadNameTemplateKey`、`DownloadService.loadNameTemplate()`、`DownloadService.storedNameTemplateValue(...)`、`DownloadNameTemplate`（含 `label`/`example`/`storedValue`）。
- Produces: `class DownloadNameTemplateSettings extends StatefulWidget`，构造 `const DownloadNameTemplateSettings({super.key})`（无参，不依赖 controller）。

- [ ] **Step 1: 写失败 widget 测试**

创建 `test/ui/settings/download_name_template_settings_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/ui/settings/download_name_template_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('初始渲染默认模板副标题', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DownloadNameTemplateSettings()),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('歌手-歌名（示例'), findsOneWidget);
  });

  testWidgets('已设置的模板在进入时正确回显', (tester) async {
    SharedPreferences.setMockInitialValues({
      DownloadService.downloadNameTemplateKey: 'title-artist',
    });
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DownloadNameTemplateSettings()),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('歌名-歌手（示例'), findsOneWidget);
  });

  testWidgets('选择「歌名-歌手」写入 prefs 并更新副标题', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DownloadNameTemplateSettings()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下载文件名'));
    await tester.pumpAndSettle();
    // 弹窗里点「歌名-歌手」选项（title 精确匹配，避开副标题里的字样）。
    await tester.tap(find.widgetWithText(RadioListTile<DownloadNameTemplate>, '歌名-歌手'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DownloadService.downloadNameTemplateKey),
        'title-artist');
    expect(find.textContaining('歌名-歌手（示例'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/ui/settings/download_name_template_settings_test.dart`
Expected: FAIL——`download_name_template_settings.dart` 不存在（编译错误）。

- [ ] **Step 3: 实现设置组件**

创建 `lib/ui/settings/download_name_template_settings.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/download_service.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 「下载文件名」设置项（设置 → 存储与下载）。
///
/// 只决定**新下载**的命名顺序模板（[DownloadNameTemplate]）；已下载文件
/// 不改名。直接读写 prefs、不经 [DownloadController]：模板不进控制器状态，
/// 真正的消费方（DownloadService）在任务执行时自行读取。
class DownloadNameTemplateSettings extends StatefulWidget {
  const DownloadNameTemplateSettings({super.key});

  @override
  State<DownloadNameTemplateSettings> createState() =>
      _DownloadNameTemplateSettingsState();
}

class _DownloadNameTemplateSettingsState
    extends State<DownloadNameTemplateSettings> {
  /// 正在写入设置：忽略重复点击，并在瓦片图标位转圈（对齐下载音质项）。
  bool _saving = false;

  DownloadNameTemplate _template = DownloadNameTemplate.artistTitle;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final template = await DownloadService.loadNameTemplate();
    if (!mounted) return;
    setState(() => _template = template);
  }

  /// 瓦片副标题：模板名 + 示例文件名，一眼看懂两种顺序的差别。
  String get _subtitle => '${_template.label}（示例：${_template.example}）';

  Future<void> _selectTemplate() async {
    if (_saving) return;
    final selected = await showDialog<DownloadNameTemplate>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载文件名'),
        content: SingleChildScrollView(
          child: RadioGroup<DownloadNameTemplate>(
            groupValue: _template,
            onChanged: (value) {
              if (value == null) return;
              Navigator.of(dialogContext).pop(value);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final template in DownloadNameTemplate.values)
                  RadioListTile<DownloadNameTemplate>(
                    value: template,
                    title: Text(template.label),
                    subtitle: Text(
                      '示例：${template.example}'
                      '${template == DownloadNameTemplate.artistTitle ? '（默认）' : ''}；'
                      '仅对新下载生效，已下载文件不改名',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted || selected == _template) return;
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        DownloadService.downloadNameTemplateKey,
        DownloadService.storedNameTemplateValue(selected),
      );
      if (!mounted) return;
      setState(() => _template = selected);
      debugPrint('[设置] 下载文件名模板已更新: ${selected.storedValue}');
    } catch (error) {
      // 写 prefs 失败（存储异常/平台通道异常）时已选模板不会生效，必须
      // 明确提示并对齐到原值，否则用户下次下载才发现命名没变。
      debugPrint('[设置] 保存下载文件名模板失败: $error');
      if (mounted) Toast.error('保存下载文件名设置失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      icon: Icons.drive_file_rename_outline_rounded,
      iconColor: const Color(0xFF00897B),
      title: '下载文件名',
      subtitle: _subtitle,
      loading: _saving,
      onTap: _selectTemplate,
    );
  }
}
```

注意：`DownloadController` 的 import 不需要；`Toast` 来自 `../widgets/toast.dart`（与 download_quality_settings.dart 同路径）。`RadioGroup` 是 Flutter 3.44 组件（下载音质设置已在用），照抄同款形态。

- [ ] **Step 4: 挂载到存储设置分节**

`lib/ui/settings/storage_settings_section.dart`：

(a) 顶部 import 区加：

```dart
import 'download_name_template_settings.dart';
```

(b) 下载分节（`DownloadQualitySettings(...)` 之后、`_SaveLyricsFileTile` 之前）插入：

```dart
        children.add(const SettingsDivider());
        // 下载文件命名模板：与音质同属「下载产出物」属性，紧跟音质项。
        children.add(const DownloadNameTemplateSettings());
```

（即原 `children.add(const SettingsDivider()); children.add(_SaveLyricsFileTile(...));` 前多出这两行，`_SaveLyricsFileTile` 前原有的 divider 保持不变。）

- [ ] **Step 5: 跑 widget 测试确认通过**

Run: `flutter test test/ui/settings/download_name_template_settings_test.dart`
Expected: PASS（3 个用例）。

- [ ] **Step 6: analyze 检查**

Run: `flutter analyze`
Expected: 0 issues。

- [ ] **Step 7: Commit**

```bash
git add lib/ui/settings/download_name_template_settings.dart lib/ui/settings/storage_settings_section.dart test/ui/settings/download_name_template_settings_test.dart
git commit -m "feat(download): 「下载文件名」设置项——命名模板切换入口（设置→存储与下载）"
```

---

### Task 3: 全量验证

**Files:** 无新改动（如有回归修复则修后单独提交）

- [ ] **Step 1: 全量测试**

Run: `flutter test`
Expected: All tests passed（基线 2144+1skip 上下浮动仅来自本特性新增用例；不允许出现既有用例失败）。

- [ ] **Step 2: analyze 最终态**

Run: `flutter analyze`
Expected: 0 issues。

- [ ] **Step 3: 汇报**

向主会话汇报：新增用例数、全量测试结果、analyze 结果、提交列表（`git log --oneline main..HEAD`）。
