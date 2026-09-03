import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/desktop/desktop_sidebar.dart';

void main() {
  const items = [
    DesktopNavItem(icon: Icons.explore_outlined, activeIcon: Icons.explore_rounded, label: '推荐'),
    DesktopNavItem(icon: Icons.leaderboard_outlined, activeIcon: Icons.leaderboard_rounded, label: '排行榜'),
    DesktopNavItem(
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings_rounded,
      label: '设置',
      showDividerAbove: true,
    ),
  ];

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('点击条目回调对应下标', (tester) async {
    final selected = <int>[];
    await tester.pumpWidget(wrap(DesktopSidebar(
      items: items,
      selectedIndex: 0,
      onSelect: selected.add,
      onSearch: () {},
    )));

    await tester.tap(find.text('排行榜'));
    expect(selected, [1]);
  });

  testWidgets('选中项与悬停样式渲染且搜索可点', (tester) async {
    var searched = false;
    await tester.pumpWidget(wrap(DesktopSidebar(
      items: items,
      selectedIndex: 2,
      onSelect: (_) {},
      onSearch: () => searched = true,
    )));

    expect(find.text('搜索音乐'), findsOneWidget);
    await tester.tap(find.text('搜索音乐'));
    expect(searched, isTrue);
  });
}
