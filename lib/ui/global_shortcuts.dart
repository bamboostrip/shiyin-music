import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/ui/keyboard_shortcuts.dart';

/// 全局（系统级）热键承载的动作（issue #31 的「可修改的全局快捷键」）。
///
/// 应用内 [ShortcutController] 的子集：全局 seek 无场景，沿用 QQ 音乐的
/// 五行——播放/暂停、上一首、下一首、音量±。
enum GlobalShortcutAction {
  playPause,
  previousTrack,
  nextTrack,
  volumeUp,
  volumeDown,
}

/// 动作在设置页里的展示文案。
extension GlobalShortcutActionLabel on GlobalShortcutAction {
  String get label => switch (this) {
    GlobalShortcutAction.playPause => '播放 / 暂停',
    GlobalShortcutAction.previousTrack => '上一首',
    GlobalShortcutAction.nextTrack => '下一首',
    GlobalShortcutAction.volumeUp => '音量 +5%',
    GlobalShortcutAction.volumeDown => '音量 −5%',
  };
}

/// 全局默认键位：QQ 音乐式 Ctrl+Alt 双修饰低冲突组合。
///
/// 单 Ctrl/Alt 组合（如 Ctrl+C）容易与其它软件冲突，默认键统一带上
/// Ctrl+Alt；用户改键时可以只留一个修饰键（保留规则只拦危险组合）。
List<KeyBinding> defaultGlobalBindingsFor(GlobalShortcutAction action) {
  return switch (action) {
    GlobalShortcutAction.playPause => const [
      KeyBinding(LogicalKeyboardKey.keyP, control: true, alt: true),
    ],
    GlobalShortcutAction.previousTrack => const [
      KeyBinding(LogicalKeyboardKey.arrowLeft, control: true, alt: true),
    ],
    GlobalShortcutAction.nextTrack => const [
      KeyBinding(LogicalKeyboardKey.arrowRight, control: true, alt: true),
    ],
    GlobalShortcutAction.volumeUp => const [
      KeyBinding(LogicalKeyboardKey.arrowUp, control: true, alt: true),
    ],
    GlobalShortcutAction.volumeDown => const [
      KeyBinding(LogicalKeyboardKey.arrowDown, control: true, alt: true),
    ],
  };
}

/// 全局热键的保留规则：**必须**有 Ctrl 或 Alt 参与修饰。
///
/// 与应用内 [reservedBindingReason] 的语义不同——全局热键是系统级拦截：
/// - 裸键会把该键在全系统的输入都吞掉（比如绑 P 之后哪里都打不出 p）；
/// - 仅 Shift 修饰仍是打字内容（Shift+P = 大写 P），同样拦截输入；
/// - 仅 Win/Meta 修饰的组合大多被系统占用，注册了也收不到。
/// 满足「Ctrl 或 Alt 任一参与」即放行；是否与其它软件冲突交给注册结果
/// 反馈（注册失败会在设置页标注并提示换键）。
String? globalReservedBindingReason(KeyBinding binding) {
  if (binding.control || binding.alt) return null;
  if (binding.shift && !binding.meta) return '仅 Shift 修饰是输入大写字母，会拦截全系统打字';
  if (binding.meta) return 'Win/Meta 组合大多被系统占用，注册了也收不到';
  return '全局快捷键必须带 Ctrl 或 Alt，否则会拦截全系统打字';
}

/// 全局（系统级）快捷键的可改配置（issue #31）。
///
/// 与应用内 [ShortcutController] 平行的第二张表：系统级热键经
/// hotkey_manager（Windows RegisterHotKey / Linux X11）注册，窗口
/// 失焦/最小化也能控制播放。默认键位与抢占/脏数据语义与应用内表一致
/// （被抢动作置「未设置」、不回落默认键；脏数据一律回退默认表）。
///
/// 总开关默认开启（QQ 音乐等国产播放器同款做法，issue 作者的期望也是
/// 「开箱即用的全局控制」）；注册失败不阻断任何流程，仅在设置页标注。
class GlobalShortcutController extends ChangeNotifier {
  GlobalShortcutController._();

  static final GlobalShortcutController instance = GlobalShortcutController._();

  /// bindings 的 prefs 键：JSON `{"playPause":["1010:41"], ...}`。
  static const String bindingsPrefsKey =
      'settings.global_shortcut_bindings.v1';

  /// 总开关的 prefs 键；**缺失视为开**（默认开启）。
  static const String enabledPrefsKey = 'settings.global_shortcuts_enabled';

  Map<GlobalShortcutAction, List<KeyBinding>> _bindings = _defaults();
  bool _enabled = true;
  bool _loaded = false;
  int _revision = 0;
  Future<void>? _loading;

  /// 是否已尝试从磁盘读取（[load] 幂等）。
  bool get loaded => _loaded;

  bool get enabled => _enabled;

  Map<GlobalShortcutAction, List<KeyBinding>> get bindings =>
      Map.unmodifiable(_bindings);

  List<KeyBinding> bindingsOf(GlobalShortcutAction action) =>
      _bindings[action] ?? const [];

  /// 读取持久化配置。失败/缺省时保留默认表与默认开关，不抛错。
  ///
  /// 并发调用共享同一个在途 Future：晚到的调用者必须等首次读盘完成
  /// 再返回，而不是拿「尚未读到」的默认表立即返回——main.dart 依赖
  /// 「load 完成后才启动全局热键注册」这一前提。
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final revisionAtStart = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(bindingsPrefsKey);
      final decoded = raw == null
          ? null
          : decodeBindingsJson(
              raw,
              actions: GlobalShortcutAction.values,
              defaults: defaultGlobalBindingsFor,
            );
      // 读盘是异步的：这段窗口里用户若已改过键/开关，不能拿磁盘旧值盖掉。
      if (_revision == revisionAtStart) {
        _bindings = decoded ?? _defaults();
        _enabled = prefs.getBool(enabledPrefsKey) ?? true;
      }
    } catch (error) {
      debugPrint('[时音][global-shortcuts] 读取全局快捷键配置失败（回退默认）: $error');
      _bindings = _defaults();
      _enabled = true;
    }
    notifyListeners();
  }

  /// 总开关。关闭即不应有任何系统级注册（由服务层响应）。
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    _revision++;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledPrefsKey, value);
    } catch (error) {
      debugPrint('[时音][global-shortcuts] 保存总开关失败（忽略）: $error');
    }
  }

  /// 改键。语义与应用内表一致：同一个组合只属于一个动作，被抢的动作
  /// 置「未设置」、不回落默认键。返回 false 表示组合被保留规则拒绝。
  Future<bool> setBinding(
    GlobalShortcutAction action,
    KeyBinding binding,
  ) async {
    if (globalReservedBindingReason(binding) != null) return false;
    _assign(action, [binding]);
    notifyListeners();
    await _persist();
    return true;
  }

  /// 单个动作恢复默认；默认键若正被别的动作占用，从对方身上摘掉。
  Future<void> resetAction(GlobalShortcutAction action) async {
    _assign(action, defaultGlobalBindingsFor(action));
    notifyListeners();
    await _persist();
  }

  /// 全部键位恢复默认。**不动总开关**——开关是用户对「要不要全局控制」
  /// 的表态，与具体键位无关。
  Future<void> resetAll() async {
    _revision++;
    _bindings = _defaults();
    notifyListeners();
    await _persist();
  }

  /// 该组合当前被哪个动作占用（排除 [ignore]，用于录制时的冲突提示）。
  GlobalShortcutAction? conflictOf(
    KeyBinding binding, {
    GlobalShortcutAction? ignore,
  }) {
    for (final action in GlobalShortcutAction.values) {
      if (action == ignore) continue;
      if (bindingsOf(action).contains(binding)) return action;
    }
    return null;
  }

  /// 把 [bindings] 指派给 [action]，并把这些组合从其它动作上摘掉。
  void _assign(GlobalShortcutAction action, List<KeyBinding> bindings) {
    _revision++;
    _bindings = assignBindings(_bindings, action, bindings);
  }

  /// 仅供测试：回到「未加载 + 默认表 + 开」的初始状态。
  @visibleForTesting
  void debugReset() {
    _bindings = _defaults();
    _enabled = true;
    _loaded = false;
    _revision = 0;
    _loading = null;
  }

  /// 仅供测试：跳过 prefs 直接注入（模拟已加载的配置）。
  @visibleForTesting
  void debugSetBindings(
    Map<GlobalShortcutAction, List<KeyBinding>> value, {
    bool enabled = true,
  }) {
    _bindings = {
      for (final action in GlobalShortcutAction.values)
        action: List<KeyBinding>.of(
          value[action] ?? defaultGlobalBindingsFor(action),
        ),
    };
    _enabled = enabled;
    _loaded = true;
  }

  static Map<GlobalShortcutAction, List<KeyBinding>> _defaults() => {
    for (final action in GlobalShortcutAction.values)
      action: defaultGlobalBindingsFor(action),
  };

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        bindingsPrefsKey,
        jsonEncode({
          for (final entry in _bindings.entries)
            entry.key.name: [
              for (final binding in entry.value) binding.encode(),
            ],
        }),
      );
    } catch (error) {
      debugPrint('[时音][global-shortcuts] 保存全局快捷键配置失败（忽略）: $error');
    }
  }
}
