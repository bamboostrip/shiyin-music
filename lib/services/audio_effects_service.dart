import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class EqualizerBand {
  const EqualizerBand({required this.centerHz, required this.levelMillibels});

  final int centerHz;
  final int levelMillibels;

  factory EqualizerBand.fromMap(Map<Object?, Object?> map) {
    return EqualizerBand(
      centerHz: (map['centerHz'] as num?)?.round() ?? 0,
      levelMillibels: (map['level'] as num?)?.round() ?? 0,
    );
  }
}

class EqualizerConfig {
  const EqualizerConfig({
    required this.minMillibels,
    required this.maxMillibels,
    required this.bands,
  });

  final int minMillibels;
  final int maxMillibels;
  final List<EqualizerBand> bands;

  factory EqualizerConfig.fallback(List<int> levels) {
    const centers = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    return EqualizerConfig(
      minMillibels: -1200,
      maxMillibels: 1200,
      bands: [
        for (var index = 0; index < centers.length; index++)
          EqualizerBand(
            centerHz: centers[index],
            levelMillibels: index < levels.length ? levels[index] : 0,
          ),
      ],
    );
  }

  factory EqualizerConfig.fromMap(Map<Object?, Object?> map) {
    final range = (map['range'] as List<Object?>?) ?? const [-1200, 1200];
    final rawBands = (map['bands'] as List<Object?>?) ?? const [];
    return EqualizerConfig(
      minMillibels: range.isNotEmpty
          ? ((range[0] as num?)?.round() ?? -1200)
          : -1200,
      maxMillibels: range.length > 1
          ? ((range[1] as num?)?.round() ?? 1200)
          : 1200,
      bands: rawBands
          .whereType<Map<Object?, Object?>>()
          .map(EqualizerBand.fromMap)
          .toList(growable: false),
    );
  }
}

class AudioEffectsService {
  static const _channel = MethodChannel('shiyin_music/audio_effects');

  /// Android 原生通道（audiofx 系效果器）可用性。
  bool get isAndroidEffectsChannel {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  /// 桌面端 mpv 滤镜链可用性。仅 Linux：发行版系统 libmpv 链全量 ffmpeg，
  /// aresample/equalizer/stereotools 齐备。Windows 捆绑的 media-kit
  /// audio-only 构建 ffmpeg 是 `--disable-filters` 白名单编译（仅
  /// overlay/equalizer），lavfi 图配置必需的 aresample 也不在其中——
  /// 任何音效图起播即失败被静默禁用（播放级探针实证，见
  /// scripts/mpv_af_playback_probe.dart），在换用全功能 DLL 前整体关闭。
  bool get isDesktopEffectsPlatform {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  }

  bool get isAudioEffectsSupported =>
      isAndroidEffectsChannel || isDesktopEffectsPlatform;

  bool get isBassBoostSupported => isAudioEffectsSupported;

  /// 环绕：Android 走原生 Virtualizer，Linux 走 mpv stereotools。Windows
  /// 桌面音效整体未开放（见 [isDesktopEffectsPlatform]），自然不含环绕。
  bool get isSurroundSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.linux);

  Future<EqualizerConfig?> equalizerConfig({
    required int? audioSessionId,
  }) async {
    // 桌面走 mpv 滤镜链（fallback 10 段配置），不打 Android 通道。
    if (!isAndroidEffectsChannel) {
      return null;
    }

    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getEqualizerConfig',
        {'audioSessionId': audioSessionId},
      );
      if (result == null) {
        return null;
      }
      return EqualizerConfig.fromMap(result);
    } on PlatformException catch (error) {
      debugPrint('[时音][audio-effects] Equalizer config failed: $error');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> configureEqualizer({
    required int? audioSessionId,
    required bool enabled,
    required List<int> levels,
  }) async {
    // 桌面 EQ 由 mpv biquad 滤镜链实现，不打 Android 通道。
    if (!isAndroidEffectsChannel) {
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>('configureEqualizer', {
        'audioSessionId': audioSessionId,
        'enabled': enabled,
        'levels': levels,
      });
      return result ?? false;
    } on PlatformException catch (error) {
      debugPrint('[时音][audio-effects] Equalizer failed: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> configureBassBoost({
    required int? audioSessionId,
    required bool enabled,
    required double strength,
  }) async {
    // 桌面低音由 EQ 曲线低频搁架折算实现，不打 Android 通道。
    if (!isAndroidEffectsChannel) {
      return false;
    }

    final normalizedStrength = strength.clamp(0.0, 1.0);
    try {
      final result = await _channel.invokeMethod<bool>('configureBassBoost', {
        'audioSessionId': audioSessionId,
        'enabled': enabled,
        'strength': (normalizedStrength * 1000).round(),
      });
      return result ?? false;
    } on PlatformException catch (error) {
      debugPrint('[时音][audio-effects] BassBoost failed: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> configureVirtualizer({
    required int? audioSessionId,
    required bool enabled,
    required double strength,
  }) async {
    // 桌面环绕由 mpv stereotools 实现（仅 Linux），不打 Android 通道。
    if (!isAndroidEffectsChannel) {
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

}
