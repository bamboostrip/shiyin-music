import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';

void main() {
  group('equalizerPresets 数据完整性', () {
    test('预设数量为 16 且与扩容清单一致', () {
      expect(PlayerController.equalizerPresets, hasLength(16));
    });

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
    test('档案数量为 6（含改名后的纯净人声/现场演唱会）', () {
      expect(PlayerController.audioEffectProfiles, hasLength(6));
    });

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
