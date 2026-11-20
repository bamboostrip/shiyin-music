import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/ui/keyboard_shortcuts.dart';
import 'package:shiyin_music/ui/pages/keyboard_shortcuts_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ShortcutController.instance.debugReset();
  });

  group('KeyBinding 编解码与展示', () {
    test('编码往返一致', () {
      const binding = KeyBinding(
        LogicalKeyboardKey.arrowLeft,
        control: true,
        shift: true,
      );
      final decoded = KeyBinding.tryDecode(binding.encode());
      expect(decoded, binding);
    });

    test('脏数据返回 null（不让设置页崩）', () {
      expect(KeyBinding.tryDecode(''), isNull);
      expect(KeyBinding.tryDecode('nope'), isNull);
      expect(KeyBinding.tryDecode('10:abc'), isNull);
      expect(KeyBinding.tryDecode('1234:32'), isNull);
    });

    test('展示文本按 Ctrl/Shift/Alt/Win 顺序拼接，方向键与空格用符号', () {
      expect(const KeyBinding(LogicalKeyboardKey.arrowLeft).label, '←');
      expect(
        const KeyBinding(
          LogicalKeyboardKey.arrowRight,
          control: true,
          shift: true,
        ).label,
        'Ctrl + Shift + →',
      );
      expect(const KeyBinding(LogicalKeyboardKey.space).label, '空格');
    });
  });

  group('ShortcutController（issue #31 改键）', () {
    // SingleActivator 没实现 ==，只能逐字段比对（const 实例才靠 canonicalize）。
    void expectActivator(
      SingleActivator actual,
      LogicalKeyboardKey trigger, {
      bool control = false,
      bool includeRepeats = true,
    }) {
      expect(actual.trigger, trigger);
      expect(actual.control, control);
      expect(actual.includeRepeats, includeRepeats);
    }

    test('默认表与 appShortcutActivators 一致（空格排除按住重复）', () {
      final controller = ShortcutController.instance;
      expectActivator(
        controller.activatorsOf(AppShortcutAction.playPause).single,
        LogicalKeyboardKey.space,
        includeRepeats: false,
      );
      expectActivator(
        controller.activatorsOf(AppShortcutAction.previousTrack).single,
        LogicalKeyboardKey.arrowLeft,
        control: true,
      );
      expect(
        controller.bindingsOf(AppShortcutAction.playPause).single.label,
        '空格',
      );
    });

    test('改键：立刻生效并写盘', () async {
      final controller = ShortcutController.instance;
      const binding = KeyBinding(LogicalKeyboardKey.keyK, control: true);
      await controller.setBinding(AppShortcutAction.playPause, binding);

      expect(controller.bindingsOf(AppShortcutAction.playPause), [binding]);
      expectActivator(
        controller.activatorsOf(AppShortcutAction.playPause).single,
        LogicalKeyboardKey.keyK,
        control: true,
        includeRepeats: false,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ShortcutController.prefsKey), contains('1000:'));
    });

    test('改键抢走同一个组合时，原动作回落默认键位（不会两个动作共用）', () async {
      final controller = ShortcutController.instance;
      const binding = KeyBinding(LogicalKeyboardKey.keyK, control: true);
      await controller.setBinding(AppShortcutAction.previousTrack, binding);
      expect(
        controller.conflictOf(binding, ignore: AppShortcutAction.previousTrack),
        isNull,
      );

      // 再把「下一首」也改成 Ctrl+K：上一首被摘掉后应回落默认 Ctrl+←，
      // 保证每个动作始终有一个可用键。
      await controller.setBinding(AppShortcutAction.nextTrack, binding);
      expect(controller.bindingsOf(AppShortcutAction.nextTrack), [binding]);
      expect(
        controller.bindingsOf(AppShortcutAction.previousTrack),
        defaultBindingsFor(AppShortcutAction.previousTrack),
      );
    });

    test('恢复默认', () async {
      final controller = ShortcutController.instance;
      await controller.setBinding(
        AppShortcutAction.volumeUp,
        const KeyBinding(LogicalKeyboardKey.f8),
      );
      await controller.resetAll();
      expect(
        controller.bindingsOf(AppShortcutAction.volumeUp),
        defaultBindingsFor(AppShortcutAction.volumeUp),
      );
    });
  });

  group('键盘快捷键设置页', () {
    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: KeyboardShortcutsPage()),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('列出全部播放动作与当前键位', (tester) async {
      await pumpPage(tester);
      for (final action in AppShortcutAction.values) {
        expect(
          find.byKey(ValueKey('shortcut_row_${action.name}')),
          findsOneWidget,
          reason: action.name,
        );
      }
      expect(find.text('播放 / 暂停'), findsOneWidget);
      expect(find.text('空格'), findsOneWidget);
      // 固定快捷键也在清单里（此前只写在更新日志里）。
      expect(find.text('Ctrl + F'), findsOneWidget);
      expect(find.text('Ctrl + 1 ~ 6'), findsOneWidget);
    });

    testWidgets('录制新键位并保存后立即生效', (tester) async {
      await pumpPage(tester);

      await tester.tap(
        find.byKey(const ValueKey('shortcut_edit_playPause')),
      );
      await tester.pumpAndSettle();
      expect(find.text('修改「播放 / 暂停」'), findsOneWidget);

      // Ctrl+K：先按修饰键、再按主键，与真实用户操作一致。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('shortcut_capture_label')),
        findsOneWidget,
      );
      expect(find.text('Ctrl + K'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('shortcut_capture_save')));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(
        ShortcutController.instance.bindingsOf(AppShortcutAction.playPause),
        [const KeyBinding(LogicalKeyboardKey.keyK, control: true)],
      );
    });

    testWidgets('Esc 取消录制，键位保持不变', (tester) async {
      await pumpPage(tester);
      await tester.tap(
        find.byKey(const ValueKey('shortcut_edit_seekForward')),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('修改「快进 5 秒」'), findsNothing);
      expect(
        ShortcutController.instance.bindingsOf(AppShortcutAction.seekForward),
        defaultBindingsFor(AppShortcutAction.seekForward),
      );
    });
  });
}
