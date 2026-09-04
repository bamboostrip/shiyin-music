import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全局播放快捷键的动作语义（双端共用）。
///
/// 由 [appShortcutActivators] 按桌面/移动形态映射为不同按键。
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

/// 桌面快进/快退步长（←/→ 单次 seek 的秒数）。
const Duration desktopSeekStep = Duration(seconds: 5);

/// 返回 [action] 在指定形态下的激活键集合（桌面/移动快捷键表的唯一决策点）。
///
/// - 移动端（desktop=false）：历史行为逐字节保持 —— 空格播放/暂停、
///   ←/→ 切歌、↑/↓ 音量；无 seek 快捷键。
/// - 桌面端（desktop=true）：对齐 PC 播放器惯例 —— ←/→ 快退/快进
///   [desktopSeekStep]，Ctrl+←/→ 切歌；空格/↑/↓ 与移动端一致
///   （空格在桌面端额外排除按住重复触发）。
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
