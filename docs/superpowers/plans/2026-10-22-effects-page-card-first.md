# 音效页卡片化改版 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 音效页层级倒转——主界面即卡片选择（关闭卡 + 6 音效档案卡 + 16 均衡器预设卡 + 自定义入口卡），手动调线下沉到推入的「自定义均衡器」深层页；点任何效果卡自动开启 EQ。

**Architecture:** 纯 UI + 控制器小改。`audio_effects_sheet.dart` 重构（卡片面板替换推子面板、删除底部弹层选择器与车机右栏快捷区、新增深层编辑页路由）；`player_controller.effects.dart` 两处行为变更（预设即点即开、一键全关）。预设/档案数据层、增强面板、桌面 mpv af 链、Android 原生通道全部不动。

**Tech Stack:** Flutter/Dart，widget 测试（fake PlayerController），控制器单测（fake AudioPlayer/Handler 照搬 audio_effect_profile_apply_test.dart）。

**Spec:** `docs/superpowers/specs/2026-10-22-effects-page-card-first-design.md`

## Global Constraints

- 分支 `feat/audio-effects-profiles` 上直接提交；**不 push**（分支合入/推送决策归用户）。
- 禁止改动：`lib/models/audio_effect_presets.dart`、桌面 mpv af 滤镜链（DesktopAudioFilters）、Android audio_effects 通道、五处入口调用点（landscape_player/desktop_player_bar/player_top_bar/poster_player/playback_settings_section）。
- Android 编译门必须用 `:app:compileImpellerDebugKotlin`（裸 `compileDebugKotlin` 是空转门，app 有 impeller/skia flavor）。
- `build_apk.bat` 本机不可用（写死不存在的 E 盘路径），不要调用。
- 提交信息遵循仓库惯例：`feat(effects): 中文摘要`。
- 手动调 band → presetName=「自定义」、档案应用自动开 EQ，这两个既有语义保持不变。

---

### Task 1: 控制器语义——预设即点即开 EQ + 一键全关

**Files:**
- Modify: `lib/controllers/player_controller.effects.dart`（applyEqualizerPreset 约 100-111 行；新增 disableAllAudioEffects，放 resetEqualizer 之后）
- Create: `test/controllers/equalizer_preset_card_semantics_test.dart`

**Interfaces:**
- Consumes: 既有 `PlayerController(api, handler)` 构造、`PlayerController.equalizerPresets`/`audioEffectProfiles` 静态表、私有 `_persistEqualizer`/`_applyEqualizer`/`_applyBassBoost`/`_applySurround` 与 `_equalizerEnabledSettingKey` 等 prefs 键。
- Produces: `Future<void> disableAllAudioEffects()` —— 关 EQ/低音/环绕三个开关、保留曲线与强度记忆、持久化三个 enabled 位、单次 notifyListeners。`applyEqualizerPreset` 新语义：无论此前 EQ 是否开启，应用后 `equalizerEnabled == true` 且立即 `_applyEqualizer()`（Task 2 的 UI 依赖此语义做「即点即响」）。

- [ ] **Step 1: 写失败测试**

创建 `test/controllers/equalizer_preset_card_semantics_test.dart`，完整内容如下（fake 骨架照搬 `test/controllers/audio_effect_profile_apply_test.dart`，该文件在仓库中，可直接对照）：

```dart
// 音效页卡片化的两条控制器语义：
//   1. applyEqualizerPreset 即点即响：无论此前 EQ 开关状态，应用预设后
//      EQ 自动开启并立即生效（卡片化主界面点预设卡必须听得见变化；
//      启动恢复不走这里，不受影响）；
//   2. disableAllAudioEffects 一键全关：EQ/低音/环绕三个开关同时关闭，
//      曲线与强度保留记忆（重新点任一效果卡即恢复）。
//
// fake api/audioHandler 搭建照搬 audio_effect_profile_apply_test.dart
// （_FakeAudioPlayer/_RecordingAudioHandler/_MockMusicApi）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();
  final _errorController = StreamController<PlayerException>.broadcast();
  final _androidAudioSessionIdController = StreamController<int?>.broadcast();

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      _processingStateController.stream;

  @override
  Stream<int?> get androidAudioSessionIdStream =>
      _androidAudioSessionIdController.stream;

  @override
  Stream<PlayerException> get errorStream => _errorController.stream;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Duration get position => Duration.zero;

  @override
  bool get playing => false;

  @override
  ProcessingState get processingState => ProcessingState.idle;

  @override
  int? get androidAudioSessionId => null;

  void disposeStreams() {
    _positionController.close();
    _durationController.close();
    _playerStateController.close();
    _processingStateController.close();
    _androidAudioSessionIdController.close();
    _errorController.close();
  }
}

class _RecordingAudioHandler extends Fake implements MusicAudioHandler {
  _RecordingAudioHandler(this._audioPlayer);

  final _FakeAudioPlayer _audioPlayer;
  final List<String> callLogs = [];

  @override
  AudioPlayer get audioPlayer => _audioPlayer;

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {}

  @override
  void detachTransportControls() {}

  @override
  Future<void> seek(Duration position, [dynamic options]) async {
    callLogs.add('seek:${position.inSeconds}');
  }

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    callLogs.add('loadSong:${song.hash}');
  }

  @override
  Future<void> play() async {
    callLogs.add('play');
  }

  @override
  Future<void> pause() async {
    callLogs.add('pause');
  }

  @override
  Future<void> stop() async {
    callLogs.add('stop');
  }

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {
  @override
  Future<SongClimax?> songClimax(String hash) async => null;

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) {
    return Future<PlayUrl>.value(PlayUrl(url: song.id, hash: song.hash));
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('applyEqualizerPreset 即点即开：EQ 自动开启并立即应用', () async {
    // 平台 override windows：桌面分支 _applyDesktopAudioFilters 在单测里
    // 无 MediaKitPlayer 登记（空表 no-op），不触达任何通道。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final fakeAudioPlayer = _FakeAudioPlayer();
    final handler = _RecordingAudioHandler(fakeAudioPlayer);
    final api = _MockMusicApi();
    final controller = PlayerController(api, handler);
    addTearDown(() {
      controller.dispose();
      fakeAudioPlayer.disposeStreams();
    });

    // 构造函数 unawaited 发起 _restoreSettings：先等恢复落定（与
    // audio_effect_profile_apply_test 同款轮询）。
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.equalizerEnabled, isFalse);

    final preset = PlayerController.equalizerPresets
        .firstWhere((p) => p.name == '流行');
    await controller.applyEqualizerPreset(preset);

    expect(controller.equalizerEnabled, isTrue);
    expect(controller.equalizerPresetName, '流行');
    expect(controller.equalizerLevels, preset.levels);

    // 清理持久化，避免污染其它用例。
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  test('disableAllAudioEffects 三件全关且保留曲线与强度记忆', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final fakeAudioPlayer = _FakeAudioPlayer();
    final handler = _RecordingAudioHandler(fakeAudioPlayer);
    final api = _MockMusicApi();
    final controller = PlayerController(api, handler);
    addTearDown(() {
      controller.dispose();
      fakeAudioPlayer.disposeStreams();
    });

    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    // 先开一个档案：EQ/低音/环绕全开且带非零强度与档案曲线。
    final profile = PlayerController.audioEffectProfiles
        .firstWhere((p) => p.name == '全景环绕');
    await controller.applyAudioEffectProfile(profile);
    expect(controller.equalizerEnabled, isTrue);

    await controller.disableAllAudioEffects();

    expect(controller.equalizerEnabled, isFalse);
    expect(controller.bassBoostEnabled, isFalse);
    expect(controller.surroundEnabled, isFalse);
    // 记忆保留：曲线仍是档案曲线，强度未被清零（重开即恢复）。
    expect(controller.equalizerLevels, profile.eqLevels);
    expect(controller.bassBoostStrength, closeTo(0.3, 0.001));
    expect(controller.surroundStrength, closeTo(0.85, 0.001));

    // 全关后再点任一预设，EQ 自动恢复开启（卡片点选即生效闭环）。
    final flat = PlayerController.equalizerPresets.first;
    await controller.applyEqualizerPreset(flat);
    expect(controller.equalizerEnabled, isTrue);

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/controllers/equalizer_preset_card_semantics_test.dart`
Expected: FAIL —— 用例 1 断言 `equalizerEnabled` 为 true 失败（现实现不开 EQ）；用例 2 编译期报 `disableAllAudioEffects` 方法不存在。

- [ ] **Step 3: 实现**

`lib/controllers/player_controller.effects.dart` 中把 `applyEqualizerPreset` 整体替换为：

```dart
  Future<void> applyEqualizerPreset(AudioEffectPreset preset) async {
    // 卡片化音效页：点预设卡即点即响——统一自动开启 EQ（启动恢复不走
    // 这里，不受影响；resetEqualizer 的「重置=平直」同语义即时生效）。
    equalizerEnabled = true;
    equalizerPresetName = preset.name;
    equalizerLevels = PlayerEqualizerLogic.levelsForBandCount(
      preset.levels,
      equalizerLevels.length,
    );
    await _persistEqualizer();
    await _applyEqualizer();
    notifyListeners();
  }
```

紧随 `resetEqualizer` 之后新增：

```dart
  /// 「关闭」卡：EQ/低音/环绕一次性全关。曲线与强度保留记忆，重新点任一
  /// 效果卡即恢复（applyAudioEffectProfile/applyEqualizerPreset 均自动开）。
  Future<void> disableAllAudioEffects() async {
    equalizerEnabled = false;
    bassBoostEnabled = false;
    surroundEnabled = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, false);
    await prefs.setBool(_bassBoostEnabledSettingKey, false);
    await prefs.setBool(_surroundEnabledSettingKey, false);
    await _applyEqualizer();
    await _applyBassBoost();
    await _applySurround();
    notifyListeners();
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/controllers/equalizer_preset_card_semantics_test.dart`
Expected: PASS（2 个用例全绿）

再跑同族既有用例确认无回归：
Run: `flutter test test/controllers/audio_effect_profile_apply_test.dart test/ui/widgets/audio_effects_page_test.dart`
Expected: PASS（旧 UI 测试此刻仍应全绿——它用 fake，不经过真实 applyEqualizerPreset）

- [ ] **Step 5: 提交**

```bash
git add lib/controllers/player_controller.effects.dart test/controllers/equalizer_preset_card_semantics_test.dart
git commit -m "feat(effects): 预设应用即开EQ并新增一键全关语义"
```

---

### Task 2: 音效页卡片化主界面 + 自定义均衡器深层页

**Files:**
- Modify: `lib/ui/widgets/audio_effects_sheet.dart`（主体重构，整文件按下文重写）
- Rewrite: `test/ui/widgets/audio_effects_page_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `disableAllAudioEffects()`；既有 `applyAudioEffectProfile`/`applyEqualizerPreset`/`resetEqualizer`/`setEqualizerEnabled`/`setEqualizerBandLevel`/`equalizerPresetName`/`equalizerLevels`/`equalizerConfig`/`isSurroundSupported`；`AppPillButton(label:, foreground:, background:, onTap:)`（app_dialog.dart）。
- Produces: 页面对外行为——tab 标签「音效｜增强」；主界面卡片网格（关闭卡 + 6 档案卡 + 16 预设卡 + 自定义入口卡）；深层页 AppBar 标题「自定义均衡器」、含启用开关/曲线/频段推子/重置单按钮；选中角标 key 仍为 `ValueKey('effect-selected-badge')`。`showAudioEffectsSheet` 签名不变（五处入口零改动）。

- [ ] **Step 1: 重写 widget 测试（先失败）**

`test/ui/widgets/audio_effects_page_test.dart` 整文件替换为：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/services/audio_effects_service.dart';
import 'package:shiyin_music/ui/widgets/audio_effects_sheet.dart';

class _FakePlayer extends ChangeNotifier implements PlayerController {
  _FakePlayer({this.isAudioEffectsSupported = true});

  @override
  bool isAudioEffectsSupported;

  @override
  EqualizerConfig equalizerConfig = const EqualizerConfig(
    minMillibels: -1500,
    maxMillibels: 1500,
    bands: [
      EqualizerBand(centerHz: 60, levelMillibels: 0),
      EqualizerBand(centerHz: 230, levelMillibels: 0),
      EqualizerBand(centerHz: 910, levelMillibels: 0),
      EqualizerBand(centerHz: 3600, levelMillibels: 0),
      EqualizerBand(centerHz: 14000, levelMillibels: 0),
    ],
  );

  @override
  List<int> equalizerLevels = [0, 0, 0, 0, 0];

  @override
  bool equalizerEnabled = false;

  @override
  String equalizerPresetName = '平直';

  @override
  bool bassBoostEnabled = false;

  @override
  double bassBoostStrength = 0.5;

  @override
  bool surroundEnabled = false;

  @override
  double surroundStrength = 0.6;

  /// 环绕滑条按支持性条件渲染；fake 默认放行以维持既有断言。
  @override
  bool isSurroundSupported = true;

  int setEqualizerEnabledCalls = 0;
  final List<AudioEffectPreset> appliedPresets = [];
  final List<AudioEffectProfile> appliedProfiles = [];
  int resetEqualizerCalls = 0;
  int disableAllEffectsCalls = 0;

  @override
  Future<void> setEqualizerEnabled(bool enabled) async {
    setEqualizerEnabledCalls++;
    equalizerEnabled = enabled;
    notifyListeners();
  }

  @override
  Future<void> setEqualizerBandLevel(
    int index,
    int levelMillibels, {
    bool persist = true,
  }) async {}

  @override
  Future<void> resetEqualizer() async {
    resetEqualizerCalls++;
  }

  @override
  Future<void> applyEqualizerPreset(AudioEffectPreset preset) async {
    appliedPresets.add(preset);
  }

  @override
  Future<void> setBassBoostEnabled(bool enabled) async {}

  @override
  Future<void> setBassBoostStrength(
    double strength, {
    bool persist = true,
  }) async {}

  @override
  Future<void> setSurroundEnabled(bool enabled) async {
    surroundEnabled = enabled;
  }

  @override
  Future<void> setSurroundStrength(
    double strength, {
    bool persist = true,
  }) async {
    surroundStrength = strength;
  }

  @override
  Future<void> applyAudioEffectProfile(AudioEffectProfile profile) async {
    appliedProfiles.add(profile);
  }

  @override
  Future<void> disableAllAudioEffects() async {
    disableAllEffectsCalls++;
    equalizerEnabled = false;
    bassBoostEnabled = false;
    surroundEnabled = false;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpPage(WidgetTester tester, PlayerController player) async {
  // 统一钉住竖屏尺寸（默认 800x600 测试面是横屏，列数断言会漂移）；
  // 横屏见 [_pumpPageLandscape]。
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: AudioEffectsPage(player: player)));
  await tester.pumpAndSettle();
}

Future<void> _pumpPageLandscape(
  WidgetTester tester,
  PlayerController player,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: AudioEffectsPage(player: player)));
  await tester.pumpAndSettle();
}

/// 滚动主界面到 [text] 可见（卡片网格 shrinkWrap 全量构建，滚动只为
/// 让目标进入可点区域）。
Future<void> _scrollTo(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('音效主界面：卡片网格直选，推子与开关已下沉深层页', (tester) async {
    await _pumpPage(tester, _FakePlayer());

    expect(find.text('自定义音效'), findsOneWidget);
    // tab（音效｜增强）+ 音效段标题同名。
    expect(find.text('音效'), findsNWidgets(2));
    expect(find.text('均衡器预设'), findsOneWidget);
    expect(find.text('增强'), findsOneWidget);
    // 关闭卡 + 档案卡在首屏。
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('停用全部音效'), findsOneWidget);
    expect(find.text('全景环绕'), findsOneWidget);
    // 主界面不再有推子/开关/弹层按钮（全部下沉）。
    expect(find.byType(Slider), findsNothing);
    expect(find.text('启用均衡器'), findsNothing);
    expect(find.text('预设'), findsNothing);
    expect(find.text('重置'), findsNothing);
    // 16 预设卡 + 1 自定义入口卡 = 17 枚迷你曲线画板
    // （shrinkWrap 网格全量构建，数量确定）。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter?.runtimeType.toString() == '_PresetCurvePainter',
      ),
      findsNWidgets(17),
    );
  });

  testWidgets('点档案卡透出 applyAudioEffectProfile 且不关页', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('超重低音'));
    await tester.pumpAndSettle();
    expect(player.appliedProfiles.map((p) => p.name), ['超重低音']);
    expect(player.appliedPresets, isEmpty);
    expect(find.text('自定义音效'), findsOneWidget);
  });

  testWidgets('滚动到预设段点预设卡透出 applyEqualizerPreset', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await _scrollTo(tester, '流行');
    await tester.tap(find.text('流行'));
    await tester.pumpAndSettle();
    expect(player.appliedPresets.map((p) => p.name), ['流行']);
    expect(player.appliedProfiles, isEmpty);
  });

  testWidgets('点关闭卡透出 disableAllAudioEffects', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(player.disableAllEffectsCalls, 1);
    expect(player.appliedProfiles, isEmpty);
    expect(player.appliedPresets, isEmpty);
  });

  testWidgets('选中态：EQ 开且预设名命中时该预设卡带唯一角标', (tester) async {
    final player = _FakePlayer()
      ..equalizerEnabled = true; // presetName 默认「平直」
    await _pumpPage(tester, player);

    // 页面上唯一可能选中的来源即「平直」预设卡（档案名无一命中）。
    expect(find.byKey(const ValueKey('effect-selected-badge')), findsOneWidget);
  });

  testWidgets('选中态：三件全关时关闭卡带唯一角标', (tester) async {
    final player = _FakePlayer(); // EQ/低音/环绕默认全关
    await _pumpPage(tester, player);

    // 名字命中类选中均要求 equalizerEnabled，唯一选中来源只能是关闭卡。
    expect(find.byKey(const ValueKey('effect-selected-badge')), findsOneWidget);
    expect(find.text('停用全部音效'), findsOneWidget);
  });

  testWidgets('选中态：手动调过线（自定义）时入口卡带唯一角标', (tester) async {
    final player = _FakePlayer()
      ..equalizerEnabled = true
      ..equalizerPresetName = '自定义';
    await _pumpPage(tester, player);

    expect(find.byKey(const ValueKey('effect-selected-badge')), findsOneWidget);
  });

  testWidgets('自定义入口卡推入编辑页：开关/推子/重置齐全，可返回', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await _scrollTo(tester, '自定义');
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    expect(find.text('自定义均衡器'), findsOneWidget);
    expect(find.text('启用均衡器'), findsOneWidget);
    // fake 配置 5 段 → 5 根推子；频段标签抽查首尾。
    expect(find.text('60'), findsOneWidget);
    expect(find.text('14k'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(5));
    expect(find.text('重置'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('自定义均衡器'), findsNothing);
    expect(find.text('自定义音效'), findsOneWidget);
  });

  testWidgets('编辑页重置按钮透出控制器', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await _scrollTo(tester, '自定义');
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();
    expect(player.resetEqualizerCalls, 1);
  });

  testWidgets('编辑页拨动启用开关透出控制器', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await _scrollTo(tester, '自定义');
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(player.setEqualizerEnabledCalls, 1);
    expect(player.equalizerEnabled, isTrue);
  });

  testWidgets('切换到增强页显示低音增强与环绕，再切回音效卡片页', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('增强'));
    await tester.pumpAndSettle();
    expect(find.text('低音增强'), findsOneWidget);
    expect(find.text('全景环绕'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));

    await tester.tap(find.text('音效').first);
    await tester.pumpAndSettle();
    // 回到卡片主界面：无滑块，关闭卡仍在。
    expect(find.byType(Slider), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('不支持的平台显示占位说明', (tester) async {
    await _pumpPage(tester, _FakePlayer(isAudioEffectsSupported: false));

    expect(find.text('当前平台暂不支持音效调节'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('关闭'), findsNothing);
  });

  testWidgets('横屏整幅卡片网格：右栏快捷区已删，档案卡点选即应用', (tester) async {
    final player = _FakePlayer();
    await _pumpPageLandscape(tester, player);

    // 旧「音效档案」右栏标题不复存在。
    expect(find.text('音效档案'), findsNothing);
    // 卡片网格整幅铺开，档案卡直接点选。
    await tester.tap(find.text('超重低音'));
    await tester.pumpAndSettle();
    expect(player.appliedProfiles.map((p) => p.name), ['超重低音']);
    expect(find.text('自定义音效'), findsOneWidget);
  });

  testWidgets('showAudioEffectsSheet 内容区推入：音效页落在内层 Navigator', (tester) async {
    final player = _FakePlayer();
    // 复刻车机 AppShell 结构：左侧常驻面板 + 内层内容区 Navigator。
    // 推入走最近 Navigator（无显式开关）：入口挂在内容区 Navigator 下即
    // 自然落内容区，常驻面板存活。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 200, child: Text('左侧常驻面板')),
              Expanded(
                child: Navigator(
                  onGenerateRoute: (settings) => MaterialPageRoute(
                    builder: (navContext) => Center(
                      child: ElevatedButton(
                        onPressed: () => showAudioEffectsSheet(
                          context: navContext,
                          player: player,
                        ),
                        child: const Text('打开音效'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开音效'));
    await tester.pumpAndSettle();

    // 音效页已打开，且推的是内层 Navigator：左侧常驻面板仍在树上
    // （若推根 Navigator，home 整页会被不透明路由盖掉）。
    expect(find.text('自定义音效'), findsOneWidget);
    expect(find.text('左侧常驻面板'), findsOneWidget);
    expect(find.text('打开音效'), findsNothing);

    // 深层编辑页同样只占内容区：从卡片网格推入后常驻面板仍在。
    await _scrollTo(tester, '自定义');
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.text('自定义均衡器'), findsOneWidget);
    expect(find.text('左侧常驻面板'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/ui/widgets/audio_effects_page_test.dart`
Expected: FAIL（现实现 tab 名还是「均衡器」、主界面是推子面板、无关闭卡/自定义卡、无编辑页路由；编译可通过——fake 已含 disableAllAudioEffects）

- [ ] **Step 3: 重写 audio_effects_sheet.dart**

整文件替换为以下内容（相对旧版的净变化：tab 名「均衡器」→「音效」；AppBar 去「保存」；车机横屏双栏 LayoutBuilder 与 `_ProfileQuickPane`/`_ProfileQuickCard` 删除；`_EqualizerPanel` 去预设弹层、底部改单颗「重置」药丸、上移到新路由 `_EqualizerEditorPage`；新增 `_EffectsCardPanel`/`_OffCard`/`_CustomEqCard`；`_sheetSectionTitle` 改名 `_sectionTitle`。其余组件逐字保留）：

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/player_controller.dart';
import 'app_dialog.dart';

/// 打开「自定义音效」页。
///
/// 一律推入调用点最近的 Navigator：手机竖屏入口（挂在根 Navigator 的
/// 播放页）整屏展示；车机横屏/桌面的入口本身就挂在内容区 Navigator 上
/// （播放页/设置页），音效页自然只占内容区，常驻面板不被盖住。
Future<void> showAudioEffectsSheet({
  required BuildContext context,
  required PlayerController player,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => AudioEffectsPage(player: player)),
  );
}

class AudioEffectsPage extends StatefulWidget {
  const AudioEffectsPage({super.key, required this.player});

  final PlayerController player;

  @override
  State<AudioEffectsPage> createState() => _AudioEffectsPageState();
}

class _AudioEffectsPageState extends State<AudioEffectsPage> {
  var _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final player = widget.player;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.dark
            : Brightness.light,
      ),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
          title: const Text('自定义音效'),
        ),
        body: AnimatedBuilder(
          animation: player,
          builder: (context, _) {
            if (!player.isAudioEffectsSupported) {
              return _UnsupportedView(colorScheme: colorScheme);
            }

            // 主界面即卡片选择（音效档案 + 均衡器预设 + 自定义入口），
            // 手动调线在「自定义」卡推入的深层页；增强保持第二 tab。
            return Column(
              children: [
                _EffectTabs(index: _tabIndex, onChanged: _setTab),
                Expanded(
                  child: _tabIndex == 0
                      ? _EffectsCardPanel(player: player)
                      : _EnhancePanel(player: player),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _setTab(int value) {
    setState(() => _tabIndex = value);
  }
}

/// 顶部胶囊分段切换（音效/增强）：44 高整圆角胶囊，选中项为悬浮白丸 +
/// 主题色字，与搜索胶囊/药丸按钮同语言。
class _EffectTabs extends StatelessWidget {
  const _EffectTabs({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labels = ['音效', '增强'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Container(
        height: 44,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: isDark
              ? colorScheme.surfaceContainerHighest
              : const Color(0xFFF1F2F5),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            for (final entry in labels.indexed)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(entry.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: entry.$1 == index
                          ? (isDark
                                ? colorScheme.surfaceContainerLowest
                                : Colors.white)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(19),
                      boxShadow: entry.$1 == index
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      entry.$2,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: entry.$1 == index
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 音效 tab 主面板：卡片网格直选（酷狗式）。上段「关闭」+ 音效档案
/// 组合卡，下段带迷你曲线的均衡器预设卡 + 末尾「自定义」入口卡；点选
/// 即应用不关页。窄屏 2 列，宽屏（平板/车机横屏/桌面）3 列。
class _EffectsCardPanel extends StatelessWidget {
  const _EffectsCardPanel({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final crossAxisCount = MediaQuery.sizeOf(context).width >= 600 ? 3 : 2;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _sectionTitle(Theme.of(context), '音效'),
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 104,
          ),
          children: [
            _OffCard(
              selected: _isAllEffectsOff(player),
              onTap: player.disableAllAudioEffects,
            ),
            for (final profile in PlayerController.audioEffectProfiles)
              _ProfileCard(
                profile: profile,
                selected: player.equalizerEnabled &&
                    player.equalizerPresetName == profile.name,
                onTap: () => player.applyAudioEffectProfile(profile),
              ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(Theme.of(context), '均衡器预设'),
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            // 名称行实际高约 20，92 给非默认字号留防溢出余量。
            mainAxisExtent: 92,
          ),
          children: [
            for (final preset in PlayerController.equalizerPresets)
              _PresetCard(
                preset: preset,
                selected: player.equalizerEnabled &&
                    player.equalizerPresetName == preset.name,
                onTap: () => player.applyEqualizerPreset(preset),
              ),
            _CustomEqCard(
              selected: player.equalizerEnabled &&
                  player.equalizerPresetName == '自定义',
              levels: player.equalizerLevels,
              onTap: () => _openEqualizerEditor(context),
            ),
          ],
        ),
      ],
    );
  }

  /// 三件全关才让「关闭」卡选中：环绕不支持的平台（Windows）开关不
  /// 渲染，残留持久化 true 不参与判定。
  bool _isAllEffectsOff(PlayerController player) {
    final surroundOff =
        !(player.surroundEnabled && player.isSurroundSupported);
    return !player.equalizerEnabled &&
        !player.bassBoostEnabled &&
        surroundOff;
  }

  /// 推入最近 Navigator：与音效页自身同语义（车机上编辑页仍只占内容
  /// 区，常驻面板不被盖住）。
  void _openEqualizerEditor(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _EqualizerEditorPage(player: player),
      ),
    );
  }
}

/// 深层「自定义均衡器」页：主界面卡片化后手动调线下沉至此。预设选择
/// 在主界面卡片网格，这里只留启用开关（快速 A/B）、曲线预览、频段推子
/// 与重置。
class _EqualizerEditorPage extends StatelessWidget {
  const _EqualizerEditorPage({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('自定义均衡器')),
      body: AnimatedBuilder(
        animation: player,
        builder: (context, _) => _EqualizerPanel(player: player),
      ),
    );
  }
}

Widget _sectionTitle(ThemeData theme, String text) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
    child: Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
    ),
  );
}

/// 档案卡图标按名字映射（档案表在 models 层，不掺 UI 字段）；改名或
/// 新增档案时回退通用图形，避免空图标。
const _profileIcons = <String, IconData>{
  '全景环绕': Icons.surround_sound_rounded,
  '3D丽音': Icons.auto_awesome_rounded,
  '超重低音': Icons.speaker_rounded,
  '纯净人声': Icons.record_voice_over_rounded,
  '现场演唱会': Icons.stadium_rounded,
  '深夜舒缓': Icons.bedtime_rounded,
};

/// 选中态卡片外壳：与 _EffectTabs 同语言的浅底 + 14 圆角，选中时主题色
/// 描边并在右上角叠一枚对勾角标。
class _SelectableCard extends StatelessWidget {
  const _SelectableCard({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark
          ? colorScheme.surfaceContainerHighest
          : const Color(0xFFF1F2F5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          width: 1.6,
          color: selected ? colorScheme.primary : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: child,
            ),
            if (selected)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  key: const ValueKey('effect-selected-badge'),
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    // 只圆内侧左下角；靠卡片外的一角由 Material 圆角裁掉。
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(13),
                    ),
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: colorScheme.onPrimary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「关闭」卡：一键停用 EQ/低音/环绕三件套（全关时选中）。停用只关
/// 开关不抹记忆，重新点效果卡即恢复——与档案卡同排版（图标+名+描述）。
class _OffCard extends StatelessWidget {
  const _OffCard({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SelectableCard(
      selected: selected,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.power_settings_new_rounded,
            size: 26,
            color: colorScheme.primary,
          ),
          const SizedBox(height: 8),
          Text(
            '关闭',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            '停用全部音效',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final AudioEffectProfile profile;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SelectableCard(
      selected: selected,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _profileIcons[profile.name] ?? Icons.graphic_eq_rounded,
            size: 26,
            color: colorScheme.primary,
          ),
          const SizedBox(height: 8),
          Text(
            profile.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            profile.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「自定义均衡器」入口卡：预设卡同排版（名 + 当前曲线实时预览），点入
/// 推入手动调线页。手动改过频段（presetName=「自定义」）后回主界面带
/// 对勾选中。
class _CustomEqCard extends StatelessWidget {
  const _CustomEqCard({
    required this.selected,
    required this.levels,
    required this.onTap,
  });

  final bool selected;
  final List<int> levels;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SelectableCard(
      selected: selected,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 16, color: colorScheme.primary),
              const SizedBox(width: 5),
              Text(
                '自定义',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            width: double.infinity,
            child: CustomPaint(
              painter: _PresetCurvePainter(
                colorScheme: colorScheme,
                levels: levels,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final AudioEffectPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SelectableCard(
      selected: selected,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            preset.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            width: double.infinity,
            child: CustomPaint(
              painter: _PresetCurvePainter(
                colorScheme: colorScheme,
                levels: preset.levels,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EqualizerPanel extends StatelessWidget {
  const _EqualizerPanel({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final config = player.equalizerConfig;
    final minDb = config.minMillibels / 100;
    final maxDb = config.maxMillibels / 100;

    return Column(
      children: [
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: const Text('启用均衡器'),
          subtitle: Text(
            player.equalizerEnabled ? player.equalizerPresetName : '关闭',
          ),
          value: player.equalizerEnabled,
          onChanged: player.setEqualizerEnabled,
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 64,
          child: CustomPaint(
            painter: _EqualizerCurvePainter(
              colorScheme: colorScheme,
              levels: player.equalizerLevels,
              min: config.minMillibels,
              max: config.maxMillibels,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 56,
                child: Padding(
                  padding: const EdgeInsets.only(top: 26, bottom: 44),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '+${maxDb.round()}dB',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '0dB',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${minDb.round()}dB',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(4, 4, 22, 18),
                  child: Row(
                    children: [
                      for (
                        var index = 0;
                        index < config.bands.length &&
                            index < player.equalizerLevels.length;
                        index++
                      )
                        _EqualizerBandSlider(
                          label: _frequencyLabel(config.bands[index].centerHz),
                          value: player.equalizerLevels[index],
                          min: config.minMillibels,
                          max: config.maxMillibels,
                          enabled: player.equalizerEnabled,
                          onChanged: (value) => player.setEqualizerBandLevel(
                            index,
                            value,
                            persist: false,
                          ),
                          onChangeEnd: (value) =>
                              player.setEqualizerBandLevel(index, value),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          // 与确认弹窗同语言的浅底药丸（46 高整圆角）：重置=回到平直。
          child: AppPillButton(
            label: '重置',
            foreground: isDark
                ? colorScheme.onSurface
                : const Color(0xFF1A1D24),
            background: isDark
                ? colorScheme.surfaceContainerHighest
                : const Color(0xFFF4F5F7),
            onTap: player.resetEqualizer,
          ),
        ),
      ],
    );
  }
}

class _EqualizerBandSlider extends StatelessWidget {
  const _EqualizerBandSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dbValue = value / 100;
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          SizedBox(
            height: 24,
            child: Text(
              dbValue == 0 ? '0' : dbValue.toStringAsFixed(1),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: enabled
                    ? colorScheme.onSurface
                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 10,
                    disabledThumbRadius: 10,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 18,
                  ),
                  activeTrackColor: colorScheme.primary,
                  inactiveTrackColor: colorScheme.outlineVariant,
                  thumbColor: enabled
                      ? colorScheme.primary
                      : colorScheme.outlineVariant,
                ),
                child: Slider(
                  value: value.toDouble(),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  onChanged: enabled ? (next) => onChanged(next.round()) : null,
                  onChangeEnd: enabled
                      ? (next) => onChangeEnd(next.round())
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: enabled
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EnhancePanel extends StatelessWidget {
  const _EnhancePanel({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bassPercent = (player.bassBoostStrength * 100).round();
    final surroundPercent = (player.surroundStrength * 100).round();
    final surroundEnabled = player.surroundEnabled;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.speaker_rounded, color: colorScheme.primary),
          title: const Text('低音增强'),
          subtitle: Text(player.bassBoostEnabled ? 'Bass $bassPercent%' : '关闭'),
          value: player.bassBoostEnabled,
          onChanged: player.setBassBoostEnabled,
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Text('Bass'),
            Expanded(
              child: Slider(
                value: player.bassBoostStrength,
                onChanged: player.bassBoostEnabled
                    ? (value) =>
                          player.setBassBoostStrength(value, persist: false)
                    : null,
                onChangeEnd: player.bassBoostEnabled
                    ? player.setBassBoostStrength
                    : null,
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '$bassPercent%',
                textAlign: TextAlign.end,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        // 环绕依赖平台滤镜支持（Windows 的 audio-only libmpv 无可用
        // 展宽滤镜），不可用时整块隐藏而非留死控件。
        if (player.isSurroundSupported) ...[
          const SizedBox(height: 26),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              Icons.surround_sound_rounded,
              color: colorScheme.primary,
            ),
            title: const Text('全景环绕'),
            subtitle: Text(surroundEnabled ? '环绕 $surroundPercent%' : '关闭'),
            value: surroundEnabled,
            onChanged: player.setSurroundEnabled,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Text('环绕'),
              Expanded(
                child: Slider(
                  value: player.surroundStrength,
                  onChanged: surroundEnabled
                      ? (value) =>
                            player.setSurroundStrength(value, persist: false)
                      : null,
                  onChangeEnd: surroundEnabled
                      ? player.setSurroundStrength
                      : null,
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '$surroundPercent%',
                  textAlign: TextAlign.end,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _EqualizerCurvePainter extends CustomPainter {
  const _EqualizerCurvePainter({
    required this.colorScheme,
    required this.levels,
    required this.min,
    required this.max,
  });

  final ColorScheme colorScheme;
  final List<int> levels;
  final int min;
  final int max;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: .56)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final zeroY = _levelToY(0, size.height);
    final zeroPaint = Paint()
      ..color = colorScheme.primary.withValues(alpha: .62)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), zeroPaint);

    if (levels.isEmpty) {
      return;
    }

    final linePaint = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var index = 0; index < levels.length; index++) {
      final x = levels.length == 1
          ? size.width / 2
          : size.width * index / (levels.length - 1);
      final y = _levelToY(levels[index], size.height);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  double _levelToY(int level, double height) {
    final span = (max - min).abs();
    if (span == 0) {
      return height / 2;
    }
    final normalized = ((level - min) / span).clamp(0.0, 1.0);
    return height * (1 - normalized);
  }

  @override
  bool shouldRepaint(covariant _EqualizerCurvePainter oldDelegate) {
    return oldDelegate.levels != levels ||
        oldDelegate.min != min ||
        oldDelegate.max != max ||
        oldDelegate.colorScheme != colorScheme;
  }
}

/// 预设卡迷你曲线：10 点折线，中线为 0dB 基准、正增益向上负增益向下。
/// 40 高内若按全局 dB 标定，摆幅只剩几个像素，故按卡内峰值归一化放大
/// 形状差异（全 0 的「平直」即贴中线）；配色沿用主曲线的主题色折线。
class _PresetCurvePainter extends CustomPainter {
  const _PresetCurvePainter({required this.colorScheme, required this.levels});

  final ColorScheme colorScheme;
  final List<int> levels;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final basePaint = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: .56)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), basePaint);

    var peak = 0;
    for (final level in levels) {
      if (level.abs() > peak) {
        peak = level.abs();
      }
    }
    // 峰值下限 1 防除零，全 0 曲线回落到中线。
    final scale = peak < 1 ? 1 : peak;

    final linePaint = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var index = 0; index < levels.length; index++) {
      final x = levels.length == 1
          ? size.width / 2
          : size.width * index / (levels.length - 1);
      final y = midY - (levels[index] / scale) * (midY - 2);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _PresetCurvePainter oldDelegate) {
    return oldDelegate.levels != levels ||
        oldDelegate.colorScheme != colorScheme;
  }
}

class _UnsupportedView extends StatelessWidget {
  const _UnsupportedView({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 42,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 14),
            Text(
              '当前平台暂不支持音效调节',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              'Android 与 Linux（系统 libmpv）播放时可使用均衡器、音效与'
              '低音增强。Windows 将随后续播放内核升级开放。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _frequencyLabel(int hz) {
  if (hz >= 1000) {
    final khz = hz / 1000;
    return khz == khz.roundToDouble()
        ? '${khz.round()}k'
        : '${khz.toStringAsFixed(1)}k';
  }
  return '$hz';
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/ui/widgets/audio_effects_page_test.dart`
Expected: PASS（14 个用例全绿）

Run: `flutter analyze lib/ui/widgets/audio_effects_sheet.dart test/ui/widgets/audio_effects_page_test.dart`
Expected: No issues found!

- [ ] **Step 5: 提交**

```bash
git add lib/ui/widgets/audio_effects_sheet.dart test/ui/widgets/audio_effects_page_test.dart
git commit -m "feat(effects): 音效页卡片化为主，均衡器调线下沉深层页"
```

---

### Task 3: 全量验证（analyze + 全量测试 + Android 编译门）

**Files:**
- 无新改动（如验证暴露问题，修复后追加提交）

**Interfaces:**
- Consumes: Task 1/2 的全部产出。
- Produces: 验证结论（analyze 0 issue、全量测试通过数、Android flavor 编译门通过）。

- [ ] **Step 1: 静态分析**

Run: `flutter analyze`
Expected: `No issues found!`（基线即 0，出现任何 issue 都需处理）

- [ ] **Step 2: 全量测试**

Run: `flutter test`
Expected: 全部通过（基线约 1126 passed + 1 skipped；Task 1 新增 2、Task 2 页面测试 13→14，总数约 1141 passed + 1 skipped，以实际输出为准，记录数字）

- [ ] **Step 3: Android 编译门（flavor）**

Run: `cd android && cmd //c "gradlew.bat :app:compileImpellerDebugKotlin"`
Expected: `BUILD SUCCESSFUL`（注意：**不要**用裸 `compileDebugKotlin`，那是空转门；`build_apk.bat` 不可用）

- [ ] **Step 4: 提交（如有修复）**

如验证中发现并修复了问题：
```bash
git add -A
git commit -m "fix(effects): 卡片化改版验证修复"
```
无问题则跳过本步。

---

## Self-Review 记录

- Spec 覆盖：主界面卡片网格（Task 2 _EffectsCardPanel）✓；关闭卡+自动开 EQ（Task 1 + Task 2 _OffCard）✓；自定义入口卡+深层页（Task 2 _CustomEqCard/_EqualizerEditorPage）✓；车机右栏删除+整幅网格（Task 2）✓；AppBar 去保存（Task 2）✓；控制器两处行为（Task 1）✓；不动清单写入 Global Constraints ✓。
- 占位符扫描：无 TBD/TODO；所有代码步骤含完整代码。
- 类型一致性：`disableAllAudioEffects()` 在 Task 1（真实实现）、Task 2（fake 覆写 + UI 调用）三处签名一致；`AppPillButton(label/foreground/background/onTap)` 与 app_dialog.dart 定义一致；角标 key `effect-selected-badge` 新旧一致。
