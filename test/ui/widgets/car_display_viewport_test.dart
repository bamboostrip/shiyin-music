import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyin_music/ui/car_display_viewport.dart';

void main() {
  group('CarDisplayViewport.virtualMediaQuery', () {
    test('缩放收缩布局视口并保持物理像素不变', () {
      const real = MediaQueryData(
        size: Size(1280, 720),
        devicePixelRatio: 1.5,
        padding: EdgeInsets.only(top: 24, bottom: 12),
        viewPadding: EdgeInsets.only(top: 24, bottom: 12),
      );

      final virtual = CarDisplayViewport.virtualMediaQuery(
        real,
        scale: 1.25,
        marginTop: 20,
        marginBottom: 10,
      );

      // 布局视口 = 屏幕 / 缩放；高度还要扣掉上下物理留白。
      expect(virtual.size.width, closeTo(1280 / 1.25, 0.001));
      expect(virtual.size.height, closeTo((720 - 20 - 10) / 1.25, 0.001));
      // dpr 反向补偿：size * dpr 仍等于物理像素。
      expect(virtual.devicePixelRatio, closeTo(1.875, 0.001));
      // 虚拟高度 × 虚拟 dpr = 物理可用高度（屏幕扣掉上下留白）。
      expect(
        virtual.size.height * virtual.devicePixelRatio,
        closeTo((720 - 30) * 1.5, 0.001),
      );
      // 系统 inset 先扣掉已被物理留白让出的部分，再按缩放折算。
      expect(virtual.viewPadding.top, closeTo((24 - 20) / 1.25, 0.001));
      expect(virtual.viewPadding.bottom, closeTo((12 - 10) / 1.25, 0.001));
      expect(virtual.padding.top, closeTo(virtual.viewPadding.top, 0.001));
      expect(virtual.padding.bottom, closeTo(virtual.viewPadding.bottom, 0.001));
    });

    test('系统 inset 小于留白时归零，不发生负 padding 或重复让位', () {
      const real = MediaQueryData(
        size: Size(1024, 600),
        devicePixelRatio: 1,
        padding: EdgeInsets.only(top: 10, bottom: 8),
        viewPadding: EdgeInsets.only(top: 10, bottom: 8),
      );

      final virtual = CarDisplayViewport.virtualMediaQuery(
        real,
        scale: 1.15,
        marginTop: 30,
        marginBottom: 20,
      );

      expect(virtual.viewPadding.top, 0);
      expect(virtual.viewPadding.bottom, 0);
      expect(virtual.padding.top, 0);
      expect(virtual.padding.bottom, 0);
    });

    test('默认参数下与原数据一致（除 dpr 补偿为恒等）', () {
      const real = MediaQueryData(
        size: Size(800, 480),
        devicePixelRatio: 2,
        padding: EdgeInsets.only(top: 24, bottom: 16),
        viewPadding: EdgeInsets.only(top: 24, bottom: 16),
      );

      final virtual = CarDisplayViewport.virtualMediaQuery(
        real,
        scale: 1.0,
        marginTop: 0,
        marginBottom: 0,
      );

      expect(virtual.size, real.size);
      expect(virtual.devicePixelRatio, real.devicePixelRatio);
      expect(virtual.padding, real.padding);
      expect(virtual.viewPadding, real.viewPadding);
    });
  });

  group('CarDisplayViewport 渲染与命中', () {
    Future<void> pumpViewport(
      WidgetTester tester, {
      required double scale,
      required double marginTop,
      required double marginBottom,
      required Widget child,
    }) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(1280, 720)),
            child: CarDisplayViewport(
              scale: scale,
              marginTop: marginTop,
              marginBottom: marginBottom,
              child: child,
            ),
          ),
        ),
      );
    }

    testWidgets('子节点按虚拟尺寸布局，网格可真正重排', (tester) async {
      Size? innerSize;
      Size? innerMediaSize;
      await pumpViewport(
        tester,
        scale: 1.25,
        marginTop: 20,
        marginBottom: 10,
        child: Builder(
          builder: (context) {
            innerMediaSize = MediaQuery.sizeOf(context);
            return LayoutBuilder(
              builder: (context, constraints) {
                innerSize = constraints.biggest;
                return const SizedBox.expand();
              },
            );
          },
        ),
      );

      expect(innerSize, isNotNull);
      expect(innerSize!.width, closeTo(1280 / 1.25, 0.01));
      expect(innerSize!.height, closeTo((720 - 30) / 1.25, 0.01));
      expect(innerMediaSize, innerSize);
    });

    testWidgets('放大后整屏可命中（不出现「看得见点不到」）', (tester) async {
      var taps = 0;
      await pumpViewport(
        tester,
        scale: 1.5,
        marginTop: 0,
        marginBottom: 0,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          child: const SizedBox.expand(),
        ),
      );

      // 屏幕右下角属于「放大后的溢出区」：普通 Transform.scale + SizedBox
      // 写法这里会命中失败，本视口必须可点。
      await tester.tapAt(const Offset(1270, 710));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('上下留白区域不响应命中，留白内不重复消费系统 inset', (tester) async {
      var taps = 0;
      await pumpViewport(
        tester,
        scale: 1.0,
        marginTop: 40,
        marginBottom: 20,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          child: const SizedBox.expand(),
        ),
      );

      // 顶部留白内（y=10）不应命中内容。
      await tester.tapAt(const Offset(640, 10));
      await tester.pump();
      expect(taps, 0);

      // 留白之下的内容区可命中。
      await tester.tapAt(const Offset(640, 60));
      await tester.pump();
      expect(taps, 1);

      // 底部留白内（y=710）也不命中。
      await tester.tapAt(const Offset(640, 710));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('车机模式关闭或参数默认时 maybe 不引入额外层级', (tester) async {
      const child = SizedBox(width: 10, height: 10);
      expect(
        CarDisplayViewport.maybe(
          enabled: false,
          scale: 1.25,
          marginTop: 30,
          marginBottom: 0,
          child: child,
        ),
        same(child),
      );
      expect(
        CarDisplayViewport.maybe(
          enabled: true,
          scale: 1.0,
          marginTop: 0,
          marginBottom: 0,
          child: child,
        ),
        same(child),
      );
      expect(
        CarDisplayViewport.maybe(
          enabled: true,
          scale: 1.25,
          marginTop: 0,
          marginBottom: 0,
          child: child,
        ),
        isA<CarDisplayViewport>(),
      );
    });
  });
}
