import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/desktop/desktop_window.dart';

void main() {
  group('DesktopWindowGeometry.clampToVisibleAreas', () {
    test('窗口与第一个可见区域相交 → 原样返回', () {
      const geometry = DesktopWindowGeometry(
        left: 100,
        top: 100,
        width: 1280,
        height: 800,
      );
      final result = DesktopWindowGeometry.clampToVisibleAreas(
        geometry,
        const [Rect.fromLTWH(0, 0, 1920, 1080)],
      );
      expect(result, geometry);
    });

    test('窗口与第二个可见区域相交 → 原样返回', () {
      const geometry = DesktopWindowGeometry(
        left: 2000,
        top: 100,
        width: 1280,
        height: 800,
      );
      final result = DesktopWindowGeometry.clampToVisibleAreas(
        geometry,
        const [
          Rect.fromLTWH(0, 0, 1920, 1080),
          Rect.fromLTWH(1920, 0, 1920, 1080),
        ],
      );
      expect(result, geometry);
    });

    test('窗口完全在屏幕右侧外 → 钳制进第一个区域（右/下各留 80px）', () {
      const geometry = DesktopWindowGeometry(
        left: 5000,
        top: 5000,
        width: 1280,
        height: 800,
      );
      final result = DesktopWindowGeometry.clampToVisibleAreas(
        geometry,
        const [Rect.fromLTWH(0, 0, 1920, 1080)],
      );
      // left = 0 + max(0, 1920 - 80 - 1280) = 560
      // top  = 0 + max(0, 1080 - 80 - 800) = 200
      expect(
        result,
        const DesktopWindowGeometry(
          left: 560,
          top: 200,
          width: 1280,
          height: 800,
        ),
      );
    });

    test('窗口完全在屏幕左侧外（负坐标）→ 钳制进第一个区域', () {
      const geometry = DesktopWindowGeometry(
        left: -5000,
        top: 100,
        width: 1280,
        height: 800,
      );
      final result = DesktopWindowGeometry.clampToVisibleAreas(
        geometry,
        const [Rect.fromLTWH(0, 0, 1920, 1080)],
      );
      // left = 0 + max(0, 1920 - 80 - 1280) = 560
      // top  = 0 + max(0, 1080 - 80 - 800) = 200
      expect(
        result,
        const DesktopWindowGeometry(
          left: 560,
          top: 200,
          width: 1280,
          height: 800,
        ),
      );
    });

    test('窗口比区域（减 80px）更宽/更高 → 贴第一个区域左上角', () {
      const geometry = DesktopWindowGeometry(
        left: -3000,
        top: -3000,
        width: 1900,
        height: 1200,
      );
      final result = DesktopWindowGeometry.clampToVisibleAreas(
        geometry,
        const [Rect.fromLTWH(0, 0, 1920, 1080)],
      );
      // max(0, 1920 - 80 - 1900) = 0、max(0, 1080 - 80 - 1200) = 0
      expect(
        result,
        const DesktopWindowGeometry(
          left: 0,
          top: 0,
          width: 1900,
          height: 1200,
        ),
      );
    });

    test('多个区域互不相交 → 落到第一个区域', () {
      const geometry = DesktopWindowGeometry(
        left: 5000,
        top: 5000,
        width: 1280,
        height: 800,
      );
      final result = DesktopWindowGeometry.clampToVisibleAreas(
        geometry,
        const [
          Rect.fromLTWH(0, 0, 1920, 1080),
          Rect.fromLTWH(1920, 0, 1920, 1080),
        ],
      );
      // 相对第一个区域：left = 560、top = 200
      expect(
        result,
        const DesktopWindowGeometry(
          left: 560,
          top: 200,
          width: 1280,
          height: 800,
        ),
      );
    });

    test('可见区域列表为空 → 原样返回', () {
      const geometry = DesktopWindowGeometry(
        left: 5000,
        top: 5000,
        width: 1280,
        height: 800,
      );
      final result = DesktopWindowGeometry.clampToVisibleAreas(
        geometry,
        const [],
      );
      expect(result, geometry);
    });
  });
}
