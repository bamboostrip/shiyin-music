import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/ui/desktop/desktop_player_bar.dart';
import 'package:shiyin_music/ui/desktop/player_bar_widgets.dart';

void main() {
  group('playbackModeIcon', () {
    test('三种模式各对应一个图标', () {
      expect(
        playbackModeIcon(PlaybackMode.playlistLoop),
        Icons.repeat_rounded,
      );
      expect(playbackModeIcon(PlaybackMode.shuffle), Icons.shuffle_rounded);
      expect(
        playbackModeIcon(PlaybackMode.singleLoop),
        Icons.repeat_one_rounded,
      );
    });
  });

  group('playbackModeTooltip', () {
    test('包含当前模式名与切换提示', () {
      expect(
        playbackModeTooltip(PlaybackMode.playlistLoop),
        '列表循环（点击切换）',
      );
      expect(playbackModeTooltip(PlaybackMode.shuffle), '随机播放（点击切换）');
      expect(playbackModeTooltip(PlaybackMode.singleLoop), '单曲循环（点击切换）');
    });
  });

  group('volumeIconFor', () {
    test('0 → 静音图标', () {
      expect(volumeIconFor(0), Icons.volume_off_rounded);
    });
    test('0..0.5 → 小音量图标', () {
      expect(volumeIconFor(0.05), Icons.volume_down_rounded);
      expect(volumeIconFor(0.49), Icons.volume_down_rounded);
    });
    test('≥0.5 → 大音量图标', () {
      expect(volumeIconFor(0.5), Icons.volume_up_rounded);
      expect(volumeIconFor(1.0), Icons.volume_up_rounded);
    });
  });

  group('toggleMute（静音记忆）', () {
    test('有音量时静音：音量归零并记住当前值', () {
      final (volume, memory) = toggleMute(0.8, null);
      expect(volume, 0.0);
      expect(memory, 0.8);
    });
    test('静音态取消：恢复记忆音量，记忆值保持', () {
      final (volume, memory) = toggleMute(0.0, 0.65);
      expect(volume, 0.65);
      expect(memory, 0.65);
    });
    test('静音态取消但无记忆：回退默认恢复值', () {
      final (volume, memory) = toggleMute(0.0, null);
      expect(volume, kDefaultRestoreVolume);
      expect(memory, isNull);
    });
    test('记忆音量越界时钳制', () {
      final (volume, _) = toggleMute(0.0, 1.5);
      expect(volume, 1.0);
    });
    test('当前音量越界时记忆值钳制', () {
      final (volume, memory) = toggleMute(1.2, null);
      expect(volume, 0.0);
      expect(memory, 1.0);
    });
  });

  group('applyVolumeWheel（滚轮步进）', () {
    test('默认步进为 ±5%', () {
      expect(kVolumeWheelStep, 0.05);
      expect(applyVolumeWheel(0.4, true), closeTo(0.45, 1e-9));
      expect(applyVolumeWheel(0.4, false), closeTo(0.35, 1e-9));
    });
    test('钳制 0..1', () {
      expect(applyVolumeWheel(0.98, true), 1.0);
      expect(applyVolumeWheel(0.03, false), 0.0);
      expect(applyVolumeWheel(1.0, true), 1.0);
      expect(applyVolumeWheel(0.0, false), 0.0);
    });
  });

  group('positionForHover（悬停位置 → 时间）', () {
    const twoMinutes = Duration(minutes: 2);
    test('两端与中点', () {
      expect(positionForHover(0, 280, twoMinutes), Duration.zero);
      expect(positionForHover(140, 280, twoMinutes), const Duration(minutes: 1));
      expect(positionForHover(280, 280, twoMinutes), twoMinutes);
    });
    test('越界坐标按端点钳制', () {
      expect(positionForHover(-10, 280, twoMinutes), Duration.zero);
      expect(positionForHover(999, 280, twoMinutes), twoMinutes);
    });
    test('宽度或时长非法时返回 0', () {
      expect(positionForHover(10, 0, twoMinutes), Duration.zero);
      expect(positionForHover(10, 280, Duration.zero), Duration.zero);
    });
    test('返回值经过 formatDuration 可直接展示', () {
      final t = positionForHover(70, 280, twoMinutes);
      expect(formatDuration(t), '00:30');
    });
  });
}
