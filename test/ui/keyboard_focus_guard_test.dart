import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/keyboard_focus_guard.dart';

class _CountIntent extends Intent {
  const _CountIntent();
}

void main() {
  group('IME 守卫（isImeComposingActive）', () {
    test('组词中（composing 非空）→ 忽略提交', () {
      const value = TextEditingValue(
        text: '音乐',
        composing: TextRange(start: 0, end: 2),
      );
      expect(isImeComposingActive(value), isTrue);
    });

    test('非组词（composing 为空）→ 正常提交', () {
      const value = TextEditingValue(
        text: '音乐',
        composing: TextRange.empty,
      );
      expect(isImeComposingActive(value), isFalse);
    });

    test('空文本同样安全', () {
      expect(isImeComposingActive(const TextEditingValue()), isFalse);
    });
  });

  group('GuardedCallbackAction 按键消费语义', () {
    const intent = _CountIntent();

    test('桌面端守卫命中 → 放行按键（ignored），handler 不执行', () {
      var handled = false;
      final action = GuardedCallbackAction<_CountIntent>(
        desktop: true,
        guard: (_) => true,
        onInvoke: (_) {
          handled = true;
          return null;
        },
      );
      final result = action.invoke(intent);
      expect(handled, isFalse);
      expect(action.toKeyEventResult(intent, result), KeyEventResult.ignored);
    });

    test('桌面端守卫未命中 → 执行 handler 并消费按键', () {
      var handled = false;
      final action = GuardedCallbackAction<_CountIntent>(
        desktop: true,
        guard: (_) => false,
        onInvoke: (_) {
          handled = true;
          return null;
        },
      );
      final result = action.invoke(intent);
      expect(handled, isTrue);
      expect(action.toKeyEventResult(intent, result), KeyEventResult.handled);
    });

    test('移动端守卫命中 → 跳过 handler 但仍消费按键（历史行为）', () {
      var handled = false;
      final action = GuardedCallbackAction<_CountIntent>(
        desktop: false,
        guard: (_) => true,
        onInvoke: (_) {
          handled = true;
          return null;
        },
      );
      final result = action.invoke(intent);
      expect(handled, isFalse);
      expect(action.toKeyEventResult(intent, result), KeyEventResult.handled);
    });

    testWidgets('放行机制端到端：守卫命中后空格仍激活焦点所在 InkWell', (tester) async {
      var activated = false;
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.space): _CountIntent(),
              },
              child: Actions(
                actions: {
                  _CountIntent: GuardedCallbackAction<_CountIntent>(
                    desktop: true,
                    guard: (_) => true, // 模拟焦点在交互控件内：全局快捷键退让
                    onInvoke: (_) => null,
                  ),
                },
                child: Center(
                  child: InkWell(
                    focusNode: focusNode,
                    autofocus: true,
                    onTap: () => activated = true,
                    child: const SizedBox(width: 100, height: 40),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(activated, isTrue);
    });
  });

  group('交互控件/可滚动区域守卫', () {
    testWidgets('焦点在 TextField → 交互控件守卫命中、不退让滚动', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: const [
                TextField(autofocus: true),
                SizedBox(height: 800),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final context = FocusManager.instance.primaryFocus!.context!;
      expect(isContextInsideInteractiveControl(context), isTrue);
      expect(isContextInsideScrollableRegion(context), isFalse);
    });

    testWidgets('焦点在 ListView 内的普通 Focus 节点 → 空格退让滚动', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(
                children: [
                  Focus(
                    focusNode: node,
                    autofocus: true,
                    child: const SizedBox(height: 100),
                  ),
                  const SizedBox(height: 900),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final context = FocusManager.instance.primaryFocus!.context!;
      expect(isContextInsideInteractiveControl(context), isFalse);
      expect(isContextInsideScrollableRegion(context), isTrue);
    });

    testWidgets('焦点在 ListView 内的 InkWell → 交互控件优先，不退让滚动', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(
                children: [
                  InkWell(
                    focusNode: node,
                    autofocus: true,
                    onTap: () {},
                    child: const SizedBox(height: 100),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final context = FocusManager.instance.primaryFocus!.context!;
      expect(isContextInsideInteractiveControl(context), isTrue);
      expect(isContextInsideScrollableRegion(context), isFalse);
    });

    testWidgets('焦点在滚动区域外 → 不退让', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              focusNode: node,
              autofocus: true,
              child: const SizedBox(height: 100),
            ),
          ),
        ),
      );
      await tester.pump();
      final context = FocusManager.instance.primaryFocus!.context!;
      expect(isContextInsideScrollableRegion(context), isFalse);
    });

    test('isFocusInside* 无焦点宿主时安全返回不抛异常', () {
      expect(() => isFocusInsideScrollableRegion(), returnsNormally);
      expect(() => isFocusInsideInteractiveControl(), returnsNormally);
    });

    testWidgets('scrollFocusedRegionByPage：向下翻一页（约一个视口）并可翻回', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(
                children: [
                  Focus(
                    focusNode: node,
                    autofocus: true,
                    child: const SizedBox(height: 100),
                  ),
                  const SizedBox(height: 900),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(scrollFocusedRegionByPage(forward: true), isTrue);
      await tester.pumpAndSettle();
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(position.pixels, closeTo(300, 0.5));

      expect(scrollFocusedRegionByPage(forward: false), isTrue);
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(0, 0.5));
    });

    testWidgets('scrollFocusedRegionByPage：无可滚动范围时返回 false', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(
                children: [
                  Focus(
                    focusNode: node,
                    autofocus: true,
                    child: const SizedBox(height: 100),
                  ),
                  const SizedBox(height: 200),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(scrollFocusedRegionByPage(forward: true), isFalse);
    });

    testWidgets('scrollFocusedRegionByPage：焦点在交互控件内不滚动', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(
                children: [
                  const TextField(autofocus: true),
                  const SizedBox(height: 900),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(scrollFocusedRegionByPage(forward: true), isFalse);
    });
  });
}
