# 音效预设与全景环绕（issue #1）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 回应 [issue #1](https://github.com/bamboostrip/shiyin-music/issues/1)：扩充均衡器预设、新增酷狗风格的命名音效档案（全景环绕/超重低音等）、Android 加 Virtualizer 环绕、桌面端（Windows/Linux）补齐 mpv 滤镜链音效。

**Architecture:** 沿用现有三层结构——Kotlin `MainActivity` 挂 `android.media.audiofx` 效果器（新增 Virtualizer），Dart `AudioEffectsService` 走 MethodChannel，`PlayerController._PlayerEffects` 管状态与持久化。新增跨平台「音效档案」数据层（EQ 曲线 + 低音 + 环绕的组合预设）。桌面端把 EQ/低音/环绕编译成 mpv `af` 滤镜链（firequalizer + extrastereo），经 vendored `just_audio_media_kit` → `media_kit` 透传，并在 media_kit 内与变速 scaletempo 统一合并写 `af`（互不覆盖）。

**Tech Stack:** Flutter/Dart、Kotlin（android.media.audiofx）、vendored media_kit/just_audio_media_kit（libmpv FFI）、ffmpeg lavfi 滤镜（firequalizer）、mpv 原生滤镜（extrastereo）。

## Global Constraints

- 分支：`feat/audio-effects-profiles`（从 main 切出，已创建）。**不 push、不改版本号、不动 CI/release。**
- 提交信息：遵循 `docs/commit-convention.md`——首行 `type(scope): 中文一句话`，正文 bullet 每条一个改动 + 验证结论单独一条。
- 代码注释：中文，风格与所在文件一致（讲约束和为什么，不复述代码）。提交里不写「本次修改」类对 reviewer 的说明。
- 验证命令（每个任务收尾必须全绿）：`flutter analyze` 与 `flutter test`（在仓库根 `D:\AllCode\flutter\shiyin-music` 下运行）。
- Android Kotlin 改动另需 `cd android && ./gradlew.bat compileDebugKotlin` 编译通过（Git Bash 下运行）。
- 新增持久化 key 一律 `settings.` 前缀，与现有 `lib/controllers/player_controller.dart:93-99` 的常量区放一起。
- 不引入任何新依赖包；不修改 pubspec 的依赖版本（只允许补注释）。
- 禁止嵌入 GPL 代码/文件（JamesDSP、ViPER 预设文件本体）。预设曲线数值为本仓库自写。
- 桌面端 `firequalizer`/`extrastereo` 的运行期听感验证无法自动化，属于计划外人工项，提交信息里按惯例注明「需真机验证」。

## 背景速览（给零上下文的实现者）

- 音效现状：Android 已有 10 段均衡器 + BassBoost + 响度增益（channel `shiyin_music/audio_effects`，`android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt:161-291` 处理器、912-1063 实现）；桌面端完全无 EQ。UI 在 `lib/ui/widgets/audio_effects_sheet.dart`（入口均被 `player.isAudioEffectsSupported` 守卫，目前仅 Android 为真）。
- 播放器：`just_audio` 0.10.6；桌面由 vendored `packages/just_audio_media_kit`（2.1.0+shiyin.7，七处本地补丁，见 `pubspec.yaml:25-41` 注释）适配 vendored `packages/media_kit`（1.2.6+shiyin.1）→ libmpv。
- 关键坑：`JustAudioMediaKit.pitch = true`（`packages/just_audio_media_kit/lib/just_audio_media_kit.dart:41`），桌面变速时 media_kit 会整体覆写 mpv `af` 属性（`packages/media_kit/lib/src/player/native/player/real.dart:834,885`）。桌面音效链必须与它合并写入（Task 5 的核心）。
- 状态字段在 `lib/controllers/player_controller.dart` 的 `_PlayerControllerBase`（622-629 行有 equalizer*/bassBoost* 字段可对照）；行为在 `player_controller.effects.dart`；持久化恢复在 `player_controller.settings.dart`（352-364 恢复、453-454 应用）；sessionId 变化重挂在 `player_controller.dart:340-348`；dispose 释放在 394-409。
- Android 频段重采样：`PlayerEqualizerLogic.levelsForBandCount`（`lib/controllers/player_logic.dart:246-265`），10 段标准曲线 → 设备实际段数自动换算，预设数据统一按 10 段（31/62/125/250/500/1k/2k/4k/8k/16k Hz）写。

---

### Task 1: EQ 预设扩充 + 音效档案数据层（纯 Dart）

**Files:**
- Modify: `lib/controllers/player_controller.dart`（`AudioEffectPreset` 类后加 `AudioEffectProfile`；`equalizerPresets` 列表尾部追加 5 个预设；`PlayerController.equalizerPresets` 同级新增 `audioEffectProfiles`）
- Test: `test/controllers/audio_effect_profiles_test.dart`（新建）

**Interfaces:**
- Produces: `AudioEffectProfile`（字段 name/description/eqLevels/bassBoost/bassStrength/surround/surroundStrength）与 `PlayerController.audioEffectProfiles`（static const List，4 项）。Task 3 的 `applyAudioEffectProfile`、Task 4 的 UI 消费它们。

- [ ] **Step 1: 写失败测试**

新建 `test/controllers/audio_effect_profiles_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';

void main() {
  group('equalizerPresets 数据完整性', () {
    test('每个预设有 10 段且值在 ±1200 毫贝尔内', () {
      for (final preset in PlayerController.equalizerPresets) {
        expect(preset.name, isNotEmpty);
        expect(preset.levels, hasLength(10));
        for (final level in preset.levels) {
          expect(level, inInclusiveRange(-1200, 1200),
              reason: '${preset.name} 的 $level 超出 ±1200');
        }
      }
    });

    test('预设名唯一', () {
      final names = PlayerController.equalizerPresets.map((e) => e.name);
      expect(names.toSet().length, names.length);
    });
  });

  group('audioEffectProfiles 数据完整性', () {
    test('档案 EQ 为 10 段且值在 ±1200 毫贝尔内，强度在 0..1', () {
      for (final profile in PlayerController.audioEffectProfiles) {
        expect(profile.eqLevels, hasLength(10));
        for (final level in profile.eqLevels) {
          expect(level, inInclusiveRange(-1200, 1200),
              reason: '${profile.name} 的 $level 超出 ±1200');
        }
        expect(profile.bassStrength, inInclusiveRange(0.0, 1.0));
        expect(profile.surroundStrength, inInclusiveRange(0.0, 1.0));
        expect(profile.description, isNotEmpty);
      }
    });

    test('档案名唯一且与 EQ 预设名不冲突', () {
      final names = PlayerController.audioEffectProfiles.map((e) => e.name);
      expect(names.toSet().length, names.length);
      final presetNames =
          PlayerController.equalizerPresets.map((e) => e.name).toSet();
      for (final name in names) {
        expect(presetNames, isNot(contains(name)));
      }
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/controllers/audio_effect_profiles_test.dart`
Expected: FAIL——`audioEffectProfiles` 未定义（getter 不存在）。

- [ ] **Step 3: 实现数据层**

在 `lib/controllers/player_controller.dart:84-89` 的 `AudioEffectPreset` 类定义之后追加：

```dart
/// 命名音效档案：EQ 曲线 + 低音增强 + 环绕的组合预设（issue #1，酷狗式
/// 「全景环绕/超重低音」同类效果的开源复刻）。EQ 仍按 10 段标准倍频程
/// 中心（31Hz..16kHz）定义，经 PlayerEqualizerLogic 重采样到设备段数。
class AudioEffectProfile {
  const AudioEffectProfile({
    required this.name,
    required this.description,
    required this.eqLevels,
    this.bassBoost = false,
    this.bassStrength = 0,
    this.surround = false,
    this.surroundStrength = 0,
  });

  final String name;
  final String description;
  final List<int> eqLevels;
  final bool bassBoost;

  /// 低音增强强度（0..1，映射到 Android BassBoost strength 0..1000）。
  final double bassStrength;
  final bool surround;

  /// 环绕强度（0..1，映射到 Android Virtualizer strength / 桌面 extrastereo）。
  final double surroundStrength;
}
```

在 `equalizerPresets` 列表（158-184 行）「电子」之后追加 5 个预设（曲线为社区通用风格曲线的自写数值）：

```dart
    AudioEffectPreset(
      name: '舞曲',
      levels: [500, 400, 150, 0, -150, -300, -200, 100, 350, 450],
    ),
    AudioEffectPreset(
      name: '爵士',
      levels: [300, 200, 100, 0, 100, 100, 0, 100, 250, 300],
    ),
    AudioEffectPreset(
      name: '金属',
      levels: [450, 300, 50, -200, -250, -150, 150, 350, 450, 500],
    ),
    AudioEffectPreset(
      name: '民谣',
      levels: [100, 150, 250, 300, 250, 150, 100, 100, 150, 200],
    ),
    AudioEffectPreset(
      name: '嘻哈',
      levels: [650, 550, 300, 50, -100, -100, 100, 250, 400, 450],
    ),
```

在 `equalizerPresets` 之后新增同级 static const：

```dart
  /// 命名音效档案（均衡器页「预设」弹层顶部展示）。曲线为本仓库自写，
  /// 禁止从酷狗/ViPER 等 GPL 或闭源来源拷贝参数文件。
  static const audioEffectProfiles = [
    AudioEffectProfile(
      name: '全景环绕',
      description: '声场展宽 + 轻低音，空间感增强',
      eqLevels: [300, 200, 100, 0, 0, 0, 100, 200, 300, 250],
      bassBoost: true,
      bassStrength: 0.3,
      surround: true,
      surroundStrength: 0.8,
    ),
    AudioEffectProfile(
      name: '超重低音',
      description: '低频大幅增强，节奏感拉满',
      eqLevels: [850, 750, 550, 250, 0, -100, -150, -200, -150, -100],
      bassBoost: true,
      bassStrength: 0.9,
    ),
    AudioEffectProfile(
      name: '清澈人声',
      description: '中频突出，人声靠前',
      eqLevels: [-200, -100, 50, 250, 450, 550, 400, 150, 0, -100],
    ),
    AudioEffectProfile(
      name: '现场氛围',
      description: '环绕声场，还原现场听感',
      eqLevels: [250, 150, 50, -50, -100, 0, 150, 250, 300, 200],
      bassBoost: true,
      bassStrength: 0.35,
      surround: true,
      surroundStrength: 0.55,
    ),
  ];
```

注意：`equalizerPresets` 用的是 `static const`（非 late final），`AudioEffectProfile` 必须是 const 构造（上面已保证）才能进 const 列表。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/controllers/audio_effect_profiles_test.dart`
Expected: PASS（全部用例）。

- [ ] **Step 5: 全量验证 + 提交**

Run: `flutter analyze` → 无新增告警；`flutter test` → 全绿。

```bash
git add lib/controllers/player_controller.dart test/controllers/audio_effect_profiles_test.dart
git commit -m "feat(effects): 扩充均衡器预设并新增命名音效档案数据层

- 均衡器预设由 7 个扩到 12 个（新增舞曲/爵士/金属/民谣/嘻哈，社区通用风格曲线自写数值）
- 新增 AudioEffectProfile 音效档案：EQ+低音+环绕组合预设，先落数据层供后续应用与 UI 消费
- 新增数据完整性单测（10 段/±1200 毫贝尔/名称唯一），flutter test 全过"
```

---

### Task 2: Android Virtualizer 环绕通道（Kotlin + Service）

**Files:**
- Modify: `android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt`（import 区、效果器字段区、channel handler、`configureBassBoost` 旁新增 Virtualizer 方法、onDestroy）
- Modify: `lib/services/audio_effects_service.dart`（新增 `configureVirtualizer` 与 `isSurroundSupported`）

**Interfaces:**
- Produces: MethodChannel 方法 `configureVirtualizer`，参数 `{audioSessionId: Int?, enabled: Boolean, strength: Int(0..1000)}`，返回 Boolean；Dart 侧 `AudioEffectsService.configureVirtualizer({required int? audioSessionId, required bool enabled, required double strength}) → Future<bool>`（strength 0..1 自动 ×1000）。Task 3 消费。

- [ ] **Step 1: MainActivity 加 Virtualizer**

1. import 区（18-20 行附近，`android.media.audiofx.*` 逐类导入的风格）加：

```kotlin
import android.media.audiofx.Virtualizer
```

2. 效果器字段区（grep `private var bassBoost` 定位，通常在类头部字段区）加：

```kotlin
private var virtualizer: Virtualizer? = null
private var virtualizerSessionId: Int? = null
```

3. channel handler（161-291 行的 when 块）在 `"configureBassBoost"` case 之后加：

```kotlin
"configureVirtualizer" -> {
    val audioSessionId = call.argument<Int>("audioSessionId")
    val enabled = call.argument<Boolean>("enabled") ?: false
    val strength = call.argument<Int>("strength") ?: 0

    runCatching {
        configureVirtualizer(audioSessionId, enabled, strength)
    }.onSuccess { supported ->
        result.success(supported)
    }.onFailure { error ->
        releaseVirtualizer()
        result.error("virtualizer_failed", error.message, null)
    }
}
```

4. 在 `releaseBassBoost()`（1008-1015 行）之后新增，完全仿照 BassBoost 范式：

```kotlin
/**
 * 配置环绕（Virtualizer）。API 31 起官方标记 deprecated 且推荐 Spatializer，
 * 但 Spatializer 是系统级查询/控制接口、不能按音频会话插入效果，对本应用
 * 场景不可用；Virtualizer 在 minSdk 26 全范围仍可工作。部分设备实现为空
 * 操作，由 strengthSupported 表达，效果差异属设备行为。
 */
@Suppress("DEPRECATION")
private fun configureVirtualizer(
    audioSessionId: Int?,
    enabled: Boolean,
    strength: Int
): Boolean {
    if (!enabled) {
        releaseVirtualizer()
        return true
    }
    if (audioSessionId == null || audioSessionId <= 0) {
        return false
    }

    val effect = if (virtualizerSessionId == audioSessionId && virtualizer != null) {
        virtualizer!!
    } else {
        releaseVirtualizer()
        Virtualizer(0, audioSessionId).also {
            virtualizer = it
            virtualizerSessionId = audioSessionId
        }
    }

    val clampedStrength = strength.coerceIn(0, 1000).toShort()
    if (effect.strengthSupported) {
        effect.setStrength(clampedStrength)
    } else {
        effect.setStrength(if (clampedStrength > 0) 1000 else 0)
    }
    effect.enabled = true
    return true
}

@Suppress("DEPRECATION")
private fun releaseVirtualizer() {
    virtualizer?.runCatching {
        enabled = false
        release()
    }
    virtualizer = null
    virtualizerSessionId = null
}
```

5. `onDestroy()`（grep `releaseBassBoost()` 在 onDestroy 内的调用处，1172-1175 行附近）在 `releaseBassBoost()` 旁加一行 `releaseVirtualizer()`。

- [ ] **Step 2: Dart Service 加透传方法**

`lib/services/audio_effects_service.dart`，在 `isBassBoostSupported`（69 行）后加：

```dart
  bool get isSurroundSupported => isAudioEffectsSupported;
```

在 `configureBassBoost` 方法（119-142 行）后加（同范式）：

```dart
  Future<bool> configureVirtualizer({
    required int? audioSessionId,
    required bool enabled,
    required double strength,
  }) async {
    if (!isSurroundSupported) {
      return false;
    }

    final normalizedStrength = strength.clamp(0.0, 1.0);
    try {
      final result = await _channel.invokeMethod<bool>('configureVirtualizer', {
        'audioSessionId': audioSessionId,
        'enabled': enabled,
        'strength': (normalizedStrength * 1000).round(),
      });
      return result ?? false;
    } on PlatformException catch (error) {
      debugPrint('[时音][audio-effects] Virtualizer failed: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }
```

- [ ] **Step 3: 编译与静态检查**

Run: `cd android && ./gradlew.bat compileDebugKotlin`（Git Bash；回到根目录再跑下一步）
Expected: BUILD SUCCESSFUL。

Run: `flutter analyze`
Expected: 无新增告警（本任务无 Dart 测试可写——channel 路径无单测覆盖，行为靠 Task 6 后真机验证）。

- [ ] **Step 4: 提交**

```bash
git add android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt lib/services/audio_effects_service.dart
git commit -m "feat(effects): Android 端接入 Virtualizer 环绕效果器

- audio_effects 通道新增 configureVirtualizer，仿 BassBoost 范式（sessionId 复用/释放重建/onDestroy 释放）
- Virtualizer 虽在 API 31 标记 deprecated，但 Spatializer 为系统级接口不可按会话挂载，保留旧效果器覆盖 minSdk 26 全范围
- 部分车机实现为空操作，由 strengthSupported 降级为开关式强度
- gradlew compileDebugKotlin 与 flutter analyze 通过，环绕听感需真机验证"
```

---

### Task 3: 控制器环绕状态 + 音效档案应用

**Files:**
- Modify: `lib/controllers/player_controller.dart`（持久化 key 常量、`_PlayerControllerBase` 字段与抽象契约、sessionId 监听 340-348、dispose 394-409）
- Modify: `lib/controllers/player_controller.effects.dart`（环绕 setter/apply、`applyAudioEffectProfile`、`audioEffectsLabel`）
- Modify: `lib/controllers/player_controller.settings.dart`（恢复 352-364 区、应用 453-454 区）
- Test: `test/controllers/audio_effect_profile_apply_test.dart`（新建）

**Interfaces:**
- Consumes: Task 1 的 `AudioEffectProfile`/`PlayerController.audioEffectProfiles`；Task 2 的 `AudioEffectsService.configureVirtualizer`。
- Produces: 公开 API `surroundEnabled`/`surroundStrength` 字段、`setSurroundEnabled(bool)`、`setSurroundStrength(double, {bool persist})`、`applyAudioEffectProfile(AudioEffectProfile)`、`isSurroundSupported`。Task 4 UI 消费。
- 注意：本任务先保持 `isAudioEffectsSupported` 仍为 Android-only（桌面门在 Task 5 放开），`_applySurround` 的桌面分支本任务就位但桌面下 `isSurroundSupported=false` 走不到（Task 5 接管）。

- [ ] **Step 1: 写失败测试**

先读 `test/controllers/loudness_neutral_reset_test.dart` 与 `test/controllers/player_logic_test.dart`，复用其中构造 PlayerController 的 fake api/audioHandler 模式（文件顶部 import 与 fake 类照搬，勿自造）。新建 `test/controllers/audio_effect_profile_apply_test.dart`：

```dart
// 复制 loudness_neutral_reset_test.dart 的 imports 与 fake 搭建（_FakeApi/
// _FakeAudioHandler 等，以其真实命名为准），然后：
void main() {
  test('applyAudioEffectProfile 一次性落 EQ/低音/环绕并置自定义前预设名', () async {
    final controller = PlayerController(fakeApi, fakeHandler);
    addTearDown(controller.dispose);

    final profile = PlayerController.audioEffectProfiles
        .firstWhere((p) => p.name == '全景环绕');
    await controller.applyAudioEffectProfile(profile);

    expect(controller.equalizerEnabled, isTrue);
    expect(controller.equalizerPresetName, '全景环绕');
    // 10 段标准曲线直接命中 fallback 配置的 10 段。
    expect(controller.equalizerLevels, profile.eqLevels);
    expect(controller.bassBoostEnabled, isTrue);
    expect(controller.bassBoostStrength, closeTo(0.3, 0.001));
    expect(controller.surroundEnabled, isTrue);
    expect(controller.surroundStrength, closeTo(0.8, 0.001));

    // 清理持久化，避免污染其它用例（若 fake 测试已有 SharedPreferences
    // mock 初始化则照该文件的方式处理）。
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });
}
```

（fake 构造细节以被参考文件的实际形态为准；若 PlayerController 构造有额外必填依赖，按 loudness 测试的方式一并注入。）

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/controllers/audio_effect_profile_apply_test.dart`
Expected: FAIL——`applyAudioEffectProfile`/`surroundEnabled` 未定义。

- [ ] **Step 3: 实现状态与逻辑**

1. `lib/controllers/player_controller.dart` 99 行（`_bassBoostStrengthSettingKey`）后加：

```dart
const _surroundEnabledSettingKey = 'settings.surround_enabled';
const _surroundStrengthSettingKey = 'settings.surround_strength';
```

2. `_PlayerControllerBase` 字段区 628-629 行（bassBoost 字段后）加：

```dart
  bool surroundEnabled = false;
  double surroundStrength = 0.6;
```

3. 同文件 sessionId 监听（340-348）`unawaited(_applyBassBoost());` 后加 `unawaited(_applySurround());`。

4. dispose（402-409 bassBoost 的 unawaited 块后）加：

```dart
    unawaited(
      _audioEffects.configureVirtualizer(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        strength: surroundStrength,
      ),
    );
```

5. `player_controller.effects.dart`：mixin 头部 getter 区（5-8 行）加：

```dart
  bool get isSurroundSupported => _audioEffects.isSurroundSupported;
```

`audioEffectsLabel`（9-20 行）在 bassBoost 分支后、return '关闭' 前加：

```dart
    if (surroundEnabled) {
      return '环绕 ${(surroundStrength * 100).round()}%';
    }
```

`_applyBassBoost`（154-166）之后新增三个成员：

```dart
  Future<void> setSurroundEnabled(bool enabled) async {
    if (surroundEnabled == enabled) {
      return;
    }
    surroundEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_surroundEnabledSettingKey, enabled);
    await _applySurround();
    notifyListeners();
  }

  Future<void> setSurroundStrength(
    double strength, {
    bool persist = true,
  }) async {
    final nextStrength = strength.clamp(0.0, 1.0);
    if ((surroundStrength - nextStrength).abs() < 0.001) {
      return;
    }
    surroundStrength = nextStrength;
    if (surroundEnabled) {
      unawaited(_applySurround());
    }
    notifyListeners();

    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_surroundStrengthSettingKey, nextStrength);
    }
  }

  /// 应用命名音效档案：EQ/低音/环绕一次性落到位（issue #1 酷狗式音效的
  /// 本仓实现）。应用后各子项仍可单独微调，微调 EQ 会走既有「自定义」路径。
  Future<void> applyAudioEffectProfile(AudioEffectProfile profile) async {
    equalizerEnabled = true;
    equalizerPresetName = profile.name;
    equalizerLevels = PlayerEqualizerLogic.levelsForBandCount(
      profile.eqLevels,
      equalizerLevels.length,
    );
    bassBoostEnabled = profile.bassBoost;
    bassBoostStrength = profile.bassStrength;
    surroundEnabled = profile.surround;
    surroundStrength = profile.surroundStrength;
    await _persistEqualizer();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bassBoostEnabledSettingKey, bassBoostEnabled);
    await prefs.setDouble(_bassBoostStrengthSettingKey, bassBoostStrength);
    await prefs.setBool(_surroundEnabledSettingKey, surroundEnabled);
    await prefs.setDouble(_surroundStrengthSettingKey, surroundStrength);
    await _applyEqualizer();
    await _applyBassBoost();
    await _applySurround();
    notifyListeners();
  }
```

`_applyBassBoost` 同范式新增 `_applySurround`（若基类声明了抽象契约则带 @override；本任务同时在基类抽象契约区加声明——grep `Future<void> _applyBassBoost` 在基类的抽象声明处，旁路加 `Future<void> _applySurround();`）：

```dart
  @override
  Future<void> _applySurround() async {
    if (!isSurroundSupported) {
      return;
    }

    await _audioEffects.configureVirtualizer(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: surroundEnabled,
      strength: surroundStrength,
    );
  }
```

6. `player_controller.settings.dart`：363-364（bassBoost 恢复）后加：

```dart
    surroundEnabled =
        prefs.getBool(_surroundEnabledSettingKey) ?? surroundEnabled;
    surroundStrength =
        prefs.getDouble(_surroundStrengthSettingKey) ?? surroundStrength;
```

453-454（`unawaited(_applyBassBoost());`）后加：

```dart
    unawaited(_applySurround());
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/controllers/audio_effect_profile_apply_test.dart`
Expected: PASS。

- [ ] **Step 5: 全量验证 + 提交**

Run: `flutter analyze`、`flutter test` → 全绿。

```bash
git add lib/controllers/player_controller.dart lib/controllers/player_controller.effects.dart lib/controllers/player_controller.settings.dart test/controllers/audio_effect_profile_apply_test.dart
git commit -m "feat(effects): 控制器接入环绕状态与音效档案应用

- PlayerController 新增环绕开关/强度（含持久化、sessionId 变化重挂、dispose 释放），与低音增强同范式
- applyAudioEffectProfile 把档案的 EQ/低音/环绕一次性应用并各自落盘，微调仍走原「自定义」路径
- audioEffectsLabel 补环绕文案；新增档案应用单测，flutter test 全过"
```

---

### Task 4: 音效页 UI——环绕滑条 + 预设弹层音效档案区

**Files:**
- Modify: `lib/ui/widgets/audio_effects_sheet.dart`（`_EnhancePanel` 加环绕块；`_showPresetPicker` 重构为「音效 + 均衡器预设」两段式）

**Interfaces:**
- Consumes: Task 3 的 `surroundEnabled`/`setSurroundEnabled`/`setSurroundStrength`；Task 1 的 `PlayerController.audioEffectProfiles` + Task 3 的 `applyAudioEffectProfile`。

- [ ] **Step 1: `_EnhancePanel` 加环绕块**

在低音 Slider 的 Row（423-450 行）之后追加（镜像低音块的交互：禁用时滑条置灰、拖动不落盘松手才落盘）：

```dart
        const SizedBox(height: 26),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(
            Icons.surround_sound_rounded,
            color: colorScheme.primary,
          ),
          title: const Text('全景环绕'),
          subtitle: Text(
            surroundEnabled ? '环绕 $surroundPercent%' : '关闭',
          ),
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
                    ? (value) => player.setSurroundStrength(
                          value,
                          persist: false,
                        )
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
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
```

并在 build 顶部 `bassPercent`（410 行）旁加：

```dart
    final surroundPercent = (player.surroundStrength * 100).round();
```

- [ ] **Step 2: `_showPresetPicker` 两段式**

把 276-312 行的 `showModalBottomSheet<AudioEffectPreset>` 改为返回 `Object`，ListView.separated 换成显式 children 的 `ListView(shrinkWrap: true, ...)`：

```dart
  Future<void> _showPresetPicker(BuildContext context) async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final sheetTheme = Theme.of(sheetContext);
        return Material(
          color: sheetTheme.colorScheme.surface,
          child: SafeArea(
            top: false,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    '音效',
                    style: sheetTheme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                for (final profile in PlayerController.audioEffectProfiles)
                  ListTile(
                    leading: const Icon(Icons.auto_awesome_rounded),
                    title: Text(profile.name),
                    subtitle: Text(profile.description),
                    trailing: player.equalizerPresetName == profile.name
                        ? Icon(
                            Icons.check_rounded,
                            color: sheetTheme.colorScheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(profile),
                  ),
                const Divider(height: 24),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    '均衡器预设',
                    style: sheetTheme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                for (final preset in PlayerController.equalizerPresets)
                  ListTile(
                    leading: const Icon(Icons.tune_rounded),
                    title: Text(preset.name),
                    dense: true,
                    trailing: player.equalizerPresetName == preset.name
                        ? Icon(
                            Icons.check_rounded,
                            color: sheetTheme.colorScheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(preset),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (result is AudioEffectProfile) {
      await player.applyAudioEffectProfile(result);
    } else if (result is AudioEffectPreset) {
      await player.applyEqualizerPreset(result);
    }
  }
```

- [ ] **Step 3: 验证 + 提交**

Run: `flutter analyze`、`flutter test` → 全绿（UI 无既有单测则 analyze 为准）。

```bash
git add lib/ui/widgets/audio_effects_sheet.dart
git commit -m "feat(effects): 音效页新增全景环绕滑条与音效档案选择

- 增强面板补环绕开关+强度滑条，交互与低音增强一致（拖动不落盘松手落盘）
- 预设弹层改为两段式：顶部音效档案（全景环绕/超重低音/清澈人声/现场氛围）+ 下方均衡器预设
- flutter analyze/test 全过，视觉与车机表现需真机点验"
```

---

### Task 5: 桌面端 mpv 滤镜链（EQ + 低音折叠 + 环绕）与平台门放开

**Files:**
- Modify: `packages/media_kit/lib/src/player/native/player/real.dart`（af 统一链管理 + `setExtraAudioFilters` 公开 API）
- Modify: `packages/just_audio_media_kit/lib/mediakit_player.dart`（`setAudioEffectFilters` 透传）
- Modify: `pubspec.yaml`（25-41 行补丁注释块补第 8 条，media_kit 注释同理若有对应块）
- Create: `lib/services/desktop_audio_filters.dart`（纯函数滤镜链组装）
- Modify: `lib/services/audio_effects_service.dart`（平台门拆分：android 通道门 / desktop 支持门）
- Modify: `lib/controllers/player_controller.effects.dart`（`_applyDesktopAudioFilters` + 三个 apply 的桌面路由 + dispose 清链）
- Test: `test/services/desktop_audio_filters_test.dart`（新建）

**Interfaces:**
- Produces: `NativePlayer.setExtraAudioFilters(List<String>)`（vendored media_kit 内）、`MediaKitPlayer.setAudioEffectFilters(List<String>)`（vendored just_audio_media_kit 内）、`DesktopAudioFilters.build(...)` 纯函数、`AudioEffectsService.isAndroidEffectsChannel`/`isDesktopEffectsPlatform` 门。
- 关键约束：变速（setRate/setPitch，`real.dart:822-898`）与音效链必须合并写同一个 `af` 属性，任何一侧变化都重写整链。

- [ ] **Step 1: 写失败测试**

新建 `test/services/desktop_audio_filters_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/desktop_audio_filters.dart';

void main() {
  const centers = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

  test('全部关闭时产出空链', () {
    expect(
      DesktopAudioFilters.build(
        equalizerEnabled: false,
        centerHz: centers,
        levelsMillibels: List.filled(10, 0),
      ),
      isEmpty,
    );
  });

  test('EQ 开启产出 firequalizer，毫贝尔转 dB 保留一位小数', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: [500, 0, 0, 0, 0, 0, 0, 0, 0, 250],
    );
    expect(filters, hasLength(1));
    expect(
      filters.single,
      "lavfi=[firequalizer=gain_entry='entry(31,5.0);entry(62,0.0);"
      "entry(125,0.0);entry(250,0.0);entry(500,0.0);entry(1000,0.0);"
      "entry(2000,0.0);entry(4000,0.0);entry(8000,0.0);entry(16000,2.5)']",
    );
  });

  test('低音增强在 EQ 关闭时仍产出搁架抬升曲线', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: false,
      centerHz: centers,
      levelsMillibels: List.filled(10, 0),
      bassEnabled: true,
      bassStrength: 0.5,
    );
    expect(filters, hasLength(1));
    // 满强度 +12dB：0.5 → 31Hz +6.0 / 62Hz +4.2 / 125Hz +2.1，其余 0.0。
    expect(filters.single, contains('entry(31,6.0)'));
    expect(filters.single, contains('entry(62,4.2)'));
    expect(filters.single, contains('entry(125,2.1)'));
    expect(filters.single, contains('entry(250,0.0)'));
  });

  test('EQ 与低音叠加时低频点为两者之和', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: [300, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      bassEnabled: true,
      bassStrength: 1.0,
    );
    // 31Hz = 3.0(EQ) + 12.0(bass 满强度) = 15.0。
    expect(filters.single, contains('entry(31,15.0)'));
  });

  test('环绕映射 extrastereo 系数并带削波保护', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: false,
      centerHz: centers,
      levelsMillibels: List.filled(10, 0),
      surroundEnabled: true,
      surroundStrength: 0.8,
    );
    // m = 1 + 0.55×0.8 = 1.440。
    expect(filters.single, 'extrastereo=m=1.440:c=1');
  });

  test('EQ 与环绕同开时链序为先 EQ 后环绕', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: List.filled(10, 100),
      surroundEnabled: true,
      surroundStrength: 0.5,
    );
    expect(filters, hasLength(2));
    expect(filters.first, startsWith('lavfi=[firequalizer'));
    expect(filters.last, 'extrastereo=m=1.275:c=1');
  });

  test('频点与电平数不一致时按短侧截断不抛', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: [100, 200],
    );
    expect(filters.single, contains('entry(62,2.0)'));
    expect(filters.single, isNot(contains('entry(125,')));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/services/desktop_audio_filters_test.dart`
Expected: FAIL——`desktop_audio_filters.dart` 不存在。

- [ ] **Step 3: 实现 `DesktopAudioFilters`**

新建 `lib/services/desktop_audio_filters.dart`：

```dart
import 'dart:math' as math;

/// 桌面端（mpv）音频滤镜链组装：把均衡器/低音/环绕状态编译成 mpv `af`
/// 属性的滤镜片段列表。纯函数，供单测与 PlayerController 桌面路径复用。
///
/// - 均衡器：ffmpeg `firequalizer`（FFT FIR，任意频点增益），毫贝尔值
///   除以 100 转 dB 后逐点写 gain_entry；频率点间线性插值由滤镜完成。
/// - 低音增强：Android 有独立 BassBoost 效果器，mpv 无对应物，折算成
///   31/62/125Hz 三点搁架抬升（满强度 +12dB 梯形）叠进 EQ 曲线。
/// - 环绕：mpv 原生 `extrastereo`（立体声差异放大，m>1 展宽），强度
///   线性映射 m = 1 + 0.55×strength，c=1 开启削波保护防大音量爆音。
abstract final class DesktopAudioFilters {
  /// firequalizer 单点增益钳制（±24dB），防叠加后的极端值。
  static const _maxDb = 24.0;

  static List<String> build({
    required bool equalizerEnabled,
    required List<int> centerHz,
    required List<int> levelsMillibels,
    bool bassEnabled = false,
    double bassStrength = 0,
    bool surroundEnabled = false,
    double surroundStrength = 0,
  }) {
    final filters = <String>[];
    final hasEq =
        equalizerEnabled && centerHz.isNotEmpty && levelsMillibels.isNotEmpty;
    final bassDb = bassEnabled ? bassStrength.clamp(0.0, 1.0) * 12.0 : 0.0;
    if (hasEq || bassDb > 0) {
      filters.add(
        _firequalizer(centerHz, levelsMillibels, applyEq: hasEq, bassDb: bassDb),
      );
    }
    if (surroundEnabled && surroundStrength > 0) {
      filters.add(
        'extrastereo=m='
        '${(1 + 0.55 * surroundStrength.clamp(0.0, 1.0)).toStringAsFixed(3)}'
        ':c=1',
      );
    }
    return filters;
  }

  static String _firequalizer(
    List<int> centerHz,
    List<int> levels, {
    required bool applyEq,
    required double bassDb,
  }) {
    final count = math.min(centerHz.length, levels.length);
    final entries = <String>[
      for (var index = 0; index < count; index++)
        'entry(${centerHz[index]},'
        '${_bandDb(centerHz[index], applyEq ? levels[index] / 100.0 : 0, bassDb).toStringAsFixed(1)})',
    ];
    return "lavfi=[firequalizer=gain_entry='${entries.join(';')}']";
  }

  static double _bandDb(int hz, double eqDb, double bassDb) {
    final db = eqDb + _bassShelfDb(hz, bassDb);
    return db.clamp(-_maxDb, _maxDb);
  }

  static double _bassShelfDb(int hz, double bassDb) {
    if (bassDb <= 0) {
      return 0;
    }
    if (hz <= 31) {
      return bassDb;
    }
    if (hz <= 62) {
      return bassDb * 0.7;
    }
    if (hz <= 125) {
      return bassDb * 0.35;
    }
    return 0;
  }
}
```

- [ ] **Step 4: vendored media_kit 加 af 统一链管理**

`packages/media_kit/lib/src/player/native/player/real.dart`：

1. 类字段区（grep `late final`/`final` 字段集中处，或直接放 `_setPropertyString` 使用区上方）加：

```dart
  // LOCAL PATCH (shiyin): 桌面音效滤镜链（EQ/环绕），与变速的 scaletempo
  // 合并写入同一个 af 属性——此前变速直接整体覆写 af，会把音效链冲掉。
  List<String> _extraAudioFilters = <String>[];
```

2. 在 `setRate`（822-845）与 `setPitch`（854-898）的两个 `await _setPropertyString('af', 'scaletempo:scale=...')`（834-835、885-886 行）都改为 `await _updateAudioFilters();`。

3. 新增两个方法（放 setPitch 之后）：

```dart
  /// LOCAL PATCH (shiyin): 设置桌面音效滤镜链（EQ/环绕），与变速的
  /// scaletempo 在同一个 af 属性内合并，互不覆盖。
  Future<void> setExtraAudioFilters(List<String> filters) async {
    if (disposed) {
      return;
    }
    _extraAudioFilters = List<String>.of(filters);
    await _updateAudioFilters();
  }

  /// LOCAL PATCH (shiyin): af 滤镜链统一组装。变速（pitch 模式下用
  /// scaletempo 补偿速度）在前、音效链在后；链为空时写空串清空滤镜。
  Future<void> _updateAudioFilters() async {
    final chain = <String>[
      if (configuration.pitch)
        'scaletempo:scale=${(state.rate / state.pitch).toStringAsFixed(8)}',
      ..._extraAudioFilters,
    ];
    await _setPropertyString('af', chain.join(','));
  }
```

注意：原 834/885 行的 scaletempo 表达式必须原样保留进 `_updateAudioFilters`（含 `toStringAsFixed(8)` 与 rate/pitch 相除的补偿语义）；`setRate` else 分支（configuration.pitch=false 时走 `speed` 属性）不动。

- [ ] **Step 5: vendored just_audio_media_kit 透传**

先看 `packages/just_audio_media_kit/lib/src/set_property_io.dart` 里对 `NativePlayer` 的导入与转型写法并照搬。然后在 `mediakit_player.dart` 的 `setPitch`（368-370 行）之后加：

```dart
  /// LOCAL PATCH (shiyin): 桌面音效 —— 把 EQ/环绕滤镜链透传给 media_kit
  /// NativePlayer（与变速的 scaletempo 在 af 属性里合并，见 real.dart 的
  /// _updateAudioFilters）。非 NativePlayer 平台静默 no-op。
  Future<void> setAudioEffectFilters(List<String> filters) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setExtraAudioFilters(filters);
    }
  }
```

（若 set_property_io.dart 显示 `NativePlayer` 未被 `package:media_kit/media_kit.dart` 顶层导出，按该文件的实际 import 路径引入。）

- [ ] **Step 6: pubspec 补丁注释**

`pubspec.yaml` 25-41 行 just_audio_media_kit 的「含七处补丁」注释块，追加第 8 条并同步改「七处」为「八处」：

```yaml
  # 8) 新增 setAudioEffectFilters 透传（桌面音效 EQ/环绕滤镜链，与
  #    变速 scaletempo 在 media_kit 侧合并写 af，见 media_kit 补丁）；
```

同文件 media_kir/media_kit 依赖注释块（grep `media_kit:` 定位）若有本地补丁清单，补记一条「real.dart: af 属性统一组装（scaletempo + 音效链），新增 setExtraAudioFilters 公开 API」。

- [ ] **Step 7: 平台门拆分 + 控制器桌面路由**

1. `lib/services/audio_effects_service.dart` 65-69 行改为：

```dart
  /// Android 原生通道（audiofx 系效果器）可用性。
  bool get isAndroidEffectsChannel {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  /// 桌面端 mpv 滤镜链可用性（Windows/Linux）。
  bool get isDesktopEffectsPlatform {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
  }

  bool get isAudioEffectsSupported =>
      isAndroidEffectsChannel || isDesktopEffectsPlatform;

  bool get isBassBoostSupported => isAudioEffectsSupported;

  bool get isSurroundSupported => isAudioEffectsSupported;
```

类内所有 `_channel.invokeMethod` 方法（equalizerConfig/configureEqualizer/configureBassBoost/configureVirtualizer）的守卫从 `isAudioEffectsSupported`/`isBassBoostSupported`/`isSurroundSupported` 改为 `isAndroidEffectsChannel`（桌面不再空打通道）。

2. `lib/controllers/player_controller.dart` 头部 import 区加：

```dart
import 'package:just_audio_media_kit/just_audio_media_kit.dart' show MediaKitPlayer;
```

（若 analyzer 报 unused（桌面导入在 Android 单测下未用）则去掉 `show` 直接整包导入；以 analyzer 为准。）

dispose（394-409 区，Task 3 加的 virtualizer 块之后）加桌面清链：

```dart
    // 桌面端清空 mpv 滤镜链（Android 走上面的通道 disable）。
    final desktopPlatform = audioPlayer.platform;
    if (desktopPlatform is MediaKitPlayer) {
      unawaited(desktopPlatform.setAudioEffectFilters(const []));
    }
```

3. `lib/controllers/player_controller.effects.dart`：

   - 头部加 `import '../services/desktop_audio_filters.dart';`（相对路径风格与文件内其它 import 一致）。
   - `_applyEqualizer`（141-152）、`_applyBassBoost`（154-166）、`_applySurround`（Task 3 新增）统一改为三段式：

```dart
  @override
  Future<void> _applyEqualizer() async {
    if (_audioEffects.isAndroidEffectsChannel) {
      await _audioEffects.configureEqualizer(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: equalizerEnabled,
        levels: equalizerLevels,
      );
      return;
    }
    await _applyDesktopAudioFilters();
  }
```

`_applyBassBoost`/`_applySurround` 同构（各自保留原 Android 参数，末尾 `await _applyDesktopAudioFilters();`）。

   - 新增：

```dart
  /// 桌面端：把 EQ/低音/环绕统一编译成 mpv af 滤镜链（just_audio_media_kit
  /// → media_kit → mpv）。任一音效状态变化后重算整链，与变速合并写入。
  Future<void> _applyDesktopAudioFilters() async {
    if (!_audioEffects.isDesktopEffectsPlatform) {
      return;
    }
    final platform = audioPlayer.platform;
    if (platform is! MediaKitPlayer) {
      return;
    }
    try {
      await platform.setAudioEffectFilters(
        DesktopAudioFilters.build(
          equalizerEnabled: equalizerEnabled,
          centerHz: [
            for (final band in equalizerConfig.bands) band.centerHz,
          ],
          levelsMillibels: equalizerLevels,
          bassEnabled: bassBoostEnabled,
          bassStrength: bassBoostStrength,
          surroundEnabled: surroundEnabled,
          surroundStrength: surroundStrength,
        ),
      );
    } catch (error) {
      debugPrint('[时音][audio-effects] Desktop filters failed: $error');
    }
  }
```

   - `_refreshEqualizerConfig`（118-139）守卫从 `isAudioEffectsSupported` 改为 `_audioEffects.isAndroidEffectsChannel`（桌面保持 fallback 10 段配置，不去打通道）。

4. `audio_effects_sheet.dart` 的 `_UnsupportedView` 文案（553 行）改为：

```dart
              'Android、Windows 与 Linux 播放时可使用均衡器、音效与低音增强。',
```

（此后 unsupported 只剩 Web/未支持平台，设置页/播放页入口守卫 `isAudioEffectsSupported` 自动对桌面放行，无需逐个改。）

- [ ] **Step 8: 跑测试 + 全量验证**

Run: `flutter test test/services/desktop_audio_filters_test.dart` → PASS。
Run: `flutter analyze`、`flutter test` → 全绿。

- [ ] **Step 9: 提交**

```bash
git add packages/media_kit/lib/src/player/native/player/real.dart packages/just_audio_media_kit/lib/mediakit_player.dart pubspec.yaml lib/services/desktop_audio_filters.dart lib/services/audio_effects_service.dart lib/controllers/player_controller.dart lib/controllers/player_controller.effects.dart lib/ui/widgets/audio_effects_sheet.dart test/services/desktop_audio_filters_test.dart
git commit -m "feat(effects): 桌面端经 mpv 滤镜链补齐均衡器与环绕

- media_kit 新增 af 统一链管理：变速 scaletempo 与音效滤镜合并写同一 af 属性，消除变速冲掉音效链的互踩
- 桌面 EQ 走 ffmpeg firequalizer（毫贝尔逐点转 dB），低音增强折算 31/62/125Hz 搁架叠加，环绕走 extrastereo（m=1+0.55×强度，c=1 削波保护）
- 音效平台门拆分为 Android 通道门与桌面门，设置页/播放页音效入口自动对 Windows/Linux 放行
- DesktopAudioFilters 纯函数组装 + 7 条单测，flutter analyze/test 全过；firequalizer 实际听感需 Windows 真机验证"
```

---

### Task 6: 全量验证与收尾

**Files:**
- 无新增改动（除非前序任务有遗漏收尾）。

- [ ] **Step 1: 全量静态检查与测试**

Run: `flutter analyze` → 无新增告警。
Run: `flutter test` → 全绿。
Run: `cd android && ./gradlew.bat compileDebugKotlin` → BUILD SUCCESSFUL（确认 Task 2/3 期间未破坏）。

- [ ] **Step 2: 检查遗留**

- `git log --oneline main..HEAD` 核对应有 5 个提交（Task 1-5 各一）。
- `git diff main --stat` 核对无计划外文件（尤其未动 CI/release/版本号）。

- [ ] **Step 3: 人工验证清单（写进最终汇报，不自动执行）**

1. Android 真机：音效页 → 档案「全景环绕」→ 听感是否有展宽；车机蓝牙下确认 Virtualizer 非 no-op。
2. Windows：设置页出现「音效」入口 → EQ 拖动 → debug 控制台无 MPV filter 报错；变速 1.5x 后 EQ 仍在（不被冲掉）。
3. Linux：同 Windows（系统 libmpv2 需带 lavfi）。
4. 重启 App：环绕开关/强度、档案选择恢复正确。

---

## Self-Review 记录

- Spec 覆盖：issue #1 的「预设」→ Task 1（EQ 预设）+ Task 3/4（档案即预设组合）；「全景环绕」→ Task 2（Android Virtualizer）+ Task 5（桌面 extrastereo）；桌面补齐 → Task 5。无遗漏。
- 占位符扫描：Task 3 Step 1 的 fake 搭建引用既有测试文件形态（允许——是仓库内真实存在的模式，非「TBD」）；其余步骤均有完整代码。
- 类型一致性：`AudioEffectProfile`（Task 1 定义 ↔ Task 3/4 消费）、`setExtraAudioFilters`（Task 5 Step 4 定义 ↔ Step 5 消费）、`setAudioEffectFilters`（Step 5 定义 ↔ Step 7 消费）、`isAndroidEffectsChannel`/`isDesktopEffectsPlatform`（Step 7 定义 ↔ 消费）已核对一致。
