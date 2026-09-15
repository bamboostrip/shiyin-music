import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/volume_scale.dart';

void main() {
  group('mpvVolumeFromLinear（线性 → mpv 立方刻度）', () {
    test('0 → 0', () {
      expect(mpvVolumeFromLinear(0), 0);
    });

    test('1.0 → 100.0（0dB 基准点）', () {
      expect(mpvVolumeFromLinear(1.0), closeTo(100.0, 1e-9));
    });

    test('2.0 → ≈125.99（+6dB）', () {
      expect(mpvVolumeFromLinear(2.0), closeTo(125.99210498948732, 1e-9));
    });

    test('0.5 → ≈79.37（-6dB）', () {
      expect(mpvVolumeFromLinear(0.5), closeTo(79.37005259840998, 1e-9));
    });

    test('负输入 clamp 到 0（防御，just_audio 契约本身不允许负值）', () {
      expect(mpvVolumeFromLinear(-1.0), 0);
      expect(mpvVolumeFromLinear(-0.001), 0);
    });

    test('回归锁定：-4.33dB 的线性系数 0.607 → ≈84.68，绝不是 60.7', () {
      // 若此值回到 60.7 附近说明立方刻度换算被移除（退回直接 ×100），
      // 所有响度增益的 dB 将被放大 3 倍（想 -4.33dB 实际 -13dB），
      // 表现为"轻歌炸、响歌哑"。
      expect(mpvVolumeFromLinear(0.607), closeTo(84.6765, 0.01));
    });
  });

  group('linearFromMpvVolume（mpv 立方刻度 → 线性，回读用）', () {
    test('100.0 → 1.0', () {
      expect(linearFromMpvVolume(100.0), closeTo(1.0, 1e-9));
    });

    test('≈125.99 → 2.0', () {
      expect(linearFromMpvVolume(125.99210498948732), closeTo(2.0, 1e-9));
    });

    test('0 → 0', () {
      expect(linearFromMpvVolume(0), 0);
    });

    test('负输入 clamp 到 0（防御）', () {
      expect(linearFromMpvVolume(-50), 0);
    });
  });

  group('roundtrip（线性 → mpv → 线性）', () {
    test('常用音量无损往返', () {
      for (final v in [0.05, 0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0]) {
        expect(
          linearFromMpvVolume(mpvVolumeFromLinear(v)),
          closeTo(v, 1e-12),
          reason: 'v=$v 往返后失真',
        );
      }
    });
  });
}
