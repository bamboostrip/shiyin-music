import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/app_search_field.dart';
import 'package:shiyin_music/ui/widgets/marquee_text.dart';

/// [AppSearchField]（移动端统一搜索胶囊）的失焦覆盖层行为契约。
///
/// 背景：输入框失焦后原生 TextField 只会把超长文本裁成省略号，所以失焦且
/// 有文字时改为「原生文字置透明 + 叠一层 MarqueeText 跑马灯」。
///
/// 这里锁住的核心不变量：**跑马灯的可见窗口必须止于清除按钮左侧**。
/// 第一版实现直接 `Positioned.fill` 铺满整个 Stack，而 Stack 的宽度包含了
/// 右侧 32px 的后缀槽（清除按钮），于是滚动中的文字会画到 X 图标上。
void main() {
  const fieldWidth = 300.0;
  // 足够长，必然溢出 300px 宽的胶囊。
  const longText =
      '经理翻案上来饭啦空阔洁陵奥赛微这是一条特别特别长的搜索关键词用来触发跑马灯';

  Future<FocusNode> pumpField(
    WidgetTester tester,
    TextEditingController controller, {
    FocusNode? focusNode,
    String hintText = '搜索歌曲、歌手、专辑',
  }) async {
    final node = focusNode ?? FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: fieldWidth,
              child: AppSearchField(
                controller: controller,
                focusNode: node,
                hintText: hintText,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return node;
  }

  group('AppSearchField 失焦跑马灯覆盖层', () {
    testWidgets('跑马灯可见窗口不进入清除按钮区域（回归：文字曾画到 X 上）', (tester) async {
      final controller = TextEditingController(text: longText);
      addTearDown(controller.dispose);
      await pumpField(tester, controller);

      // 失焦 + 有文字 → 跑马灯接管显示，且确实在滚动（有 ClipRect）。
      final marquee = find.byType(MarqueeText);
      expect(marquee, findsOneWidget);
      expect(
        find.descendant(of: marquee, matching: find.byType(ClipRect)),
        findsOneWidget,
        reason: '文本溢出时应该走滚动分支而不是静态渲染',
      );

      // 文本未被截断：跑马灯里能看到完整文本。
      // 注意不能直接 find.text —— TextField 自身的 EditableText 也在树上
      // （只是被置成了透明），会一起命中。限定在 MarqueeText 子树内断言。
      expect(
        find.descendant(of: marquee, matching: find.text(longText)),
        findsOneWidget,
      );

      final clearIcon = find.byIcon(Icons.close_rounded);
      expect(clearIcon, findsOneWidget);

      final marqueeRect = tester.getRect(marquee);
      final clearRect = tester.getRect(clearIcon);
      final fieldRect = tester.getRect(find.byType(TextField));

      // 核心不变量：跑马灯右边界不得越过清除图标左边界。
      expect(
        marqueeRect.right,
        lessThanOrEqualTo(clearRect.left),
        reason: '跑马灯不得绘制到后缀槽（清除按钮）上',
      );
      // 而且它确实按后缀槽内缩了，不是铺满整个输入框。
      expect(marqueeRect.right, lessThan(fieldRect.right));
      // 左侧仍与输入区起点对齐（不需要内缩）。
      expect(marqueeRect.left, greaterThanOrEqualTo(fieldRect.left));
    });

    testWidgets('聚焦时由 TextField 自己显示文本，不叠跑马灯', (tester) async {
      final controller = TextEditingController(text: longText);
      addTearDown(controller.dispose);
      final node = await pumpField(tester, controller);
      expect(find.byType(MarqueeText), findsOneWidget);

      node.requestFocus();
      // 焦点变更由 FocusManager 在帧末应用，监听回调里的 setState 再排一帧，
      // 所以要泵两帧才能看到覆盖层被移除。
      await tester.pump();
      await tester.pump();

      expect(node.hasFocus, isTrue);
      expect(find.byType(MarqueeText), findsNothing);

      // 聚焦态原生文字必须可见（不能被置透明）。
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.style?.color, isNot(Colors.transparent));
    });

    testWidgets('文本放得下时渲染静态文本，不产生滚动', (tester) async {
      final controller = TextEditingController(text: '晴天');
      addTearDown(controller.dispose);
      await pumpField(tester, controller);

      final marquee = find.byType(MarqueeText);
      expect(marquee, findsOneWidget);
      expect(
        find.descendant(of: marquee, matching: find.byType(ClipRect)),
        findsNothing,
        reason: '放得下时 MarqueeText 应零开销退化为静态 Text.rich',
      );
      // 同样限定在 MarqueeText 子树内（外层 TextField 的 EditableText 也在树上）。
      expect(
        find.descendant(of: marquee, matching: find.text('晴天')),
        findsOneWidget,
      );
    });

    testWidgets('空输入显示 hint，不出现跑马灯', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpField(tester, controller);

      expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
      expect(find.byType(MarqueeText), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsNothing);
    });

    testWidgets('点跑马灯区域能重新聚焦输入框（覆盖层不吞点击）', (tester) async {
      final controller = TextEditingController(text: longText);
      addTearDown(controller.dispose);
      final node = await pumpField(tester, controller);
      expect(node.hasFocus, isFalse);

      // 点在跑马灯文字中段：覆盖层是 IgnorePointer，点击应穿透到下层 TextField。
      await tester.tapAt(tester.getCenter(find.byType(MarqueeText)));
      await tester.pump();

      expect(node.hasFocus, isTrue);
    });

    testWidgets('清除按钮仍可点：清空后回到 hint 态', (tester) async {
      final controller = TextEditingController(text: longText);
      addTearDown(controller.dispose);
      await pumpField(tester, controller);
      expect(find.byType(MarqueeText), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();

      expect(controller.text, isEmpty);
      expect(find.byType(MarqueeText), findsNothing);
      expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
    });
  });
}
