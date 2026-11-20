import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局播放快捷键的动作语义（双端共用）。
///
/// 由 [appShortcutActivators] 按桌面/移动形态映射为不同按键；桌面端可在
/// 设置页「键盘快捷键」逐项改键（见 [ShortcutController]）。
enum AppShortcutAction {
  /// 空格：播放/暂停（双端一致；桌面端含滚动退让，见
  /// keyboard_focus_guard.dart 的空格守卫）。
  playPause,

  /// 上一首：桌面 = Ctrl+←，移动 = ←（历史行为）。
  previousTrack,

  /// 下一首：桌面 = Ctrl+→，移动 = →（历史行为）。
  nextTrack,

  /// 快退 ±5 秒：仅桌面 = ←；移动端无此动作（← 是切歌）。
  seekBackward,

  /// 快进 ±5 秒：仅桌面 = →；移动端无此动作（→ 是切歌）。
  seekForward,

  /// ↑：音量 +5%（双端一致）。
  volumeUp,

  /// ↓：音量 -5%（双端一致）。
  volumeDown,
}

/// 动作在设置页里的展示文案。
extension AppShortcutActionLabel on AppShortcutAction {
  String get label => switch (this) {
    AppShortcutAction.playPause => '播放 / 暂停',
    AppShortcutAction.previousTrack => '上一首',
    AppShortcutAction.nextTrack => '下一首',
    AppShortcutAction.seekBackward => '快退 5 秒',
    AppShortcutAction.seekForward => '快进 5 秒',
    AppShortcutAction.volumeUp => '音量 +5%',
    AppShortcutAction.volumeDown => '音量 −5%',
  };

  /// 设置页副标题：说清这个键在什么前提下才生效。
  String get hint => switch (this) {
    AppShortcutAction.playPause => '焦点不在按钮/输入框时生效；焦点在列表上时改为翻页',
    AppShortcutAction.previousTrack => '切到上一首',
    AppShortcutAction.nextTrack => '切到下一首',
    AppShortcutAction.seekBackward => '当前位置回退 5 秒',
    AppShortcutAction.seekForward => '当前位置前进 5 秒',
    AppShortcutAction.volumeUp => '音量上调一档',
    AppShortcutAction.volumeDown => '音量下调一档',
  };
}

/// 桌面快进/快退步长（←/→ 单次 seek 的秒数）。
const Duration desktopSeekStep = Duration(seconds: 5);

/// 一个可持久化的键位：逻辑键 + 修饰键。
///
/// 持久化只存 [LogicalKeyboardKey.keyId] 与修饰位，跨版本稳定；展示用
/// [label]（`Ctrl + Shift + ←` 这种）。
@immutable
class KeyBinding {
  const KeyBinding(
    this.key, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  /// 修饰键顺序固定，便于相等比较与展示。
  SingleActivator toActivator({bool includeRepeats = true}) => SingleActivator(
    key,
    control: control,
    shift: shift,
    alt: alt,
    meta: meta,
    includeRepeats: includeRepeats,
  );

  /// 持久化编码：修饰位 + keyId，如 `1000:32`（Ctrl+空格）。
  String encode() =>
      '${control ? 1 : 0}${shift ? 1 : 0}${alt ? 1 : 0}${meta ? 1 : 0}:${key.keyId}';

  /// 解码；脏数据返回 null（调用方回退默认键位，不让设置页崩）。
  static KeyBinding? tryDecode(String raw) {
    final separator = raw.lastIndexOf(':');
    if (separator <= 0) return null;
    final flags = raw.substring(0, separator);
    final keyId = int.tryParse(raw.substring(separator + 1));
    if (keyId == null || !RegExp(r'^[01]{4}$').hasMatch(flags)) return null;
    bool bit(int index) => flags[index] == '1';
    return KeyBinding(
      LogicalKeyboardKey(keyId),
      control: bit(0),
      shift: bit(1),
      alt: bit(2),
      meta: bit(3),
    );
  }

  /// 展示文本：`Ctrl + Shift + ←` / `空格`。
  String get label => [
    if (control) 'Ctrl',
    if (shift) 'Shift',
    if (alt) 'Alt',
    if (meta) 'Win',
    describeShortcutKey(key),
  ].join(' + ');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeyBinding &&
          other.key.keyId == key.keyId &&
          other.control == control &&
          other.shift == shift &&
          other.alt == alt &&
          other.meta == meta;

  @override
  int get hashCode => Object.hash(key.keyId, control, shift, alt, meta);

  @override
  String toString() => 'KeyBinding($label)';
}

/// 按键的展示名。`LogicalKeyboardKey.keyLabel` 对空格/方向键给的是不可见
/// 字符或空串，这里统一换成中文/箭头。
String describeShortcutKey(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.space) return '空格';
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
    return '回车';
  }
  if (key == LogicalKeyboardKey.tab) return 'Tab';
  if (key == LogicalKeyboardKey.backspace) return '退格';
  if (key == LogicalKeyboardKey.delete) return 'Delete';
  if (key == LogicalKeyboardKey.arrowLeft) return '←';
  if (key == LogicalKeyboardKey.arrowRight) return '→';
  if (key == LogicalKeyboardKey.arrowUp) return '↑';
  if (key == LogicalKeyboardKey.arrowDown) return '↓';
  if (key == LogicalKeyboardKey.pageUp) return 'Page Up';
  if (key == LogicalKeyboardKey.pageDown) return 'Page Down';
  if (key == LogicalKeyboardKey.home) return 'Home';
  if (key == LogicalKeyboardKey.end) return 'End';
  final label = key.keyLabel;
  if (label.isNotEmpty) return label.toUpperCase();
  return key.debugName ?? '按键 ${key.keyId}';
}

/// 纯修饰键：录制新键位时按下它们只是在「等主键」，不能当成一次绑定。
bool isModifierKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.control ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.shift ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.alt ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.meta ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight ||
      key == LogicalKeyboardKey.capsLock ||
      key == LogicalKeyboardKey.fn;
}

/// 桌面端默认键位表（设置页「恢复默认」与首次启动的初始值）。
List<KeyBinding> defaultBindingsFor(AppShortcutAction action) {
  return switch (action) {
    AppShortcutAction.playPause => const [KeyBinding(LogicalKeyboardKey.space)],
    AppShortcutAction.previousTrack => const [
      KeyBinding(LogicalKeyboardKey.arrowLeft, control: true),
    ],
    AppShortcutAction.nextTrack => const [
      KeyBinding(LogicalKeyboardKey.arrowRight, control: true),
    ],
    AppShortcutAction.seekBackward => const [
      KeyBinding(LogicalKeyboardKey.arrowLeft),
    ],
    AppShortcutAction.seekForward => const [
      KeyBinding(LogicalKeyboardKey.arrowRight),
    ],
    AppShortcutAction.volumeUp => const [KeyBinding(LogicalKeyboardKey.arrowUp)],
    AppShortcutAction.volumeDown => const [
      KeyBinding(LogicalKeyboardKey.arrowDown),
    ],
  };
}

/// 返回 [action] 在指定形态下的**默认**激活键集合。
///
/// - 移动端（desktop=false）：历史行为逐字节保持 —— 空格播放/暂停、
///   ←/→ 切歌、↑/↓ 音量；无 seek 快捷键，且不受桌面端改键影响。
/// - 桌面端（desktop=true）：对齐 PC 播放器惯例 —— ←/→ 快退/快进
///   [desktopSeekStep]，Ctrl+←/→ 切歌；空格/↑/↓ 与移动端一致
///   （空格在桌面端额外排除按住重复触发）。
///
/// 桌面端实际生效的键位由 [ShortcutController] 决定（可在设置页改键），
/// 本函数只提供默认值。
List<SingleActivator> appShortcutActivators(
  AppShortcutAction action, {
  required bool desktop,
}) {
  return switch (action) {
    AppShortcutAction.playPause => desktop
        // 桌面排除 key repeat：按住空格不应连发播放/暂停。
        ? const [SingleActivator(LogicalKeyboardKey.space, includeRepeats: false)]
        : const [SingleActivator(LogicalKeyboardKey.space)],
    AppShortcutAction.previousTrack => desktop
        ? const [SingleActivator(LogicalKeyboardKey.arrowLeft, control: true)]
        : const [SingleActivator(LogicalKeyboardKey.arrowLeft)],
    AppShortcutAction.nextTrack => desktop
        ? const [SingleActivator(LogicalKeyboardKey.arrowRight, control: true)]
        : const [SingleActivator(LogicalKeyboardKey.arrowRight)],
    AppShortcutAction.seekBackward => desktop
        ? const [SingleActivator(LogicalKeyboardKey.arrowLeft)]
        : const [],
    AppShortcutAction.seekForward => desktop
        ? const [SingleActivator(LogicalKeyboardKey.arrowRight)]
        : const [],
    AppShortcutAction.volumeUp => const [
      SingleActivator(LogicalKeyboardKey.arrowUp),
    ],
    AppShortcutAction.volumeDown => const [
      SingleActivator(LogicalKeyboardKey.arrowDown),
    ],
  };
}

/// 桌面端快捷键的可改配置（issue #31）。
///
/// 设置页「键盘快捷键」读写这里，[AppShortcutScope] 监听它重建 `Shortcuts`
/// 表，改键立即生效、无需重启。持久化在 SharedPreferences，脏数据一律回退
/// 默认表——快捷键是锦上添花，绝不能因为一条坏记录让播放控制失灵。
///
/// **只覆盖应用内（局部）快捷键**：系统级全局热键（App 在后台/失焦时也响应）
/// 需要原生 RegisterHotKey 注册与冲突协商，当前版本未接入。
class ShortcutController extends ChangeNotifier {
  ShortcutController._();

  static final ShortcutController instance = ShortcutController._();

  /// prefs 键：JSON `{"playPause":["1000:32"], ...}`。
  static const String prefsKey = 'settings.shortcut_bindings.v1';

  Map<AppShortcutAction, List<KeyBinding>> _bindings = _defaults();
  bool _loaded = false;

  /// 是否已尝试从磁盘读取（[load] 幂等）。
  bool get loaded => _loaded;

  Map<AppShortcutAction, List<KeyBinding>> get bindings =>
      Map.unmodifiable(_bindings);

  List<KeyBinding> bindingsOf(AppShortcutAction action) =>
      _bindings[action] ?? const [];

  /// 该动作当前生效的激活器；空格保持「排除按住重复」。
  List<SingleActivator> activatorsOf(AppShortcutAction action) => [
    for (final binding in bindingsOf(action))
      binding.toActivator(
        includeRepeats: action != AppShortcutAction.playPause,
      ),
  ];

  /// 读取持久化配置。失败/缺省时保留默认表，不抛错。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      final decoded = raw == null ? null : _decode(raw);
      _bindings = decoded ?? _defaults();
    } catch (error) {
      debugPrint('[时音][shortcuts] 读取快捷键配置失败（回退默认）: $error');
      _bindings = _defaults();
    }
    notifyListeners();
  }

  /// 改键。
  ///
  /// 同一个组合只能属于一个动作：会把该组合从其它动作上摘掉，避免
  /// `Shortcuts` 表里后写入的项覆盖前一项、用户以为「改了却没生效」。
  /// 被摘掉的动作若因此变空，回落它的默认键位（保证每个动作始终可用）。
  Future<void> setBinding(
    AppShortcutAction action,
    KeyBinding binding,
  ) async {
    for (final other in AppShortcutAction.values) {
      if (other == action) continue;
      final remaining = bindingsOf(
        other,
      ).where((item) => item != binding).toList(growable: false);
      if (remaining.length == bindingsOf(other).length) continue;
      _bindings[other] = remaining.isEmpty
          ? defaultBindingsFor(other)
          : remaining;
    }
    _bindings[action] = [binding];
    notifyListeners();
    await _persist();
  }

  /// 单个动作恢复默认。
  Future<void> resetAction(AppShortcutAction action) async {
    _bindings[action] = defaultBindingsFor(action);
    notifyListeners();
    await _persist();
  }

  /// 全部恢复默认。
  Future<void> resetAll() async {
    _bindings = _defaults();
    notifyListeners();
    await _persist();
  }

  /// 该组合当前被哪个动作占用（排除 [ignore]，用于录制时的冲突提示）。
  AppShortcutAction? conflictOf(
    KeyBinding binding, {
    AppShortcutAction? ignore,
  }) {
    for (final action in AppShortcutAction.values) {
      if (action == ignore) continue;
      if (bindingsOf(action).contains(binding)) return action;
    }
    return null;
  }

  /// 仅供测试：回到「未加载 + 默认表」的初始状态。
  @visibleForTesting
  void debugReset() {
    _bindings = _defaults();
    _loaded = false;
  }

  /// 仅供测试：跳过 prefs 直接注入（模拟已加载的配置）。
  @visibleForTesting
  void debugSetBindings(Map<AppShortcutAction, List<KeyBinding>> value) {
    _bindings = {
      for (final action in AppShortcutAction.values)
        action: List<KeyBinding>.of(
          value[action] ?? defaultBindingsFor(action),
        ),
    };
    _loaded = true;
  }

  static Map<AppShortcutAction, List<KeyBinding>> _defaults() => {
    for (final action in AppShortcutAction.values)
      action: defaultBindingsFor(action),
  };

  Map<AppShortcutAction, List<KeyBinding>>? _decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final result = <AppShortcutAction, List<KeyBinding>>{};
      for (final action in AppShortcutAction.values) {
        final encoded = json[action.name];
        final parsed = <KeyBinding>[];
        if (encoded is List) {
          for (final item in encoded) {
            if (item is! String) continue;
            final binding = KeyBinding.tryDecode(item);
            if (binding != null) parsed.add(binding);
          }
        }
        result[action] = parsed.isEmpty ? defaultBindingsFor(action) : parsed;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefsKey,
        jsonEncode({
          for (final entry in _bindings.entries)
            entry.key.name: [for (final binding in entry.value) binding.encode()],
        }),
      );
    } catch (error) {
      // 写盘失败只影响「下次启动是否记得」，本次会话已生效。
      debugPrint('[时音][shortcuts] 保存快捷键配置失败（忽略）: $error');
    }
  }
}

/// 计算 ←/→ seek 的目标进度：当前位置 ± [step]，并 clamp 到 0..[duration]。
///
/// [duration] 非正（未加载/时长未知）时返回 null，表示不执行 seek。
Duration? computeSeekTarget({
  required Duration position,
  required Duration duration,
  required bool forward,
  Duration step = desktopSeekStep,
}) {
  if (duration <= Duration.zero) return null;
  final delta = forward ? step.inMilliseconds : -step.inMilliseconds;
  final target = (position.inMilliseconds + delta).clamp(0, duration.inMilliseconds);
  return Duration(milliseconds: target);
}
