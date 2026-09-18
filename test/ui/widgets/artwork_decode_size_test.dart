import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';

/// 解码选档（[decodeSizeFor]）的档位单测。
///
/// 口径（P1-2 桌面网格解码降档）：
/// - 移动/车机（!isDesktopFormFactor）：维持旧公式 `size*2.0` 吸档、上限 600，
///   size 非有限 → 600，输出与旧函数逐一相等（零回归基线）。
/// - 桌面且非 highRes：`size*1.5` 吸档、上限 400（触顶后不再升到 480/600），
///   size 非有限 → 400。
/// - highRes=true（仅播放页海报/横屏大图两处传入）：任何形态都走旧 2x/600 档。
///
/// 档位表 [64,96,128,160,200,256,320,400,480,600] 两档共用，保证跨布局复用
/// 缓存的优点不丢。测试宿主为 Windows 桌面，故用
/// [debugDesktopFormFactorOverride] 显式固定形态（参照 form_factor_test）。
void main() {
  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  group('移动/车机档位（!isDesktopFormFactor，与旧 decodeSizeFor 逐一相等）', () {
    setUp(() {
      debugDesktopFormFactorOverride = false;
    });

    test('2x 吸档、上限 600、非有限尺寸回落 600', () {
      expect(decodeSizeFor(1), 64);
      expect(decodeSizeFor(44), 96);
      expect(decodeSizeFor(48), 96);
      expect(decodeSizeFor(63), 128);
      expect(decodeSizeFor(100), 200);
      // 120*2=240 吸附到 256（旧公式口径）。
      expect(decodeSizeFor(120), 256);
      expect(decodeSizeFor(139), 320);
      expect(decodeSizeFor(160), 320);
      expect(decodeSizeFor(231), 480);
      expect(decodeSizeFor(300), 600);
      expect(decodeSizeFor(500), 600);
      expect(decodeSizeFor(double.infinity), 600);
      expect(decodeSizeFor(double.nan), 600);
    });

    test('highRes 参数在移动端不改变输出（档位零变化）', () {
      for (final size in [1.0, 44.0, 63.0, 120.0, 231.0, 300.0, 500.0]) {
        expect(decodeSizeFor(size, highRes: true), decodeSizeFor(size),
            reason: 'size=$size');
      }
      expect(decodeSizeFor(double.infinity, highRes: true), 600);
    });
  });

  group('桌面档位（isDesktopFormFactor，非 highRes 走 1.5x/400）', () {
    setUp(() {
      debugDesktopFormFactorOverride = true;
    });

    test('1.5x 吸档', () {
      expect(decodeSizeFor(1), 64);
      // 44*1.5=66 → 96。
      expect(decodeSizeFor(44), 96);
      expect(decodeSizeFor(48), 96);
      // 63*1.5=94.5 → 95 → 96（旧公式为 128，此处降档是本任务目标）。
      expect(decodeSizeFor(63), 96);
      expect(decodeSizeFor(100), 160);
      // 120*1.5=180 → 200（旧公式为 256）。
      expect(decodeSizeFor(120), 200);
      expect(decodeSizeFor(139), 256);
      // 160*1.5=240 → 256。
      expect(decodeSizeFor(160), 256);
      // 231*1.5=346.5 → 347 → 400。
      expect(decodeSizeFor(231), 400);
    });

    test('触顶 400 后不再升档，非有限尺寸回落 400', () {
      // 260*1.5=390 → 400（仍在档内）。
      expect(decodeSizeFor(260), 400);
      // 280*1.5=420 超 400 → 触顶 400，而不是升到 480。
      expect(decodeSizeFor(280), 400);
      // 300*1.5=450 超 400 → 400。
      expect(decodeSizeFor(300), 400);
      expect(decodeSizeFor(500), 400);
      expect(decodeSizeFor(double.infinity), 400);
      expect(decodeSizeFor(double.nan), 400);
    });

    test('highRes=true 恢复旧 2x/600 档（播放页大图）', () {
      expect(decodeSizeFor(120, highRes: true), 256);
      expect(decodeSizeFor(160, highRes: true), 320);
      expect(decodeSizeFor(300, highRes: true), 600);
      expect(decodeSizeFor(500, highRes: true), 600);
      expect(decodeSizeFor(double.infinity, highRes: true), 600);
      expect(decodeSizeFor(double.nan, highRes: true), 600);
    });
  });

  group('桌面与移动同输入不同档（降档仅在桌面非 highRes 生效）', () {
    final cases = <double, List<int>>{
      63: [96, 128],
      120: [200, 256],
      160: [256, 320],
      231: [400, 480],
      300: [400, 600],
      double.infinity: [400, 600],
    };

    test('桌面 1.5x/400，移动 2x/600，同一输入输出不同', () {
      cases.forEach((size, expected) {
        debugDesktopFormFactorOverride = true;
        final desktop = decodeSizeFor(size);
        debugDesktopFormFactorOverride = false;
        final mobile = decodeSizeFor(size);
        expect(desktop, expected[0], reason: '桌面 size=$size');
        expect(mobile, expected[1], reason: '移动 size=$size');
        expect(desktop, lessThan(mobile), reason: 'size=$size');
      });
    });

    test('桌面 highRes=true 时与移动输出一致（大图不降档）', () {
      cases.forEach((size, expected) {
        debugDesktopFormFactorOverride = true;
        final desktopHighRes = decodeSizeFor(size, highRes: true);
        debugDesktopFormFactorOverride = false;
        final mobile = decodeSizeFor(size);
        expect(desktopHighRes, mobile, reason: 'size=$size');
        expect(desktopHighRes, expected[1], reason: 'size=$size');
      });
    });
  });

  group('Artwork 组件 highRes 透传', () {
    testWidgets('桌面形态：默认走 400 档，highRes: true 走 600 档', (tester) async {
      debugDesktopFormFactorOverride = true;

      await tester.pumpWidget(const MaterialApp(
        home: Center(
          child: Artwork(url: 'http://example.com/grid.jpg', size: 300),
        ),
      ));
      expect(
        tester.widget<RetryableNetworkImage>(
          find.byType(RetryableNetworkImage),
        ).cacheWidth,
        400,
      );

      await tester.pumpWidget(const MaterialApp(
        home: Center(
          child: Artwork(
            url: 'http://example.com/poster.jpg',
            size: double.infinity,
            highRes: true,
          ),
        ),
      ));
      expect(
        tester.widget<RetryableNetworkImage>(
          find.byType(RetryableNetworkImage),
        ).cacheWidth,
        600,
      );
    });
  });
}
