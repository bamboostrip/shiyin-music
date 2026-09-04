import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/horizontal_wheel_scroll.dart';

void main() {
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
}
