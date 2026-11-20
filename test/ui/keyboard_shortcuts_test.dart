import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/keyboard_shortcuts.dart';

void main() {
  // SingleActivator 未实现 ==：const 实例靠 canonicalize 才能直接比较。
  // 桌面默认表现在从 defaultBindingsFor 派生（非 const 实例），
  // 这里统一改为逐字段断言，不依赖 const 恒等。
  void expectActivators(
    List<SingleActivator> actual,
    List<SingleActivator> expected,
  ) {
    expect(actual.length, expected.length);
    for (var i = 0; i < expected.length; i++) {
      expect(actual[i].trigger, expected[i].trigger, reason: '[$i] trigger');
      expect(actual[i].control, expected[i].control, reason: '[$i] control');
      expect(actual[i].shift, expected[i].shift, reason: '[$i] shift');
      expect(actual[i].alt, expected[i].alt, reason: '[$i] alt');
      expect(actual[i].meta, expected[i].meta, reason: '[$i] meta');
      expect(
        actual[i].includeRepeats,
        expected[i].includeRepeats,
        reason: '[$i] includeRepeats',
      );
    }
  }

  group('快捷键表映射（桌面/移动双端差异）', () {
    test('桌面端：←/→ = 快退/快进 ±5s，Ctrl+←/→ = 上一首/下一首', () {
      expectActivators(
        appShortcutActivators(AppShortcutAction.seekBackward, desktop: true),
        const [SingleActivator(LogicalKeyboardKey.arrowLeft)],
      );
      expectActivators(
        appShortcutActivators(AppShortcutAction.seekForward, desktop: true),
        const [SingleActivator(LogicalKeyboardKey.arrowRight)],
      );
      expectActivators(
        appShortcutActivators(AppShortcutAction.previousTrack, desktop: true),
        const [SingleActivator(LogicalKeyboardKey.arrowLeft, control: true)],
      );
      expectActivators(
        appShortcutActivators(AppShortcutAction.nextTrack, desktop: true),
        const [SingleActivator(LogicalKeyboardKey.arrowRight, control: true)],
      );
    });

    test('桌面端：空格播放/暂停（排除按住重复）、↑/↓ 音量', () {
      expectActivators(
        appShortcutActivators(AppShortcutAction.playPause, desktop: true),
        const [SingleActivator(LogicalKeyboardKey.space, includeRepeats: false)],
      );
      expectActivators(
        appShortcutActivators(AppShortcutAction.volumeUp, desktop: true),
        const [SingleActivator(LogicalKeyboardKey.arrowUp)],
      );
      expectActivators(
        appShortcutActivators(AppShortcutAction.volumeDown, desktop: true),
        const [SingleActivator(LogicalKeyboardKey.arrowDown)],
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
      expectActivators(
        appShortcutActivators(AppShortcutAction.playPause, desktop: false),
        const [SingleActivator(LogicalKeyboardKey.space)],
      );
      expectActivators(
        appShortcutActivators(AppShortcutAction.volumeUp, desktop: false),
        appShortcutActivators(AppShortcutAction.volumeUp, desktop: true),
      );
      expectActivators(
        appShortcutActivators(AppShortcutAction.volumeDown, desktop: false),
        appShortcutActivators(AppShortcutAction.volumeDown, desktop: true),
      );
    });

    test('桌面端同一物理键（←）同时承载 seek（无修饰）与切歌（Ctrl）', () {
      // 键值级去重（SingleActivator 无 ==，identity 去重对派生实例无效）：
      // 同一「键 + 修饰」组合在默认表里只属于一个动作。
      final seen = <String>{};
      for (final action in AppShortcutAction.values) {
        for (final binding in defaultBindingsFor(action)) {
          expect(
            seen.add(binding.encode()),
            isTrue,
            reason: '${action.label} 的 ${binding.label} 与其它动作重复',
          );
        }
      }
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
