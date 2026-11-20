import 'dart:convert';

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

    test('抢占同一组合：被抢的动作置为「未设置」，绝不回落默认键', () async {
      final controller = ShortcutController.instance;
      // 把「快进」改成空格——空格原本属于「播放/暂停」。
      const binding = KeyBinding(LogicalKeyboardKey.space);
      expect(await controller.setBinding(AppShortcutAction.seekForward, binding),
          isTrue);

      expect(controller.bindingsOf(AppShortcutAction.seekForward), [binding]);
      // 关键：播放/暂停不能「回落默认空格」，否则两条记录共用一键，
      // Shortcuts 表里后者覆盖前者 → 播放/暂停静默失效。
      expect(controller.bindingsOf(AppShortcutAction.playPause), isEmpty);
      expect(controller.activatorsOf(AppShortcutAction.playPause), isEmpty);

      // 全表不允许出现重复组合。
      final seen = <KeyBinding, List<AppShortcutAction>>{};
      for (final action in AppShortcutAction.values) {
        for (final item in controller.bindingsOf(action)) {
          seen.putIfAbsent(item, () => []).add(action);
        }
      }
      expect(
        seen.entries.where((entry) => entry.value.length > 1),
        isEmpty,
        reason: '同一组合只能属于一个动作',
      );
    });

    test('「未设置」会持久化：重启读取后不会被默认键补回来', () async {
      final controller = ShortcutController.instance;
      await controller.setBinding(
        AppShortcutAction.volumeUp,
        const KeyBinding(LogicalKeyboardKey.space),
      );
      expect(controller.bindingsOf(AppShortcutAction.playPause), isEmpty);

      // 模拟重启：清内存态后重新从 prefs 解码。
      controller.debugReset();
      await controller.load();
      expect(controller.bindingsOf(AppShortcutAction.playPause), isEmpty);
      expect(
        controller.bindingsOf(AppShortcutAction.volumeUp),
        [const KeyBinding(LogicalKeyboardKey.space)],
      );
    });

    test('保留键（回车/ Ctrl+F / Esc / Tab）不允许改绑', () async {
      final controller = ShortcutController.instance;
      for (final binding in const [
        KeyBinding(LogicalKeyboardKey.enter),
        KeyBinding(LogicalKeyboardKey.keyF, control: true),
        KeyBinding(LogicalKeyboardKey.escape),
        KeyBinding(LogicalKeyboardKey.tab),
        KeyBinding(LogicalKeyboardKey.digit3, control: true),
      ]) {
        expect(reservedBindingReason(binding), isNotNull,
            reason: binding.label);
        expect(
          await controller.setBinding(AppShortcutAction.playPause, binding),
          isFalse,
          reason: binding.label,
        );
        expect(
          controller.bindingsOf(AppShortcutAction.playPause),
          defaultBindingsFor(AppShortcutAction.playPause),
          reason: '被拒绝后键位不应变化（${binding.label}）',
        );
      }
    });

    test('保留键只拦精确组合：带修饰键的回车/Esc/Tab 可改绑', () async {
      final controller = ShortcutController.instance;

      // 焦点系统/固定表占用的是精确组合：裸 Esc/Tab/回车，以及
      // Shift+Tab（框架的反向焦点遍历）——这些仍然拒绝。
      for (final binding in const [
        KeyBinding(LogicalKeyboardKey.escape),
        KeyBinding(LogicalKeyboardKey.tab),
        KeyBinding(LogicalKeyboardKey.tab, shift: true),
        KeyBinding(LogicalKeyboardKey.enter),
      ]) {
        expect(reservedBindingReason(binding), isNotNull, reason: binding.label);
      }

      // 其余修饰组合（Ctrl/Alt/Shift 搭配回车、Esc、Tab）并未被任何
      // 固定表占用，是空闲键位；一刀切拒绝会把它们挡在门外，且提示
      // 文案（如「回车用于打开播放页」）对 Ctrl+回车这种组合是误导。
      for (final binding in const [
        KeyBinding(LogicalKeyboardKey.enter, control: true),
        KeyBinding(LogicalKeyboardKey.numpadEnter, alt: true),
        KeyBinding(LogicalKeyboardKey.escape, shift: true),
        KeyBinding(LogicalKeyboardKey.tab, control: true),
      ]) {
        expect(reservedBindingReason(binding), isNull, reason: binding.label);
        expect(
          await controller.setBinding(AppShortcutAction.playPause, binding),
          isTrue,
          reason: binding.label,
        );
      }
    });

    test('手改配置里同一键位重复出现：先到先得，不产生两个动作共用', () async {
      SharedPreferences.setMockInitialValues({
        ShortcutController.prefsKey: jsonEncode({
          'playPause': ['0000:32'],
          'seekForward': ['0000:32'], // 与 playPause 撞车
        }),
      });
      final controller = ShortcutController.instance;
      controller.debugReset();
      await controller.load();

      expect(
        controller.bindingsOf(AppShortcutAction.playPause),
        [const KeyBinding(LogicalKeyboardKey.space)],
      );
      expect(controller.bindingsOf(AppShortcutAction.seekForward), isEmpty);
    });

    test('整串配置是坏 JSON/非对象时回退默认表（不能让播放键全灭）', () async {
      // 单条记录脏（tryDecode 返回 null）已有覆盖；这里钉的是整串 blob
      // 级别的损坏：坏 JSON 抛 FormatException、合法 JSON 但不是对象、
      // 显式 null——都必须回退默认表而不是把所有动作变成「未设置」。
      for (final raw in ['{oops', '[1,2]', '"配置"', 'null']) {
        SharedPreferences.setMockInitialValues({
          ShortcutController.prefsKey: raw,
        });
        ShortcutController.instance.debugReset();
        await ShortcutController.instance.load();

        for (final action in AppShortcutAction.values) {
          expect(
            ShortcutController.instance.bindingsOf(action),
            defaultBindingsFor(action),
            reason: '$action ← prefs = $raw',
          );
        }
      }
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

    testWidgets('「恢复默认」需二次确认，取消不丢配置', (tester) async {
      ShortcutController.instance.debugSetBindings({
        AppShortcutAction.playPause: const [
          KeyBinding(LogicalKeyboardKey.keyK, control: true),
        ],
      });
      await pumpPage(tester);

      await tester.tap(find.byKey(const ValueKey('shortcut_reset_all')));
      await tester.pumpAndSettle();
      expect(find.text('恢复默认快捷键？'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shortcut_reset_cancel')));
      await tester.pumpAndSettle();
      expect(
        ShortcutController.instance.bindingsOf(AppShortcutAction.playPause),
        [const KeyBinding(LogicalKeyboardKey.keyK, control: true)],
      );

      await tester.tap(find.byKey(const ValueKey('shortcut_reset_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shortcut_reset_confirm')));
      await tester.pumpAndSettle();
      expect(
        ShortcutController.instance.bindingsOf(AppShortcutAction.playPause),
        defaultBindingsFor(AppShortcutAction.playPause),
      );
    });

    testWidgets('桌面最小窗口宽（360）下不溢出', (tester) async {
      // 长标签 + 「未设置」+ 恢复 + 修改 同排时曾溢出 108px；
      // 窄窗改为两行布局，键位与操作折行。
      ShortcutController.instance.debugSetBindings({
        AppShortcutAction.playPause: const [],
        AppShortcutAction.seekForward: const [
          KeyBinding(
            LogicalKeyboardKey.arrowRight,
            control: true,
            shift: true,
            alt: true,
          ),
        ],
      });
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: KeyboardShortcutsPage()),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('未设置'), findsOneWidget);
    });

    testWidgets('被抢走的动作显示「未设置」（不会偷偷回落默认键）', (tester) async {
      ShortcutController.instance.debugSetBindings({
        AppShortcutAction.playPause: const [],
        AppShortcutAction.seekForward: const [
          KeyBinding(LogicalKeyboardKey.space),
        ],
      });
      await pumpPage(tester);

      expect(find.text('未设置'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('shortcut_chip_playPause_0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('shortcut_chip_seekForward_0')),
        findsOneWidget,
      );
    });

    testWidgets('改过键的行出现「恢复默认键位」，点击即找回', (tester) async {
      ShortcutController.instance.debugSetBindings({
        AppShortcutAction.playPause: const [],
        AppShortcutAction.seekForward: const [
          KeyBinding(LogicalKeyboardKey.space),
        ],
      });
      await pumpPage(tester);

      expect(find.text('未设置'), findsOneWidget);
      // 没改过的行不该有恢复入口，避免满屏图标。
      expect(
        find.byKey(const ValueKey('shortcut_reset_seekBackward')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('shortcut_reset_playPause')));
      await tester.pumpAndSettle();

      final controller = ShortcutController.instance;
      expect(
        controller.bindingsOf(AppShortcutAction.playPause),
        defaultBindingsFor(AppShortcutAction.playPause),
      );
      // 空格被要回来，快进让位（一个组合仍只属于一个动作）。
      expect(controller.bindingsOf(AppShortcutAction.seekForward), isEmpty);
      expect(find.text('未设置'), findsWidgets);
    });

    testWidgets('录制到系统保留键时禁用保存并说明原因', (tester) async {
      await pumpPage(tester);
      await tester.tap(
        find.byKey(const ValueKey('shortcut_edit_seekBackward')),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.textContaining('回车用于打开播放页'), findsOneWidget);
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('shortcut_capture_save')),
      );
      expect(save.onPressed, isNull);
      // 键位不受影响
      expect(
        ShortcutController.instance.bindingsOf(AppShortcutAction.seekBackward),
        defaultBindingsFor(AppShortcutAction.seekBackward),
      );
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
