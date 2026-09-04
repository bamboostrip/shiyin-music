import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/keyboard_shortcuts.dart';

void main() {
  group('快捷键表映射（桌面/移动双端差异）', () {
    test('桌面端：←/→ = 快退/快进 ±5s，Ctrl+←/→ = 上一首/下一首', () {
      expect(
        appShortcutActivators(AppShortcutAction.seekBackward, desktop: true),
        [const SingleActivator(LogicalKeyboardKey.arrowLeft)],
      );
      expect(
        appShortcutActivators(AppShortcutAction.seekForward, desktop: true),
        [const SingleActivator(LogicalKeyboardKey.arrowRight)],
      );
      expect(
        appShortcutActivators(AppShortcutAction.previousTrack, desktop: true),
        [const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true)],
      );
      expect(
        appShortcutActivators(AppShortcutAction.nextTrack, desktop: true),
        [const SingleActivator(LogicalKeyboardKey.arrowRight, control: true)],
      );
    });

    test('桌面端：空格播放/暂停（排除按住重复）、↑/↓ 音量', () {
      expect(
        appShortcutActivators(AppShortcutAction.playPause, desktop: true),
        [const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false)],
      );
      expect(
        appShortcutActivators(AppShortcutAction.volumeUp, desktop: true),
        [const SingleActivator(LogicalKeyboardKey.arrowUp)],
      );
      expect(
        appShortcutActivators(AppShortcutAction.volumeDown, desktop: true),
        [const SingleActivator(LogicalKeyboardKey.arrowDown)],
      );
    });

    test('移动端：历史行为保持 —— ←/→ 切歌，无 seek/Ctrl 组合', () {
      expect(
        appShortcutActivators(AppShortcutAction.previousTrack, desktop: false),
        [const SingleActivator(LogicalKeyboardKey.arrowLeft)],
      );
      expect(
        appShortcutActivators(AppShortcutAction.nextTrack, desktop: false),
        [const SingleActivator(LogicalKeyboardKey.arrowRight)],
      );
      // 移动端没有 seek 快捷键（←/→ 语义是切歌）。
      expect(
        appShortcutActivators(AppShortcutAction.seekBackward, desktop: false),
        isEmpty,
      );
      expect(
        appShortcutActivators(AppShortcutAction.seekForward, desktop: false),
        isEmpty,
      );
      // 移动端不出现 Ctrl 组合。
      final allKeys = AppShortcutAction.values
          .expand((a) => appShortcutActivators(a, desktop: false));
      expect(allKeys.where((a) => a.control), isEmpty);
    });

    test('移动端：空格（保留默认重复行为）/↑/↓ 与桌面一致', () {
      expect(
        appShortcutActivators(AppShortcutAction.playPause, desktop: false),
        [const SingleActivator(LogicalKeyboardKey.space)],
      );
      expect(
        appShortcutActivators(AppShortcutAction.volumeUp, desktop: false),
        appShortcutActivators(AppShortcutAction.volumeUp, desktop: true),
      );
      expect(
        appShortcutActivators(AppShortcutAction.volumeDown, desktop: false),
        appShortcutActivators(AppShortcutAction.volumeDown, desktop: true),
      );
    });

    test('桌面端同一物理键（←）同时承载 seek（无修饰）与切歌（Ctrl）', () {
      final desktopKeys = {
        for (final action in AppShortcutAction.values)
          ...appShortcutActivators(action, desktop: true),
      };
      // 无冲突：同一激活器只对应一个动作。
      final flat = AppShortcutAction.values
          .expand((a) => appShortcutActivators(a, desktop: true));
      expect(flat.length, desktopKeys.length);
    });
  });

  group('computeSeekTarget（seek 目标计算与钳制）', () {
    const fiveSeconds = Duration(seconds: 5);

    test('正常前进/后退 ±5 秒', () {
      expect(
        computeSeekTarget(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 4),
          forward: true,
        ),
        const Duration(seconds: 35),
      );
      expect(
        computeSeekTarget(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 4),
          forward: false,
        ),
        const Duration(seconds: 25),
      );
    });

    test('后退越过 0 钳制到 0', () {
      expect(
        computeSeekTarget(
          position: const Duration(seconds: 2),
          duration: const Duration(minutes: 4),
          forward: false,
        ),
        Duration.zero,
      );
    });

    test('前进越过时长钳制到时长', () {
      const duration = Duration(minutes: 4);
      expect(
        computeSeekTarget(
          position: duration - const Duration(seconds: 2),
          duration: duration,
          forward: true,
        ),
        duration,
      );
    });

    test('当前位置已越界时同样钳制到 0..时长', () {
      const duration = Duration(minutes: 4);
      expect(
        computeSeekTarget(
          position: duration + const Duration(seconds: 10),
          duration: duration,
          forward: true,
        ),
        duration,
      );
      expect(
        computeSeekTarget(
          position: const Duration(seconds: -30),
          duration: duration,
          forward: false,
        ),
        Duration.zero,
      );
    });

    test('时长未知（≤0）返回 null 不执行 seek', () {
      expect(
        computeSeekTarget(
          position: Duration.zero,
          duration: Duration.zero,
          forward: true,
        ),
        isNull,
      );
      expect(
        computeSeekTarget(
          position: Duration.zero,
          duration: const Duration(milliseconds: -1),
          forward: false,
        ),
        isNull,
      );
    });

    test('自定义步长', () {
      expect(
        computeSeekTarget(
          position: const Duration(seconds: 60),
          duration: const Duration(minutes: 4),
          forward: true,
          step: const Duration(seconds: 10),
        ),
        const Duration(seconds: 70),
      );
      expect(desktopSeekStep, fiveSeconds);
    });
  });
}
