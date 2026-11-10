import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/expandable_intro.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: 300, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('短简介不显示「详细」按钮', (tester) async {
    await tester.pumpWidget(_wrap(const ExpandableIntro(text: '一句话简介')));
    await tester.pumpAndSettle();

    expect(find.text('一句话简介'), findsOneWidget);
    expect(find.text('详细'), findsNothing);
  });

  testWidgets('长简介默认收起 3 行，点「详细」展开、点「收起」收回', (tester) async {
    final longText = List.generate(12, (i) => '第${i + 1}句简介内容，用于测试折叠。').join();
    await tester.pumpWidget(
      _wrap(ExpandableIntro(title: '歌手简介', text: longText)),
    );
    await tester.pumpAndSettle();

    expect(find.text('歌手简介'), findsOneWidget);
    expect(find.text('详细'), findsOneWidget);

    final collapsed = tester.widget<Text>(find.text(longText));
    expect(collapsed.maxLines, 3);
    expect(collapsed.overflow, TextOverflow.ellipsis);

    await tester.tap(find.text('详细'));
    await tester.pumpAndSettle();

    final expanded = tester.widget<Text>(find.text(longText));
    expect(expanded.maxLines, isNull);
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('详细'), findsNothing);

    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.text('详细'), findsOneWidget);
  });

  testWidgets('空文本不渲染任何内容', (tester) async {
    await tester.pumpWidget(_wrap(const ExpandableIntro(text: '   ')));
    await tester.pumpAndSettle();

    expect(find.byType(ExpandableIntro), findsOneWidget);
    expect(find.text('详细'), findsNothing);
  });
}
