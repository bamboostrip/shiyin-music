import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/background_crop.dart';

/// 背景图裁剪几何的纯函数单测。
///
/// 锁死三件事：
/// 1. 源矩形宽高比恒等于视口宽高比 —— 渲染时 `drawImageRect` 是纯等比缩放，
///    这是「背景永不变形」的数学保证；
/// 2. 源矩形永远落在原图内 —— 不会画出透明/黑边；
/// 3. 平移/缩放的夹紧与锚点行为 —— 手势手感与越界保护。
void main() {
  const image = Size(4000, 3000);
  const portraitBox = Size(1080, 2400);
  const landscapeBox = Size(2400, 1080);

  group('BackgroundCrop', () {
    test('默认构图是居中 + 最小放大', () {
      expect(BackgroundCrop.center.focusX, 0.5);
      expect(BackgroundCrop.center.focusY, 0.5);
      expect(BackgroundCrop.center.zoom, 1);
      expect(BackgroundCrop.center.isDefault, isTrue);
      expect(BackgroundCrop.center.copyWith(zoom: 2).isDefault, isFalse);
    });

    test('normalized 夹到合法范围，脏数据回落默认值', () {
      expect(
        const BackgroundCrop(focusX: -1, focusY: 2, zoom: 0.2).normalized(),
        const BackgroundCrop(focusX: 0, focusY: 1, zoom: 1),
      );
      expect(
        const BackgroundCrop(focusX: 0.3, focusY: 0.7, zoom: 99).normalized(),
        const BackgroundCrop(focusX: 0.3, focusY: 0.7, zoom: 3),
      );
      expect(
        const BackgroundCrop(
          focusX: double.nan,
          focusY: double.infinity,
          zoom: double.nan,
        ).normalized(),
        BackgroundCrop.center,
      );
    });

    test('相等性按值比较', () {
      expect(
        const BackgroundCrop(focusX: 0.2, focusY: 0.3, zoom: 1.5),
        const BackgroundCrop(focusX: 0.2, focusY: 0.3, zoom: 1.5),
      );
      expect(
        const BackgroundCrop(focusX: 0.2),
        isNot(const BackgroundCrop(focusX: 0.3)),
      );
      expect(
        const BackgroundCrop(focusX: 0.2).hashCode,
        const BackgroundCrop(focusX: 0.2).hashCode,
      );
    });
  });

  group('visibleImageFraction', () {
    test('竖屏视口 + 横图：cover 裁掉左右，宽可见比例 < 1、高铺满', () {
      final visible = visibleImageFraction(
        imageSize: image,
        boxSize: portraitBox,
        crop: BackgroundCrop.center,
      );
      expect(visible.width, closeTo(1080 / (0.8 * 4000), 1e-9));
      expect(visible.height, 1);
    });

    test('放大 2 倍后可见比例减半', () {
      final visible = visibleImageFraction(
        imageSize: image,
        boxSize: portraitBox,
        crop: const BackgroundCrop(zoom: 2),
      );
      expect(visible.width, closeTo(1080 / (0.8 * 4000) / 2, 1e-9));
      expect(visible.height, 0.5);
    });

    test('图像与视口比例相同 + 未放大：可见整图', () {
      final visible = visibleImageFraction(
        imageSize: image,
        boxSize: const Size(400, 300),
        crop: BackgroundCrop.center,
      );
      expect(visible.width, closeTo(1, 1e-9));
      expect(visible.height, closeTo(1, 1e-9));
    });

    test('非法尺寸/参数安全回落', () {
      expect(
        visibleImageFraction(
          imageSize: Size.zero,
          boxSize: portraitBox,
          crop: BackgroundCrop.center,
        ),
        const Size(1, 1),
      );
      expect(
        visibleImageFraction(
          imageSize: image,
          boxSize: const Size(double.infinity, 100),
          crop: BackgroundCrop.center,
        ),
        const Size(1, 1),
      );
    });
  });

  group('backgroundSourceRect', () {
    test('默认构图：竖屏视口取横图中间一条，且铺满视口高度', () {
      final rect = backgroundSourceRect(
        imageSize: image,
        boxSize: portraitBox,
        crop: BackgroundCrop.center,
      );
      // 可见宽 = 0.3375 * 4000 = 1350，高 = 3000，居中 → 左边 1325。
      expect(rect.width, closeTo(1350, 1e-6));
      expect(rect.height, closeTo(3000, 1e-6));
      expect(rect.left, closeTo(1325, 1e-6));
      expect(rect.top, closeTo(0, 1e-6));
    });

    test('任意图像/视口/焦距组合下：源矩形宽高比恒等于视口宽高比', () {
      final cases = <(Size, Size, BackgroundCrop)>[
        (image, portraitBox, BackgroundCrop.center),
        (image, landscapeBox, BackgroundCrop.center),
        (
          const Size(1080, 2400),
          const Size(2400, 1080),
          const BackgroundCrop(zoom: 2),
        ),
        (
          const Size(1080, 1920),
          const Size(1080, 1080),
          const BackgroundCrop(focusX: 0.1, focusY: 0.9, zoom: 3),
        ),
        (
          const Size(500, 500),
          const Size(4000, 100),
          const BackgroundCrop(focusX: 0.3, focusY: 0.6, zoom: 1.7),
        ),
      ];
      for (final (imageSize, boxSize, crop) in cases) {
        final rect = backgroundSourceRect(
          imageSize: imageSize,
          boxSize: boxSize,
          crop: crop,
        );
        expect(
          rect.width / rect.height,
          closeTo(boxSize.width / boxSize.height, 1e-6),
          reason: 'image=$imageSize box=$boxSize crop=$crop',
        );
      }
    });

    test('任意组合下源矩形都落在原图范围内', () {
      for (final zoom in [1.0, 1.3, 2.0, 3.0]) {
        for (final focusX in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          for (final focusY in [0.0, 0.5, 1.0]) {
            final crop = BackgroundCrop(
              focusX: focusX,
              focusY: focusY,
              zoom: zoom,
            );
            for (final box in [portraitBox, landscapeBox]) {
              final rect = backgroundSourceRect(
                imageSize: image,
                boxSize: box,
                crop: crop,
              );
              expect(rect.left, greaterThanOrEqualTo(-1e-6));
              expect(rect.top, greaterThanOrEqualTo(-1e-6));
              expect(rect.right, lessThanOrEqualTo(image.width + 1e-6));
              expect(rect.bottom, lessThanOrEqualTo(image.height + 1e-6));
            }
          }
        }
      }
    });

    test('非法尺寸返回空矩形（调用方直接跳过绘制）', () {
      expect(
        backgroundSourceRect(
          imageSize: Size.zero,
          boxSize: portraitBox,
          crop: BackgroundCrop.center,
        ),
        Rect.zero,
      );
      expect(
        backgroundSourceRect(
          imageSize: image,
          boxSize: const Size(double.nan, 100),
          crop: BackgroundCrop.center,
        ),
        Rect.zero,
      );
    });
  });

  group('panBackgroundCrop', () {
    test('向右拖：画面右移，聚焦点左移，缩放不变', () {
      final moved = panBackgroundCrop(
        crop: BackgroundCrop.center,
        delta: const Offset(108, 0),
        imageSize: image,
        boxSize: portraitBox,
      );
      // 可见宽 0.3375：拖过 1/10 视口宽 = 0.03375 图像比例。
      expect(moved.focusX, closeTo(0.5 - 0.03375, 1e-9));
      expect(moved.focusY, closeTo(0.5, 1e-9));
      expect(moved.zoom, 1);
    });

    test('拖到边界被夹紧，可见区域不会越出图像', () {
      final moved = panBackgroundCrop(
        crop: BackgroundCrop.center,
        delta: const Offset(10000, 10000),
        imageSize: image,
        boxSize: portraitBox,
      );
      expect(moved.focusX, closeTo(0.3375 / 2, 1e-9));
      // 高度方向已铺满，聚焦点只能居中。
      expect(moved.focusY, closeTo(0.5, 1e-9));
    });

    test('非法尺寸/位移不改变参数', () {
      expect(
        panBackgroundCrop(
          crop: const BackgroundCrop(focusX: 0.3, zoom: 2),
          delta: const Offset(10, 10),
          imageSize: image,
          boxSize: Size.zero,
        ),
        const BackgroundCrop(focusX: 0.3, zoom: 2),
      );
      expect(
        panBackgroundCrop(
          crop: BackgroundCrop.center,
          delta: const Offset(double.nan, 0),
          imageSize: image,
          boxSize: portraitBox,
        ),
        BackgroundCrop.center,
      );
    });
  });

  group('zoomBackgroundCrop', () {
    test('以中心为锚点缩放：聚焦点不变', () {
      final zoomed = zoomBackgroundCrop(
        crop: BackgroundCrop.center,
        scaleFactor: 2,
        imageSize: image,
        boxSize: portraitBox,
      );
      expect(zoomed.zoom, 2);
      expect(zoomed.focusX, closeTo(0.5, 1e-9));
      expect(zoomed.focusY, closeTo(0.5, 1e-9));
    });

    test('以左上角为锚点缩放：该角对应的图像内容保持在原处', () {
      final zoomed = zoomBackgroundCrop(
        crop: BackgroundCrop.center,
        scaleFactor: 2,
        imageSize: image,
        boxSize: portraitBox,
        focal: Offset.zero,
      );
      // 缩放前左上角对应图像点 (0.5 - 0.3375/2, 0.5 - 0.5) = (0.33125, 0)，
      // 缩放后可见高 0.5，焦点 = (0.33125 + 0.5*0.16875, 0 + 0.25)。
      expect(zoomed.focusX, closeTo(0.33125 + 0.084375, 1e-6));
      expect(zoomed.focusY, closeTo(0.25, 1e-6));
      expect(zoomed.zoom, 2);
    });

    test('放大倍数被夹到 [1, 3]', () {
      expect(
        zoomBackgroundCrop(
          crop: BackgroundCrop.center,
          scaleFactor: 10,
          imageSize: image,
          boxSize: portraitBox,
        ).zoom,
        BackgroundCrop.maxZoom,
      );
      expect(
        zoomBackgroundCrop(
          crop: const BackgroundCrop(zoom: 1.2),
          scaleFactor: 0.01,
          imageSize: image,
          boxSize: portraitBox,
        ).zoom,
        BackgroundCrop.minZoom,
      );
    });

    test('非法输入不改变参数', () {
      expect(
        zoomBackgroundCrop(
          crop: BackgroundCrop.center,
          scaleFactor: 0,
          imageSize: image,
          boxSize: portraitBox,
        ),
        BackgroundCrop.center,
      );
      expect(
        zoomBackgroundCrop(
          crop: BackgroundCrop.center,
          scaleFactor: 2,
          imageSize: image,
          boxSize: portraitBox,
          focal: const Offset(double.nan, 0.5),
        ),
        BackgroundCrop.center,
      );
    });

    test('放大后聚焦点仍被夹在图像内', () {
      final zoomed = zoomBackgroundCrop(
        crop: const BackgroundCrop(focusX: 1, focusY: 1, zoom: 2),
        scaleFactor: 2,
        imageSize: image,
        boxSize: portraitBox,
        focal: const Offset(1, 1),
      );
      final visible = visibleImageFraction(
        imageSize: image,
        boxSize: portraitBox,
        crop: zoomed,
      );
      expect(zoomed.focusX, lessThanOrEqualTo(1 - visible.width / 2 + 1e-9));
      expect(zoomed.focusY, lessThanOrEqualTo(1 - visible.height / 2 + 1e-9));
      expect(zoomed.focusX, greaterThanOrEqualTo(visible.width / 2 - 1e-9));
      expect(zoomed.focusY, greaterThanOrEqualTo(visible.height / 2 - 1e-9));
    });
  });

  test('数学不变量：任意组合的源矩形都不会被非等比拉伸', () {
    // 用随机组合扫一遍，防止某个分支漏掉比例保持。
    final random = math.Random(20261105);
    for (var i = 0; i < 200; i++) {
      final imageSize = Size(
        100 + random.nextDouble() * 4000,
        100 + random.nextDouble() * 4000,
      );
      final boxSize = Size(
        100 + random.nextDouble() * 2000,
        100 + random.nextDouble() * 2000,
      );
      final crop = BackgroundCrop(
        focusX: random.nextDouble(),
        focusY: random.nextDouble(),
        zoom:
            BackgroundCrop.minZoom +
            random.nextDouble() *
                (BackgroundCrop.maxZoom - BackgroundCrop.minZoom),
      );
      final rect = backgroundSourceRect(
        imageSize: imageSize,
        boxSize: boxSize,
        crop: crop,
      );
      if (rect.isEmpty) continue;
      expect(
        rect.width / rect.height,
        closeTo(boxSize.width / boxSize.height, 1e-6),
        reason: 'image=$imageSize box=$boxSize crop=$crop',
      );
    }
  });
}
