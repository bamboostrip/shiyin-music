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

/// 与 [_wrap] 相同，但把全局字体缩放换成 [scale]（车机/系统大字体）。
Widget _wrapScaled(Widget child, double scale) {
  return MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Center(
            child: SizedBox(width: 300, child: child),
          ),
        ),
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

  testWidgets('大字体放大后超行：必须出现「详细」（测量要带 textScaler）', (tester) async {
    // 10 个汉字 × 13.5 ≈ 135px，1.0 倍时在 300px 宽内只占 1 行（不溢出）；
    // 3.0 倍时 ≈ 405px 必然折成 2 行 > collapsedMaxLines(1)。两端的余量都很大，
    // 不依赖测试字体的精确度量。旧实现测量用 TextScaler.noScaling，放大后正文
    // 其实已被省略号截断，却判定「未溢出」→「详细」永不出现，用户看不到全文。
    const text = '一二三四五六七八九十';
    await tester.pumpWidget(
      _wrapScaled(
        const ExpandableIntro(text: text, collapsedMaxLines: 1),
        1.0,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('详细'),
      findsNothing,
      reason: '1.0 倍时未超行，不该有展开按钮（否则用例失去区分度）',
    );

    await tester.pumpWidget(
      _wrapScaled(
        const ExpandableIntro(text: text, collapsedMaxLines: 1),
        3.0,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('详细'),
      findsOneWidget,
      reason: '字体放大后已超行，必须能展开看全文',
    );
  });
}
