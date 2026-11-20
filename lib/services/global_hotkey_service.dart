import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shiyin_music/ui/global_shortcuts.dart';
import 'package:shiyin_music/ui/keyboard_shortcuts.dart';

/// 热键注册器的最小接口：生产环境包装 hotkey_manager，测试注入假实现，
/// 服务层逻辑不依赖插件本体。
abstract class GlobalHotkeyRegistrar {
  Future<void> register({
    required String identifier,
    required KeyBinding binding,
    required VoidCallback onKeyDown,
  });

  Future<void> unregisterAll();
}

/// [GlobalHotkeyRegistrar] 的生产实现：包装 hotkey_manager（Windows 走
/// RegisterHotKey，Linux 走 X11；XWayland 可用，原生 Wayland 无 portal
/// 时不支持——注册失败的组合会作为错误暴露到设置页，不阻断其它组合）。
class HotkeyManagerRegistrar implements GlobalHotkeyRegistrar {
  const HotkeyManagerRegistrar();

  @override
  Future<void> register({
    required String identifier,
    required KeyBinding binding,
    required VoidCallback onKeyDown,
  }) {
    return hotKeyManager.register(
      hotKeyOf(binding, identifier: identifier),
      // Windows/X11 只上报 keyDown，动作全部挂在按下瞬间。
      keyDownHandler: (_) => onKeyDown(),
    );
  }

  @override
  Future<void> unregisterAll() => hotKeyManager.unregisterAll();
}

/// [KeyBinding] → hotkey_manager [HotKey] 的纯转换。
///
/// identifier 必须稳定（按动作命名）：热键注册的生命周期是「全注销再全
/// 注册」，稳定 id 便于日志排查与平台侧幂等。
HotKey hotKeyOf(KeyBinding binding, {required String identifier}) {
  return HotKey(
    identifier: identifier,
    key: binding.key,
    modifiers: [
      if (binding.control) HotKeyModifier.control,
      if (binding.shift) HotKeyModifier.shift,
      if (binding.alt) HotKeyModifier.alt,
      if (binding.meta) HotKeyModifier.meta,
    ],
    scope: HotKeyScope.system,
  );
}

/// 全局热键服务：监听 [GlobalShortcutController]，把当前生效的键位表
/// 同步到系统（改键/开关/恢复默认后立即重注册）。
///
/// 同步策略是「先全注销、再全注册」：简单且幂等——本应用是
/// hotkey_manager 的唯一使用者，不存在需要保留的第三方注册。
/// 单个组合注册失败（被其它程序占用/平台不支持）只记录到
/// [errorOf] 暴露给设置页标注，绝不影响其它组合与应用本身。
class GlobalHotkeyService extends ChangeNotifier {
  GlobalHotkeyService({
    required GlobalShortcutController controller,
    required GlobalHotkeyRegistrar registrar,
    required void Function(GlobalShortcutAction action) onAction,
  }) : _controller = controller,
       _registrar = registrar,
       _onAction = onAction;

  final GlobalShortcutController _controller;
  final GlobalHotkeyRegistrar _registrar;
  final void Function(GlobalShortcutAction action) _onAction;

  /// 应用级单例：main 装配后赋值，设置页从这里读注册失败状态。
  static GlobalHotkeyService? instance;

  static String identifierOf(GlobalShortcutAction action) =>
      'shiyin_global_${action.name}';

  final Map<GlobalShortcutAction, Object> _errors = {};
  bool _started = false;
  bool _syncing = false;
  bool _dirty = false;

  /// 该动作当前热键的注册错误；null = 注册成功（或尚未同步）。
  Object? errorOf(GlobalShortcutAction action) => _errors[action];

  /// 是否有任一组合注册失败（设置页顶部提醒用）。
  bool get hasErrors => _errors.isNotEmpty;

  /// 开始监听控制器并执行首次同步。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _controller.addListener(_onControllerChanged);
    await sync();
  }

  /// 停止监听并注销全部系统热键。
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _controller.removeListener(_onControllerChanged);
    _errors.clear();
    await _registrar.unregisterAll();
    notifyListeners();
  }

  void _onControllerChanged() {
    // 控制器通知可能发生在异步写盘中间，sync 内部有脏标记串行化。
    unawaited(sync());
  }

  /// 把控制器当前状态（开关 + 键位表）同步到系统热键注册。
  Future<void> sync() async {
    if (_syncing) {
      _dirty = true;
      return;
    }
    _syncing = true;
    try {
      await _doSync();
      // 同步期间又有变化：再跑一轮，直到追上最新状态。
      while (_dirty) {
        _dirty = false;
        await _doSync();
      }
    } finally {
      _syncing = false;
    }
    notifyListeners();
  }

  Future<void> _doSync() async {
    _errors.clear();
    await _registrar.unregisterAll();
    if (!_controller.enabled) return;
    for (final action in GlobalShortcutAction.values) {
      for (final binding in _controller.bindingsOf(action)) {
        try {
          await _registrar.register(
            identifier: identifierOf(action),
            binding: binding,
            onKeyDown: () => _onAction(action),
          );
        } catch (error) {
          debugPrint('[时音][global-shortcuts] 注册失败 ${binding.label}: $error');
          _errors[action] = error;
        }
      }
    }
  }
}
