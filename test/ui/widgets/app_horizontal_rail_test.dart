import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/app_section.dart';
import 'package:shiyin_music/ui/widgets/horizontal_wheel_scroll.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  tearDown(() => debugDesktopFormFactorOverride = null);

  // 布局约束来自测试视口而非 MediaQuery 数据（MediaQuery 只是继承数据，
  // 不会改变 LayoutBuilder 收到的约束），因此同步设置真实视口尺寸。
  Future<void> pumpRail(
    WidgetTester tester,
    Widget child,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(child));
  }

  Widget rail() => AppHorizontalRail<String>(
        title: '测试轨',
        items: ['a', 'b', 'c'],
        height: 120,
        itemWidth: 100,
        itemBuilder: (_, item) => Text(item),
      );

  testWidgets('桌面窄窗(<840)：保持横轨', (tester) async {
    debugDesktopFormFactorOverride = true;
    await pumpRail(tester, rail(), const Size(700, 800));
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    // 横轨必须包裹在滚轮横滚组件内（桌面滚轮可横向滚动）。
    expect(find.byType(HorizontalWheelScroll), findsOneWidget);
  });

  testWidgets('桌面宽窗(≥840)：转网格', (tester) async {
    debugDesktopFormFactorOverride = true;
    await pumpRail(tester, rail(), const Size(1200, 800));
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('非桌面同宽(≥840)：平板侧栏形态同样转网格', (tester) async {
    // 门控已放宽为纯宽度阈值：移动形态宽内容区（平板触屏侧栏形态）
    // 与桌面宽窗行为一致，手机窄宽度仍保持横轨。
    debugDesktopFormFactorOverride = false;
    await pumpRail(tester, rail(), const Size(1200, 800));
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('非桌面窄宽(<840)：保持横轨（手机零回归）', (tester) async {
    debugDesktopFormFactorOverride = false;
    await pumpRail(tester, rail(), const Size(700, 800));
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
  });
}
