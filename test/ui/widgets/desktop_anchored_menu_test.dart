import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/desktop_anchored_menu.dart';

void main() {
  group('placeAnchoredMenu 纯函数', () {
    test('正常情况：菜单从锚点（左上角参考点）向右下展开，不翻转', () {
      final rect = placeAnchoredMenu(
        anchor: const Offset(100, 120),
        menuSize: const Size(220, 200),
        screenSize: const Size(1280, 800),
      );

      expect(rect.topLeft, const Offset(100, 120));
      expect(rect.width, 220);
      expect(rect.height, 200);
    });

    test('下方溢出：向上翻转（菜单底缘贴锚点上方）', () {
      final rect = placeAnchoredMenu(
        anchor: const Offset(100, 700),
        menuSize: const Size(220, 200),
        screenSize: const Size(1280, 800),
      );

      // 700 + 200 > 800 - 8 → top = 700 - 200
      expect(rect.top, 500);
      expect(rect.bottom, 700);
      expect(rect.left, 100);
    });

    test('右侧溢出：向左翻转（菜单右缘贴锚点左侧）', () {
      final rect = placeAnchoredMenu(
        anchor: const Offset(1200, 100),
        menuSize: const Size(220, 200),
        screenSize: const Size(1280, 800),
      );

      // 1200 + 220 > 1280 - 8 → left = 1200 - 220
      expect(rect.left, 980);
      expect(rect.right, 1200);
      expect(rect.top, 100);
    });

    test('右下角双溢出：同时向左向上翻转', () {
      final rect = placeAnchoredMenu(
        anchor: const Offset(1200, 700),
        menuSize: const Size(220, 200),
        screenSize: const Size(1280, 800),
      );

      expect(rect.left, 980);
      expect(rect.top, 500);
    });

    test('锚点贴近左上角：钳制到屏幕边距（≥8px）', () {
      final rect = placeAnchoredMenu(
        anchor: const Offset(2, 2),
        menuSize: const Size(220, 200),
        screenSize: const Size(1280, 800),
      );

      expect(rect.left, 8);
      expect(rect.top, 8);
    });

    test('翻转后仍越界（锚点近右缘、菜单较宽）：钳制保留边距', () {
      // 锚点 x=1290 已超出屏幕：先触发左翻 → 1290-220=1070，
      // 1070+220=1290 > 1272 → 钳制到 1280-8-220=1052。
      final rect = placeAnchoredMenu(
        anchor: const Offset(1290, 100),
        menuSize: const Size(220, 200),
        screenSize: const Size(1280, 800),
      );

      expect(rect.left, 1052);
      expect(rect.right, 1272);
    });

    test('菜单比屏幕还大：收缩到可用区域并贴边距', () {
      final rect = placeAnchoredMenu(
        anchor: const Offset(10, 10),
        menuSize: const Size(600, 500),
        screenSize: const Size(300, 200),
      );

      expect(rect.left, 8);
      expect(rect.top, 8);
      expect(rect.width, 300 - 16);
      expect(rect.height, 200 - 16);
    });

    test('锚点在屏幕外（负坐标）：结果仍被钳制在边距内', () {
      final rect = placeAnchoredMenu(
        anchor: const Offset(-50, -50),
        menuSize: const Size(220, 200),
        screenSize: const Size(1280, 800),
      );

      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.right, lessThanOrEqualTo(1280 - 8));
      expect(rect.bottom, lessThanOrEqualTo(800 - 8));
    });

    test('自定义边距生效', () {
      final rect = placeAnchoredMenu(
        anchor: const Offset(0, 0),
        menuSize: const Size(100, 100),
        screenSize: const Size(1280, 800),
        margin: 16,
      );

      expect(rect.left, 16);
      expect(rect.top, 16);
    });
  });

  group('showDesktopAnchoredMenu 路由', () {
    testWidgets('菜单锚定在指定锚点处（测量后定位）', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const anchor = Offset(60, 60);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDesktopAnchoredMenu<void>(
                  context: context,
                  anchor: anchor,
                  builder: (_) => const SizedBox(width: 200, height: 100),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final positioned = tester.widgetList<Positioned>(
        find.byWidgetPredicate(
          (w) => w is Positioned && w.width != null && w.height != null,
        ),
      );
      expect(positioned, isNotEmpty);
      expect(positioned.first.left, anchor.dx);
      expect(positioned.first.top, anchor.dy);
      expect(positioned.first.width, 200);
      expect(positioned.first.height, 100);

      // barrier 覆盖全屏：存在 ModalBarrier 且可点击关闭
      final barrier = tester.widget<ModalBarrier>(
        find.byType(ModalBarrier).last,
      );
      expect(barrier.dismissible, isTrue);
    });

    testWidgets('点击空白处（barrier）关闭菜单', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDesktopAnchoredMenu<void>(
                  context: context,
                  anchor: const Offset(100, 100),
                  builder: (_) => const SizedBox(width: 200, height: 100),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(SizedBox).last, findsOneWidget);

      // 点击菜单外的空白区域
      await tester.tapAt(const Offset(700, 550));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) => w is Positioned && w.width == 200.0 && w.height == 100.0,
        ),
        findsNothing,
      );
    });

    testWidgets('按 Esc 关闭菜单', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDesktopAnchoredMenu<void>(
                  context: context,
                  anchor: const Offset(100, 100),
                  builder: (_) => const SizedBox(width: 200, height: 100),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) => w is Positioned && w.width == 200.0 && w.height == 100.0,
        ),
        findsNothing,
      );
    });
  });

  testWidgets('anchorBelow：取 RenderBox 底边中点的全局坐标', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    Offset? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Builder(
                builder: (context) => SizedBox(
                  width: 120,
                  height: 40,
                  child: GestureDetector(
                    onTap: () => result = anchorBelow(context),
                    child: const Text('tap-target'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Builder 的 RenderBox = SizedBox(120x40)，位于左上角。
    await tester.tap(find.text('tap-target'));

    expect(result, isNotNull);
    expect(result!.dx, 60); // 宽度中点
    expect(result!.dy, 40); // 底边
  });
}
