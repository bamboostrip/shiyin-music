import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/services/global_hotkey_service.dart';
import 'package:shiyin_music/ui/global_shortcuts.dart';
import 'package:shiyin_music/ui/keyboard_shortcuts.dart';
import 'package:shiyin_music/ui/pages/keyboard_shortcuts_page.dart';

/// 页面测试用的假注册器：可按 identifier 模拟注册失败。
class _FakeRegistrar implements GlobalHotkeyRegistrar {
  _FakeRegistrar({this.failIdentifiers = const {}});

  final Set<String> failIdentifiers;

  @override
  Future<void> register({
    required String identifier,
    required KeyBinding binding,
    required VoidCallback onKeyDown,
  }) async {
    if (failIdentifiers.contains(identifier)) {
      throw PlatformException(code: 'hotkey_conflict', message: '已被占用');
    }
  }

  @override
  Future<void> unregisterAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ShortcutController.instance.debugReset();
    GlobalShortcutController.instance.debugReset();
    GlobalHotkeyService.instance = null;
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1200, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: KeyboardShortcutsPage()));
    await tester.pumpAndSettle();
  }

  group('键盘快捷键页 · 全局分节', () {
    testWidgets('默认开启，五行动作与默认键位齐全', (tester) async {
      await pumpPage(tester);

      final sw = tester.widget<Switch>(
        find.byKey(const ValueKey('global_shortcut_enabled_switch')),
      );
      expect(sw.value, isTrue, reason: '总开关默认开启');

      for (final action in GlobalShortcutAction.values) {
        expect(
          find.byKey(ValueKey('global_shortcut_row_${action.name}')),
          findsOneWidget,
          reason: action.name,
        );
      }
      expect(find.text('Ctrl + Alt + P'), findsOneWidget);
    });

    testWidgets('关闭总开关：写盘、分节进入停用态、改键入口不可用', (tester) async {
      await pumpPage(tester);

      await tester.tap(
        find.byKey(const ValueKey('global_shortcut_enabled_switch')),
      );
      await tester.pumpAndSettle();

      expect(GlobalShortcutController.instance.enabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(GlobalShortcutController.enabledPrefsKey), isFalse);
      expect(find.textContaining('已关闭'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('global_shortcut_edit_playPause')),
        findsNothing,
        reason: '停用态不提供改键入口',
      );
    });

    testWidgets('录制全局键：裸键被保留规则拒绝；Ctrl+Alt+K 可保存', (tester) async {
      await pumpPage(tester);

      await tester.tap(
        find.byKey(const ValueKey('global_shortcut_edit_playPause')),
      );
      await tester.pumpAndSettle();

      // 裸键：全局热键必须带 Ctrl/Alt。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      expect(find.textContaining('必须带 Ctrl 或 Alt'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('shortcut_capture_save')),
            )
            .onPressed,
        isNull,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);

      // Ctrl+Alt+K：合法组合。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(find.text('Ctrl + Alt + K'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('shortcut_capture_save')));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(
        GlobalShortcutController.instance.bindingsOf(
          GlobalShortcutAction.playPause,
        ),
        const [
          KeyBinding(LogicalKeyboardKey.keyK, control: true, alt: true),
        ],
      );
    });

    testWidgets('注册失败的组合在行内标注，成功的行不标', (tester) async {
      final service = GlobalHotkeyService(
        controller: GlobalShortcutController.instance,
        registrar: _FakeRegistrar(
          failIdentifiers: {'shiyin_global_playPause'},
        ),
        onAction: (_) {},
      );
      GlobalHotkeyService.instance = service;
      await service.sync();

      await pumpPage(tester);

      expect(
        find.byKey(const ValueKey('global_shortcut_error_playPause')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('global_shortcut_error_nextTrack')),
        findsNothing,
      );
    });

    testWidgets('AppBar「恢复默认」同时重置全局键位，但不动总开关', (tester) async {
      await GlobalShortcutController.instance.setBinding(
        GlobalShortcutAction.playPause,
        const KeyBinding(LogicalKeyboardKey.f9, control: true),
      );
      await GlobalShortcutController.instance.setEnabled(false);

      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('shortcut_reset_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shortcut_reset_confirm')));
      await tester.pumpAndSettle();

      expect(
        GlobalShortcutController.instance.bindingsOf(
          GlobalShortcutAction.playPause,
        ),
        defaultGlobalBindingsFor(GlobalShortcutAction.playPause),
      );
      expect(
        GlobalShortcutController.instance.enabled,
        isFalse,
        reason: '恢复默认只还原键位，不动用户对总开关的表态',
      );
    });

    testWidgets('横幅不再声称全局热键尚未支持', (tester) async {
      await pumpPage(tester);
      expect(find.textContaining('尚未支持'), findsNothing);
      expect(find.textContaining('全局'), findsWidgets);
    });

    testWidgets('桌面最小窗口宽（360）下含全局分节不溢出', (tester) async {
      await pumpPage(tester, size: const Size(360, 900));
      expect(tester.takeException(), isNull);
    });
  });
}
