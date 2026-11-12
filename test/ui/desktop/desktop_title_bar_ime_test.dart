// 顶栏搜索胶囊（DesktopTitleBar._TitleBarSearchField）的 IME 组词链路测试。
//
// 背景：Windows 11 26H2 + Flutter 3.44.8 release 下用户报告「PC 顶栏搜索框
// 无法输入中文」（DesktopSearchSuggestPanel 打开）。本文件用
// TestTextInput.updateEditingValue 打真实 IME 的 updateEditingState 手势，
// 判定 Dart/Widget 侧是否会把组词（composing）状态打掉：
//
//   1. 组词文本是否原样进入 controller（不丢 composing 区间、不抛异常）；
//   2. 逐键组词（n→ni→nih→nihao）是否每一步都保留 composing；
//   3. 组词期间发生父级重建（悬停 setState）时 composing 是否幸存；
//   4. 提交（composing 清空 + 上屏中文）是否落到 controller；
//   5. 特征化用例：组词期间 Enter 目前会直接触发 onSubmitted，
//      把**拼音原文**交出去——顶栏没有 isImeComposingActive 守卫。
//
// 若本文件全绿而线上仍打不出中文，说明缺陷不在 Dart widget 层
// （嫌疑点排序见 .tmp-ime/ime-repo-audit.md）。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/desktop/desktop_title_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    // window_manager 在单测里没有原生实现：_checkMaximized() 会 await
    // isMaximized()，无 handler 时抛 MissingPluginException（lib 内已 catch）。
    // 这里给出稳定桩值，避免依赖实现的异常吞没。
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) async {
        switch (call.method) {
          case 'isMaximized':
          case 'isMaximizedValue':
          case 'isVisible':
          case 'isFullScreen':
            return false;
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
  });

  testWidgets('点击聚焦后 IME 组词文本进入 controller 且 composing 保留',
      (WidgetTester tester) async {
    final harness = await _pumpTitleBar(tester);

    await _focusSearchField(tester);
    expect(harness.focusNode.hasFocus, isTrue, reason: '点击后应聚焦搜索框');

    // IME 第一步：拼音进入组词区（Windows 拼音在键入 nihao 时就发这个值）。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '组词不应抛异常');
    expect(harness.controller.text, 'nihao');
    expect(
      harness.controller.value.composing,
      const TextRange(start: 0, end: 5),
      reason: 'composing 区间必须保留，否则候选框会消失',
    );
    expect(
      harness.focusNode.hasFocus,
      isTrue,
      reason: '组词期间焦点不得丢失',
    );
    // 顶栏 TextField 未被任何 onChanged/监听器重写文本：值应与 IME 下发一致。
    expect(harness.controller.value.text, 'nihao');
  });

  testWidgets('逐键组词：每一步的 composing 都完整保留', (WidgetTester tester) async {
    final harness = await _pumpTitleBar(tester);
    await _focusSearchField(tester);

    const steps = <String>['n', 'ni', 'nih', 'niha', 'nihao'];
    for (var i = 0; i < steps.length; i++) {
      final String text = steps[i];
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
          composing: TextRange(start: 0, end: text.length),
        ),
      );
      await tester.pump();

      expect(harness.controller.text, text, reason: '第 $i 步文本被改写');
      expect(
        harness.controller.value.composing,
        TextRange(start: 0, end: text.length),
        reason: '第 $i 步 composing 被清空（会打断 IME 组词）',
      );
      expect(harness.focusNode.hasFocus, isTrue, reason: '第 $i 步焦点丢失');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('组词期间父级重建（悬停 setState）不会丢 composing',
      (WidgetTester tester) async {
    final harness = await _pumpTitleBar(tester);
    await _focusSearchField(tester);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();

    // _TitleBarSearchFieldState 的 MouseRegion.onEnter/onExit 会 setState；
    // 这是顶栏在「打字过程中」唯一会触发自身重建的路径
    // （shell 未传 onQueryChanged，输入不会引起 shell setState）。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(
      find.byKey(const ValueKey('desktop_title_bar_search')),
    ));
    await tester.pump();

    expect(harness.controller.text, 'nihao');
    expect(
      harness.controller.value.composing,
      const TextRange(start: 0, end: 5),
      reason: '重建不应改写 controller，否则重建即打断组词',
    );
    expect(harness.focusNode.hasFocus, isTrue);
  });

  testWidgets('组词上屏（commit）：中文进入 controller 且 composing 清空',
      (WidgetTester tester) async {
    final harness = await _pumpTitleBar(tester);
    await _focusSearchField(tester);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();

    // IME 上屏：文本替换为「你好」，composing 归一为空。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(harness.controller.text, '你好');
    expect(harness.controller.value.composing, TextRange.empty);
    expect(harness.focusNode.hasFocus, isTrue);
  });

  testWidgets('组词期间的中文上屏 + 已有前文（混合组词）', (WidgetTester tester) async {
    final harness = await _pumpTitleBar(tester);
    await _focusSearchField(tester);

    // 先有一截上屏文字，再在其后组词（composing 区间不从头开始）。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '周杰伦',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();
    expect(harness.controller.text, '周杰伦');

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '周杰伦qingtian',
        selection: TextSelection.collapsed(offset: 10),
        composing: TextRange(start: 3, end: 10),
      ),
    );
    await tester.pump();
    expect(harness.controller.text, '周杰伦qingtian');
    expect(
      harness.controller.value.composing,
      const TextRange(start: 3, end: 10),
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '周杰伦晴天',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    expect(harness.controller.text, '周杰伦晴天');
    expect(harness.controller.value.composing, TextRange.empty);
  });

  testWidgets('传 onQueryChanged 时组词逐键回调（shell 实际没传，故不重建）',
      (WidgetTester tester) async {
    final harness = await _pumpTitleBar(tester, wiredQueryChanged: true);
    await _focusSearchField(tester);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();

    // 组词期间 onChanged 就会带拼音触发（framework 语义）：这解释为何
    // desktop_shell 刻意不传 onQueryChanged——否则每个拼音键都会 setState。
    expect(harness.queries, <String>['nihao']);
    expect(harness.controller.text, 'nihao');
    expect(
      harness.controller.value.composing,
      const TextRange(start: 0, end: 5),
    );
  });

  // ── 特征化用例（记录缺陷，修好后请翻转断言）───────────────────────────
  testWidgets('组词期间 Enter：onSubmitted 收到拼音原文，且 composing 已被 framework 清空',
      (WidgetTester tester) async {
    final harness = await _pumpTitleBar(tester);
    await _focusSearchField(tester);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    expect(harness.submitted, isEmpty, reason: 'Enter 前的组词不应已提交');

    // TextField(textInputAction: search) 收到 performAction(search) 后走
    // EditableText._finalizeEditing → onSubmitted(_value.text)。
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    // 当前行为：把**拼音原文**当查询交出去。修好后此处应为 isEmpty。
    expect(
      harness.submitted,
      <String>['nihao'],
      reason: '顶栏提交路径没有 IME 守卫，组词中的 Enter 会把拼音当查询提交',
    );

    // ★ framework 语义（editable_text.dart _finalizeEditing，本用例实测确认）：
    //   controller.clearComposing() 与 focusNode.unfocus() 都发生在
    //   onSubmitted 之前。所以 onSubmitted 里读 controller.value.composing
    //   永远是空的 —— 任何「在 onSubmitted 里判 composing」的守卫都是死代码
    //   （search_page.dart:305 的 isImeComposingActive 即属此类）。
    expect(
      harness.composingAtSubmit.single,
      isNull,
      reason: 'onSubmitted 触发时 composing 已被 framework 清空（守卫必须更早）',
    );

    // 默认 onEditingComplete 在 search action 后主动 unfocus，与 shell 的
    // _closeSearchPanel(unfocus: true) 叠加成焦点抖动。
    expect(
      harness.focusNode.hasFocus,
      isFalse,
      reason: '提交后默认 unfocus（焦点抖动来源之一）',
    );
  });

  testWidgets('onEditingComplete 取代 clearComposing：IME 守卫的可行挂点（framework 行为验证）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    final List<TextRange> composingAtEditingComplete = <TextRange>[];
    final List<TextRange> composingAtSubmitted = <TextRange>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            key: const ValueKey('probe'),
            controller: controller,
            focusNode: focusNode,
            textInputAction: TextInputAction.search,
            // 提供 onEditingComplete 后，framework 的默认
            // clearComposing()/unfocus() 分支被完全跳过。
            onEditingComplete: () {
              composingAtEditingComplete.add(controller.value.composing);
            },
            onSubmitted: (_) {
              composingAtSubmitted.add(controller.value.composing);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('probe')));
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    // ① onEditingComplete 先跑，此时 composing 还完好 —— 可以在这一层
    //    记下「这次 Enter 是不是在组词中」，供 onSubmitted / 提交路径判断。
    expect(
      composingAtEditingComplete,
      <TextRange>[const TextRange(start: 0, end: 5)],
    );
    // ② 提供了非空 onEditingComplete 时，framework 的 else 分支
    //    （clearComposing + unfocus）整段被跳过，所以 onSubmitted 里
    //    composing 依然可见 —— 这是「在 onSubmitted 里判 composing」能生效
    //    的唯一前提。
    expect(
      composingAtSubmitted,
      <TextRange>[const TextRange(start: 0, end: 5)],
    );
    // ③ 代价：框架不再自动 unfocus，焦点由业务自行管理。
    expect(
      focusNode.hasFocus,
      isTrue,
      reason: '自定义 onEditingComplete 时 framework 不再自动 unfocus',
    );
  });

  testWidgets('Escape 在搜索框内被外层 Focus 消费（不冒泡到全局快捷键）',
      (WidgetTester tester) async {
    final harness = await _pumpTitleBar(tester);
    await _focusSearchField(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(harness.escapes, 1);
    // 外层 Focus 返回 handled 不影响文本输入通道（IME 不走 key 事件）；
    // 这里只确认它没有顺手清空文本或丢焦点。
    expect(harness.controller.text, isEmpty);
    expect(harness.focusNode.hasFocus, isTrue);
  });
}

/// 测试脚手架：controller/focusNode 由测试持有（与 shell 一致，widget 不拥有）。
class _Harness {
  _Harness(this.controller, this.focusNode);

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> submitted = <String>[];
  final List<String?> composingAtSubmit = <String?>[];
  final List<String> queries = <String>[];
  final List<bool> focusChanges = <bool>[];
  int escapes = 0;
}

Future<_Harness> _pumpTitleBar(
  WidgetTester tester, {
  bool wiredQueryChanged = false,
}) async {
  // 桌面窗口尺寸：固定 420 宽搜索胶囊 + 208 品牌区 + 窗口按钮，需足够宽度。
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = TextEditingController();
  final focusNode = FocusNode();
  final harness = _Harness(controller, focusNode);
  addTearDown(controller.dispose);
  addTearDown(focusNode.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DesktopTitleBar(
          // 与 desktop_shell.dart:470-484 的实际接线保持一致：
          // 传 controller/focusNode/onSubmitted，刻意**不传** onQueryChanged。
          controller: controller,
          focusNode: focusNode,
          onSubmitted: (String value) {
            harness.submitted.add(value);
            harness.composingAtSubmit.add(
              controller.value.composing == TextRange.empty
                  ? null
                  : controller.value.composing.toString(),
            );
          },
          onQueryChanged: wiredQueryChanged
              ? (String value) => harness.queries.add(value)
              : null,
          onFocusChanged: (bool focused) => harness.focusChanges.add(focused),
          onEscape: () => harness.escapes++,
          onChromeTap: () {},
        ),
      ),
    ),
  );
  await tester.pump();
  return harness;
}

Future<void> _focusSearchField(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey('desktop_title_bar_search')),
  );
  await tester.pump();
}
