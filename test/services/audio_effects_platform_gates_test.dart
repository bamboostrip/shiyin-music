import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/audio_effects_service.dart';

/// Task 5 平台门拆分的四向取值：android 通道门 vs 桌面 mpv 门 vs 聚合门。
/// 测试宿主是 Windows——不显式置 override 时 defaultTargetPlatform 落宿主
/// 值，故每个用例逐平台显式设定、tearDown 统一复位（与
/// audio_effect_profile_apply_test 同款做法）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('isAndroidEffectsChannel 仅 Android 为真', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        AudioEffectsService().isAndroidEffectsChannel,
        platform == TargetPlatform.android,
        reason: '$platform 应只在 android 为真',
      );
    }
  });

  test('isDesktopEffectsPlatform 仅 Windows/Linux 为真', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        AudioEffectsService().isDesktopEffectsPlatform,
        platform == TargetPlatform.windows || platform == TargetPlatform.linux,
        reason: '$platform 应只在 windows/linux 为真',
      );
    }
  });

  test('isAudioEffectsSupported 为两门之或（含低音/环绕跟随聚合门）', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final expected = platform == TargetPlatform.android ||
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.linux;
      final service = AudioEffectsService();
      expect(service.isAudioEffectsSupported, expected, reason: '$platform');
      // 低音/环绕沿用聚合门：桌面经 mpv 滤镜链同样可用。
      expect(service.isBassBoostSupported, expected, reason: '$platform');
      expect(service.isSurroundSupported, expected, reason: '$platform');
    }
  });
}
