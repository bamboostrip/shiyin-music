import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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

/// 解析持久化的键位 JSON（应用内/全局两张表共用）：
///
/// - 坏 JSON/非对象 → null（调用方回退默认表，不让快捷键全灭）；
/// - 动作键缺失（老版本/半截配置）→ 该动作回默认；
///   **显式空数组保留**——它表示「该动作的键被别的动作抢走了」，
///   回落默认会把重复占用一起带回来；
/// - 单条脏数据跳过；同一组合多处出现先到先得
///   （手改配置/旧版本残留都不该让任何动作静默失效）。
Map<E, List<KeyBinding>>? decodeBindingsJson<E extends Enum>(
  String raw, {
  required Iterable<E> actions,
  required List<KeyBinding> Function(E action) defaults,
}) {
  try {
    final json = jsonDecode(raw);
    if (json is! Map) return null;
    final result = <E, List<KeyBinding>>{};
    final claimed = <KeyBinding>{};
    for (final action in actions) {
      final encoded = json[action.name];
      if (encoded is! List) {
        result[action] = defaults(action);
        continue;
      }
      final parsed = <KeyBinding>[];
      for (final item in encoded) {
        if (item is! String) continue;
        final binding = KeyBinding.tryDecode(item);
        if (binding != null && claimed.add(binding)) parsed.add(binding);
      }
      result[action] = parsed;
    }
    return result;
  } catch (_) {
    return null;
  }
}

/// 指派 + 抢占（两张表共用）：把 [bindings] 给 [action]，并把这些组合从
/// 其它动作上摘掉。
///
/// 被摘动作**不回落默认键**——默认键往往正是被抢走的那个组合（例如把
/// 空格改给「快进」后，播放/暂停再回落空格就会两条记录共用一键），
/// 摘空即「未设置」，由用户再绑或点「恢复默认」，语义可预期。
Map<E, List<KeyBinding>> assignBindings<E extends Enum>(
  Map<E, List<KeyBinding>> current,
  E action,
  List<KeyBinding> bindings,
) {
  return {
    for (final entry in current.entries)
      entry.key:
          entry.key == action
              ? List<KeyBinding>.of(bindings)
              : entry.value
                    .where((item) => !bindings.contains(item))
                    .toList(growable: false),
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
    // macOS 的 Command 键在 Windows 上是 Win 键，展示名跟随平台。
    if (meta) defaultTargetPlatform == TargetPlatform.macOS ? 'Cmd' : 'Win',
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

/// 已被框架或固定快捷键占用的组合：不允许改绑，返回给用户看的原因。
///
/// 被占用的都是**精确组合**：焦点系统的裸 Esc/Tab 与 Shift+Tab（反向
/// 遍历），桌面骨架固定表的裸回车、Ctrl+F、Ctrl+1~6。允许改绑会让
/// 「关弹层 / 切焦点 / 打开播放页 / 搜索 / 切分区」失灵，且两个
/// `Shortcuts` 表谁生效取决于层级，排查成本远高于收益。
///
/// 只拦精确组合、不按主键一刀切：Ctrl+回车、Alt+回车这类带修饰键的
/// 搭配并未被占用，拦下它们会把空闲键位挡在门外，理由文案还会误导。
String? reservedBindingReason(KeyBinding binding) {
  final key = binding.key;
  final hasModifier =
      binding.control || binding.shift || binding.alt || binding.meta;
  if (!hasModifier) {
    if (key == LogicalKeyboardKey.escape) return 'Esc 用于关闭弹层与取消搜索';
    if (key == LogicalKeyboardKey.tab) return 'Tab 用于切换键盘焦点';
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      return '回车用于打开播放页（固定快捷键）';
    }
  } else if (
      binding.shift && !binding.control && !binding.alt && !binding.meta) {
    if (key == LogicalKeyboardKey.tab) return 'Shift + Tab 用于反向切换键盘焦点';
  }
  if (binding.control && !binding.shift && !binding.alt && !binding.meta) {
    if (key == LogicalKeyboardKey.keyF) return 'Ctrl + F 用于打开搜索（固定快捷键）';
    const sidebarDigits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
    ];
    if (sidebarDigits.contains(key)) {
      return 'Ctrl + 1~6 用于切换侧栏分区（固定快捷键）';
    }
  }
  return null;
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
/// 本函数只提供默认值。桌面默认表直接从 [defaultBindingsFor] 派生：
/// 改键初始值、恢复默认与本表共用同一份事实源，新增动作不会两表漂移；
/// 空格「排除按住重复」的规则与 [ShortcutController.activatorsOf] 一致。
List<SingleActivator> appShortcutActivators(
  AppShortcutAction action, {
  required bool desktop,
}) {
  if (desktop) {
    return [
      for (final binding in defaultBindingsFor(action))
        binding.toActivator(
          includeRepeats: action != AppShortcutAction.playPause,
        ),
    ];
  }
  return switch (action) {
    AppShortcutAction.playPause => const [
      SingleActivator(LogicalKeyboardKey.space),
    ],
    AppShortcutAction.previousTrack => const [
      SingleActivator(LogicalKeyboardKey.arrowLeft),
    ],
    AppShortcutAction.nextTrack => const [
      SingleActivator(LogicalKeyboardKey.arrowRight),
    ],
    AppShortcutAction.seekBackward => const [],
    AppShortcutAction.seekForward => const [],
    AppShortcutAction.volumeUp => const [SingleActivator(LogicalKeyboardKey.arrowUp)],
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
/// **只覆盖应用内（局部）快捷键**：系统级全局热键（App 在后台/失焦时也
/// 响应）见平行的 [GlobalShortcutController]（global_shortcuts.dart），
/// 由 hotkey_manager 注册、[GlobalHotkeyService] 同步。
class ShortcutController extends ChangeNotifier {
  ShortcutController._();

  static final ShortcutController instance = ShortcutController._();

  /// prefs 键：JSON `{"playPause":["1000:32"], ...}`。
  static const String prefsKey = 'settings.shortcut_bindings.v1';

  Map<AppShortcutAction, List<KeyBinding>> _bindings = _defaults();
  bool _loaded = false;
  Future<void>? _loading;

  /// 本地改动代次：用于识别「读取配置期间用户已经改过键」。
  int _revision = 0;

  /// 是否已尝试从磁盘读取（[load] 幂等）。
  bool get loaded => _loaded;

  Map<AppShortcutAction, List<KeyBinding>> get bindings =>
      Map.unmodifiable(_bindings);

  List<KeyBinding> bindingsOf(AppShortcutAction action) =>
      _bindings[action] ?? const [];

  /// 该动作当前生效的激活器；「播放/暂停」保持「排除按住重复」，
  /// 否则按住改键后的播放键会连发。
  List<SingleActivator> activatorsOf(AppShortcutAction action) => [
    for (final binding in bindingsOf(action))
      binding.toActivator(
        includeRepeats: action != AppShortcutAction.playPause,
      ),
  ];

  /// 读取持久化配置。失败/缺省时保留默认表，不抛错。
  ///
  /// 并发调用共享同一个在途 Future（与 GlobalShortcutController 同一
  /// 契约）：晚到的调用者必须等首次读盘完成再返回。
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final revisionAtStart = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      final decoded = raw == null
          ? null
          : decodeBindingsJson(
              raw,
              actions: AppShortcutAction.values,
              defaults: defaultBindingsFor,
            );
      // 读盘是异步的：这段窗口里用户若已经在设置页改过键（冷启动首帧后
      // 就进设置页虽极端，但成本为零），不能拿磁盘旧值把它盖掉。
      if (_revision == revisionAtStart) {
        _bindings = decoded ?? _defaults();
      }
    } catch (error) {
      debugPrint('[时音][shortcuts] 读取快捷键配置失败（回退默认）: $error');
      _bindings = _defaults();
    }
    notifyListeners();
  }

  /// 改键。
  ///
  /// 同一个组合只能属于一个动作：会把它从其它动作上摘掉。被摘掉的动作
  /// **不回落到默认键**——默认键往往正是被抢走的那个组合（例如把空格改给
  /// 「快进」后，播放/暂停再回落空格就会两条记录共用一键，而 `Shortcuts`
  /// 表里后写的覆盖前写的，表现为「播放/暂停静默失效」）。摘空即变「未设置」，
  /// 由用户自己再绑或点「恢复默认」，语义可预期。
  ///
  /// 返回 false 表示该组合是系统级保留键（见 [reservedBindingReason]），
  /// 调用方据此提示用户。
  Future<bool> setBinding(
    AppShortcutAction action,
    KeyBinding binding,
  ) async {
    if (reservedBindingReason(binding) != null) return false;
    _assign(action, [binding]);
    notifyListeners();
    await _persist();
    return true;
  }

  /// 单个动作恢复默认；默认键若正被别的动作占用，从对方身上摘掉，
  /// 保持「一个组合只属于一个动作」。
  Future<void> resetAction(AppShortcutAction action) async {
    _assign(action, defaultBindingsFor(action));
    notifyListeners();
    await _persist();
  }

  /// 全部恢复默认。
  Future<void> resetAll() async {
    _revision++;
    _bindings = _defaults();
    notifyListeners();
    await _persist();
  }

  /// 把 [bindings] 指派给 [action]，并把这些组合从其它动作上摘掉。
  void _assign(AppShortcutAction action, List<KeyBinding> bindings) {
    _revision++;
    _bindings = assignBindings(_bindings, action, bindings);
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
    _revision = 0;
    _loading = null;
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
