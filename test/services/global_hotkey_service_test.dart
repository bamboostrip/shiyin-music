import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/services/global_hotkey_service.dart';
import 'package:shiyin_music/ui/global_shortcuts.dart';
import 'package:shiyin_music/ui/keyboard_shortcuts.dart';

/// 假注册器：记录注册/注销动作，可按 identifier 模拟注册失败，
/// 也可手动触发已注册热键的按键回调（模拟系统热键按下）。
class _FakeRegistrar implements GlobalHotkeyRegistrar {
  _FakeRegistrar({this.failIdentifiers = const {}});

  final Set<String> failIdentifiers;
  final Map<String, KeyBinding> registered = {};
  final Map<String, VoidCallback> handlers = {};
  int unregisterAllCalls = 0;

  @override
  Future<void> register({
    required String identifier,
    required KeyBinding binding,
    required VoidCallback onKeyDown,
  }) async {
    if (failIdentifiers.contains(identifier)) {
      throw PlatformException(code: 'hotkey_conflict', message: '已被占用');
    }
    registered[identifier] = binding;
    handlers[identifier] = onKeyDown;
  }

  @override
  Future<void> unregisterAll() async {
    unregisterAllCalls++;
    registered.clear();
    handlers.clear();
  }

  /// 模拟系统热键按下。
  void press(String identifier) => handlers[identifier]!();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalShortcutController.instance.debugReset();
  });

  GlobalHotkeyService pumpService({
    _FakeRegistrar? registrar,
    Map<GlobalShortcutAction, int>? actionCalls,
  }) {
    final calls = actionCalls ?? <GlobalShortcutAction, int>{};
    final service = GlobalHotkeyService(
      controller: GlobalShortcutController.instance,
      registrar: registrar ?? _FakeRegistrar(),
      onAction: (action) => calls[action] = (calls[action] ?? 0) + 1,
    );
    return service;
  }

  group('GlobalHotkeyService', () {
    test('总开关开启：sync 注册默认表全部组合，无失败', () async {
      final registrar = _FakeRegistrar();
      final service = pumpService(registrar: registrar);

      await service.sync();

      expect(registrar.registered.length, GlobalShortcutAction.values.length);
      for (final action in GlobalShortcutAction.values) {
        final identifier = 'shiyin_global_${action.name}';
        expect(registrar.registered[identifier],
            defaultGlobalBindingsFor(action).single,
            reason: identifier);
        expect(service.errorOf(action), isNull, reason: action.name);
      }
    });

    test('热键触发：回调分发到对应动作', () async {
      final registrar = _FakeRegistrar();
      final calls = <GlobalShortcutAction, int>{};
      final service = GlobalHotkeyService(
        controller: GlobalShortcutController.instance,
        registrar: registrar,
        onAction: (action) => calls[action] = (calls[action] ?? 0) + 1,
      );
      await service.sync();

      registrar.press('shiyin_global_playPause');
      registrar.press('shiyin_global_playPause');
      registrar.press('shiyin_global_volumeUp');

      expect(calls[GlobalShortcutAction.playPause], 2);
      expect(calls[GlobalShortcutAction.volumeUp], 1);
      expect(calls.containsKey(GlobalShortcutAction.nextTrack), isFalse);
    });

    test('总开关关闭：不注册任何组合', () async {
      final registrar = _FakeRegistrar();
      final service = pumpService(registrar: registrar);
      await GlobalShortcutController.instance.setEnabled(false);

      await service.sync();

      expect(registrar.registered, isEmpty);
      expect(registrar.unregisterAllCalls, 1);
    });

    test('单个组合注册失败（被其它程序占用）：记录错误，其余照常注册',
        () async {
      final registrar = _FakeRegistrar(
        failIdentifiers: {'shiyin_global_playPause'},
      );
      final service = pumpService(registrar: registrar);

      await service.sync();

      expect(
        service.errorOf(GlobalShortcutAction.playPause),
        isNotNull,
        reason: '注册失败必须暴露给设置页标注',
      );
      for (final action in GlobalShortcutAction.values) {
        if (action == GlobalShortcutAction.playPause) continue;
        expect(service.errorOf(action), isNull, reason: action.name);
      }
      expect(registrar.registered.length, GlobalShortcutAction.values.length - 1);
    });

    test('控制器变化自动重新同步：改键后旧组合注销、新组合注册', () async {
      final registrar = _FakeRegistrar();
      final service = pumpService(registrar: registrar);
      await service.start();
      expect(registrar.unregisterAllCalls, 1);

      await GlobalShortcutController.instance.setBinding(
        GlobalShortcutAction.playPause,
        const KeyBinding(LogicalKeyboardKey.f9, control: true),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        registrar.registered['shiyin_global_playPause'],
        const KeyBinding(LogicalKeyboardKey.f9, control: true),
      );
      // 旧组合（Ctrl+Alt+P）不再出现。
      expect(
        registrar.registered.values,
        isNot(contains(defaultGlobalBindingsFor(
          GlobalShortcutAction.playPause,
        ).single)),
      );
      await service.stop();
    });

    test('start 时监听并同步；stop 注销全部并移除监听', () async {
      final registrar = _FakeRegistrar();
      final service = pumpService(registrar: registrar);

      await service.start();
      expect(registrar.registered.length, GlobalShortcutAction.values.length);

      await service.stop();
      expect(registrar.registered, isEmpty);
      expect(registrar.unregisterAllCalls, 2);

      // stop 后控制器变化不再触发注册。
      registrar.unregisterAllCalls = 0;
      await GlobalShortcutController.instance.setBinding(
        GlobalShortcutAction.nextTrack,
        const KeyBinding(LogicalKeyboardKey.f9, control: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(registrar.registered, isEmpty);
      expect(registrar.unregisterAllCalls, 0);
    });

    test('手改配置产生多绑定：每个组合独立 identifier 注册且都能触发动作', () async {
      // UI 一次只指派一个组合，但手改 prefs/旧版残留可能给一个动作多组合：
      // 同 identifier 二次注册在原生 map.insert 处不覆盖（第二组合成死键
      // 且不被注销），必须按索引给唯一 identifier。
      GlobalShortcutController.instance.debugSetBindings({
        GlobalShortcutAction.volumeUp: const [
          KeyBinding(LogicalKeyboardKey.arrowUp, control: true, alt: true),
          KeyBinding(LogicalKeyboardKey.f8, control: true, alt: true),
        ],
      });
      final registrar = _FakeRegistrar();
      final calls = <GlobalShortcutAction, int>{};
      final service = GlobalHotkeyService(
        controller: GlobalShortcutController.instance,
        registrar: registrar,
        onAction: (action) => calls[action] = (calls[action] ?? 0) + 1,
      );

      await service.sync();

      // 默认 5 个动作 + volumeUp 的第二个组合 = 6 条独立注册。
      expect(
        registrar.registered.length,
        GlobalShortcutAction.values.length + 1,
      );
      expect(registrar.registered.containsKey('shiyin_global_volumeUp'), isTrue);
      expect(
        registrar.registered.containsKey('shiyin_global_volumeUp_1'),
        isTrue,
      );

      // 两个组合都分发到同一动作。
      registrar.press('shiyin_global_volumeUp');
      registrar.press('shiyin_global_volumeUp_1');
      expect(calls[GlobalShortcutAction.volumeUp], 2);
    });

    test('同步失败状态变化时通知监听者（设置页据此刷新标注）', () async {
      var notifications = 0;
      final registrar = _FakeRegistrar(
        failIdentifiers: {'shiyin_global_playPause'},
      );
      final service = pumpService(registrar: registrar);
      service.addListener(() => notifications++);

      await service.sync();
      expect(notifications, greaterThan(0));
    });
  });

  group('hotKeyOf（KeyBinding → hotkey_manager HotKey 转换）', () {
    test('修饰键与主键逐项映射，identifier 透传', () {
      final hotKey = hotKeyOf(
        const KeyBinding(LogicalKeyboardKey.keyP, control: true, alt: true),
        identifier: 'test_id',
      );

      expect(hotKey.identifier, 'test_id');
      expect(hotKey.logicalKey, LogicalKeyboardKey.keyP);
      expect(hotKey.modifiers, containsAll([HotKeyModifier.control, HotKeyModifier.alt]));
      expect(hotKey.modifiers!.length, 2, reason: '不含未按下的修饰键');
      expect(hotKey.scope, HotKeyScope.system);
    });

    test('无修饰键组合也能构造（校验在上层保留规则）', () {
      final hotKey = hotKeyOf(
        const KeyBinding(LogicalKeyboardKey.f8),
        identifier: 'bare',
      );
      expect(hotKey.logicalKey, LogicalKeyboardKey.f8);
      expect(hotKey.modifiers, isEmpty);
    });
  });
}
