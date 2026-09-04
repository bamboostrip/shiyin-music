import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/horizontal_wheel_scroll.dart';

/// 取横向 ListView 的内部滚动位置。
ScrollPosition _innerPosition(WidgetTester tester) {
  return Scrollable.of(
    tester.element(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Viewport),
      ),
    ),
  ).position;
}

Widget _horizontalRailHost({
  required ScrollController outerController,
  required int itemCount,
  double height = 200,
  // 放在横轨上方的纵向填充，使外层 jumpTo 后横轨仍留在视口内。
  double leadingFiller = 0,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        controller: outerController,
        slivers: [
          if (leadingFiller > 0)
            SliverToBoxAdapter(child: SizedBox(height: leadingFiller)),
          SliverToBoxAdapter(
            child: SizedBox(
              height: height,
              child: HorizontalWheelScroll(
                builder: (context, controller) => ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  itemCount: itemCount,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, i) =>
                      SizedBox(width: 80, child: Text('i$i')),
                ),
              ),
            ),
          ),
          // 让外层纵向滚动有足够的可滚距离。
          const SliverToBoxAdapter(child: SizedBox(height: 3000)),
        ],
      ),
    ),
  );
}

void main() {
  group('horizontalWheelConsumes 纯函数', () {
    test('delta 为 0 / 无 clients：不消费', () {
      expect(
        horizontalWheelConsumes(
          delta: 0,
          hasClients: true,
          maxScrollExtent: 100,
          pixels: 0,
        ),
        isFalse,
      );
      expect(
        horizontalWheelConsumes(
          delta: 120,
          hasClients: false,
          maxScrollExtent: 100,
          pixels: 0,
        ),
        isFalse,
      );
    });

    test('轨道不可滚动（maxScrollExtent <= 0）：放行', () {
      expect(
        horizontalWheelConsumes(
          delta: 120,
          hasClients: true,
          maxScrollExtent: 0,
          pixels: 0,
        ),
        isFalse,
      );
      expect(
        horizontalWheelConsumes(
          delta: -120,
          hasClients: true,
          maxScrollExtent: 0,
          pixels: 0,
        ),
        isFalse,
      );
    });

    test('向末端的滚轮（delta > 0）：中间消费、到边缘放行', () {
      const max = 300.0;
      expect(
        horizontalWheelConsumes(
          delta: 120,
          hasClients: true,
          maxScrollExtent: max,
          pixels: 0,
        ),
        isTrue,
      );
      expect(
        horizontalWheelConsumes(
          delta: 120,
          hasClients: true,
          maxScrollExtent: max,
          pixels: max - 0.5, // 容差内视为已到边缘
        ),
        isFalse,
      );
      expect(
        horizontalWheelConsumes(
          delta: 120,
          hasClients: true,
          maxScrollExtent: max,
          pixels: max,
        ),
        isFalse,
      );
    });

    test('向起端的滚轮（delta < 0）：中间消费、到边缘放行', () {
      const max = 300.0;
      expect(
        horizontalWheelConsumes(
          delta: -120,
          hasClients: true,
          maxScrollExtent: max,
          pixels: max,
        ),
        isTrue,
      );
      expect(
        horizontalWheelConsumes(
          delta: -120,
          hasClients: true,
          maxScrollExtent: max,
          pixels: 0.4, // 容差内视为已到起点
        ),
        isFalse,
      );
      expect(
        horizontalWheelConsumes(
          delta: -120,
          hasClients: true,
          maxScrollExtent: max,
          pixels: 0,
        ),
        isFalse,
      );
    });
  });

  Future<void> sendWheel(WidgetTester tester, Offset dy) async {
    final center = tester.getCenter(find.byType(ListView));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: dy),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('垂直滚轮驱动横向 ListView', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            child: HorizontalWheelScroll(
              builder: (context, controller) => ListView.separated(
                controller: controller,
                scrollDirection: Axis.horizontal,
                itemCount: 40,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, i) => SizedBox(width: 80, child: Text('i$i')),
              ),
            ),
          ),
        ),
      ),
    ));

    await sendWheel(tester, const Offset(0, 120));
    // Scrollable.of 需要取 ListView 内部（Scrollable 是其后代）的 context。
    final ScrollPosition position = Scrollable.of(
      tester.element(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Viewport),
        ),
      ),
    ).position;
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('PageController 由滚轮驱动（HorizontalWheelPageScroll）', (tester) async {
    final pageController = PageController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HorizontalWheelPageScroll(
          controller: pageController,
          child: PageView(
            controller: pageController,
            children: [
              for (var i = 0; i < 5; i++)
                SizedBox.expand(child: Center(child: Text('p$i'))),
            ],
          ),
        ),
      ),
    ));

    final center = tester.getCenter(find.byType(PageView));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 400)),
    );
    await tester.pumpAndSettle();
    expect(pageController.page, greaterThan(0));
    pageController.dispose();
  });

  group('滚轮放行（外层纵向滚动）', () {
    testWidgets('轨道不可滚（内容不超宽）时滚轮放行给外层，不吞事件', (tester) async {
      final outer = ScrollController();
      await tester.pumpWidget(
        _horizontalRailHost(
          outerController: outer,
          itemCount: 2, // 2*80 + 10 = 170 < 800 视口宽 → maxScrollExtent == 0
        ),
      );
      expect(_innerPosition(tester).maxScrollExtent, 0);

      await sendWheel(tester, const Offset(0, 120));

      // 外层纵向滚动恰好滚动一次（120），证明事件被放行且未双重滚动。
      expect(outer.offset, 120);
      outer.dispose();
    });

    testWidgets('可滚方向上照常消费：内层滚动、外层不动', (tester) async {
      final outer = ScrollController();
      await tester.pumpWidget(
        _horizontalRailHost(
          outerController: outer,
          itemCount: 40,
        ),
      );

      await sendWheel(tester, const Offset(0, 120));

      expect(_innerPosition(tester).pixels, 120); // 内层只滚一次
      expect(outer.offset, 0); // 外层不受影响（resolver 注册抢占生效）
      outer.dispose();
    });

    testWidgets('滚动到横向末端后滚轮放行给外层（不会双重滚动）', (tester) async {
      final outer = ScrollController();
      await tester.pumpWidget(
        _horizontalRailHost(
          outerController: outer,
          itemCount: 12, // 内容 1070，视口 800 → max = 270
        ),
      );
      final position = _innerPosition(tester);
      expect(position.maxScrollExtent, greaterThan(0));

      // 连续下滚直到内层到达末端（继续消费），再多滚一次应放行。
      var forwarded = false;
      for (var i = 0; i < 10 && outer.offset == 0; i++) {
        await sendWheel(tester, const Offset(0, 120));
        if (outer.offset > 0) forwarded = true;
      }
      expect(forwarded, isTrue);
      expect(position.pixels, position.maxScrollExtent); // 内层停在末端
      expect(outer.offset, 120); // 外层只滚一次
      outer.dispose();
    });

    testWidgets('回到起点后向上滚轮（delta < 0）放行给外层', (tester) async {
      // leadingFiller 600 需要更高的视口，默认表面 800x600 不够。
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final outer = ScrollController();
      await tester.pumpWidget(
        _horizontalRailHost(
          outerController: outer,
          itemCount: 40,
          leadingFiller: 600, // 外层滚过后横轨仍留在视口内
        ),
      );
      final position = _innerPosition(tester);

      // 外层先向下滚一段；内层回到起点。
      outer.jumpTo(500);
      position.jumpTo(0);
      await tester.pump();

      await sendWheel(tester, const Offset(0, -120));

      expect(outer.offset, 380); // 外层向上滚一次：500 - 120
      expect(position.pixels, 0); // 内层停在起点
      outer.dispose();
    });
  });
}
