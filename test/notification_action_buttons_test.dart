import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

/// 通知卡片自定义按钮（收藏红心/桌面歌词开关）的组合逻辑测试。
/// 按钮声明顺序对齐 QQ 音乐：[红心?] 上一首 播放/暂停 下一首 [词?]。
void main() {
  NotificationActionBridge bridge({
    required bool canLike,
    required bool liked,
    required bool lyricsEnabled,
  }) {
    return NotificationActionBridge(
      canToggleLike: () => canLike,
      isCurrentSongLiked: () => liked,
      onToggleLike: () async {},
      desktopLyricsEnabled: () => lyricsEnabled,
      onToggleDesktopLyrics: () async {},
    );
  }

  group('buildNotificationControls', () {
    test('未注入桥接（桌面端/启动早期）只有标准三键', () {
      final controls = MusicAudioHandler.buildNotificationControls(
        playing: true,
        customButtonsEnabled: true,
      );

      expect(controls.length, 3);
      expect(controls[0].action, MediaAction.skipToPrevious);
      expect(controls[1].action, MediaAction.pause);
      expect(controls[2].action, MediaAction.skipToNext);
    });

    test('车机/非 Android 关闭自定义按钮后即使有桥接也只有标准三键', () {
      final controls = MusicAudioHandler.buildNotificationControls(
        playing: false,
        customButtonsEnabled: false,
        actions: bridge(canLike: true, liked: true, lyricsEnabled: true),
      );

      expect(controls.length, 3);
      expect(controls.any((c) => c.action == MediaAction.custom), isFalse);
    });

    test('完整状态：已收藏+歌词开，五键且顺序为 红心/上一首/暂停/下一首/词', () {
      final controls = MusicAudioHandler.buildNotificationControls(
        playing: true,
        customButtonsEnabled: true,
        actions: bridge(canLike: true, liked: true, lyricsEnabled: true),
      );

      expect(controls.length, 5);
      expect(controls[0].androidIcon,
          'drawable/ic_notification_heart_filled');
      expect(controls[0].label, '取消收藏');
      expect(controls[0].customAction?.name,
          MusicAudioHandler.toggleLikeActionName);
      expect(controls[1].action, MediaAction.skipToPrevious);
      expect(controls[2].action, MediaAction.pause);
      expect(controls[3].action, MediaAction.skipToNext);
      expect(controls[4].androidIcon, 'drawable/ic_notification_lyrics_on');
      expect(controls[4].label, '关闭桌面歌词');
      expect(controls[4].customAction?.name,
          MusicAudioHandler.toggleDesktopLyricsActionName);
    });

    test('未收藏/歌词关：红心空心、词按钮为关闭图标', () {
      final controls = MusicAudioHandler.buildNotificationControls(
        playing: true,
        customButtonsEnabled: true,
        actions: bridge(canLike: true, liked: false, lyricsEnabled: false),
      );

      expect(controls[0].androidIcon,
          'drawable/ic_notification_heart_outline');
      expect(controls[0].label, '收藏');
      expect(controls[4].androidIcon, 'drawable/ic_notification_lyrics_off');
      expect(controls[4].label, '桌面歌词');
    });

    test('未登录（不可收藏）隐藏红心，词按钮保留', () {
      final controls = MusicAudioHandler.buildNotificationControls(
        playing: true,
        customButtonsEnabled: true,
        actions: bridge(canLike: false, liked: false, lyricsEnabled: false),
      );

      expect(controls.length, 4);
      expect(controls[0].action, MediaAction.skipToPrevious);
      expect(controls[3].customAction?.name,
          MusicAudioHandler.toggleDesktopLyricsActionName);
    });
  });
}
