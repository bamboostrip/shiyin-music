import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';
import 'package:shiyin_music/services/notification_button_slots.dart';

/// 通知卡片自定义按钮（收藏红心/桌面歌词开关/播放模式）的组合逻辑测试。
/// 按钮声明顺序对齐 QQ 音乐：[左槽位?] 上一首 播放/暂停 下一首 [右槽位?]。
void main() {
  NotificationActionBridge bridge({
    required bool canLike,
    required bool liked,
    required bool lyricsEnabled,
    NotificationPlayMode mode = NotificationPlayMode.playlistLoop,
    NotificationSlotAction left = NotificationSlotAction.like,
    NotificationSlotAction right = NotificationSlotAction.desktopLyrics,
  }) {
    return NotificationActionBridge(
      canToggleLike: () => canLike,
      isCurrentSongLiked: () => liked,
      onToggleLike: () async {},
      desktopLyricsEnabled: () => lyricsEnabled,
      onToggleDesktopLyrics: () async {},
      playbackMode: () => mode,
      onCyclePlaybackMode: () async {},
      leftAction: () => left,
      rightAction: () => right,
    );
  }

  /// 按钮序列的可读摘要：标准键给动作名，自定义键给动作名。
  List<String> namesOf(List<MediaControl> controls) => [
        for (final control in controls)
          control.customAction?.name ?? control.action.name,
      ];

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

  group('buildNotificationControls 槽位配置（issue #34）', () {
    test('左=桌面歌词、右=播放模式：词在左、模式在右（本地歌用户的常用摆法）',
        () {
      final controls = MusicAudioHandler.buildNotificationControls(
        playing: false,
        customButtonsEnabled: true,
        actions: bridge(
          canLike: false,
          liked: false,
          lyricsEnabled: true,
          left: NotificationSlotAction.desktopLyrics,
          right: NotificationSlotAction.playbackMode,
        ),
      );

      expect(namesOf(controls), [
        MusicAudioHandler.toggleDesktopLyricsActionName,
        MediaAction.skipToPrevious.name,
        MediaAction.play.name,
        MediaAction.skipToNext.name,
        MusicAudioHandler.cyclePlaybackModeActionName,
      ]);
      expect(controls.first.androidIcon, 'drawable/ic_notification_lyrics_on');
      expect(controls.last.androidIcon, 'drawable/ic_notification_repeat');
    });

    test('播放模式按钮的图标与文案跟随三种模式', () {
      MediaControl modeControl(NotificationPlayMode mode) =>
          MusicAudioHandler.buildNotificationControls(
            playing: true,
            customButtonsEnabled: true,
            actions: bridge(
              canLike: false,
              liked: false,
              lyricsEnabled: false,
              mode: mode,
              left: NotificationSlotAction.none,
              right: NotificationSlotAction.playbackMode,
            ),
          ).last;

      expect(
        modeControl(NotificationPlayMode.playlistLoop).androidIcon,
        'drawable/ic_notification_repeat',
      );
      expect(
        modeControl(NotificationPlayMode.playlistLoop).label,
        '播放模式：歌单循环，点按切换',
      );
      expect(
        modeControl(NotificationPlayMode.shuffle).androidIcon,
        'drawable/ic_notification_shuffle',
      );
      expect(
        modeControl(NotificationPlayMode.shuffle).label,
        '播放模式：随机播放，点按切换',
      );
      expect(
        modeControl(NotificationPlayMode.singleLoop).androidIcon,
        'drawable/ic_notification_repeat_one',
      );
      expect(
        modeControl(NotificationPlayMode.singleLoop).label,
        '播放模式：单曲循环，点按切换',
      );
    });

    test('两侧都选同一个按钮只出现一次（以左侧为准）', () {
      final controls = MusicAudioHandler.buildNotificationControls(
        playing: true,
        customButtonsEnabled: true,
        actions: bridge(
          canLike: true,
          liked: false,
          lyricsEnabled: false,
          left: NotificationSlotAction.desktopLyrics,
          right: NotificationSlotAction.desktopLyrics,
        ),
      );

      expect(namesOf(controls), [
        MusicAudioHandler.toggleDesktopLyricsActionName,
        MediaAction.skipToPrevious.name,
        MediaAction.pause.name,
        MediaAction.skipToNext.name,
      ]);
    });

    test('左侧收藏不可用时不算占用：右侧若配了收藏同样不出现，其余照常', () {
      final bothLike = MusicAudioHandler.buildNotificationControls(
        playing: true,
        customButtonsEnabled: true,
        actions: bridge(
          canLike: false,
          liked: false,
          lyricsEnabled: false,
          left: NotificationSlotAction.like,
          right: NotificationSlotAction.like,
        ),
      );
      expect(namesOf(bothLike), [
        MediaAction.skipToPrevious.name,
        MediaAction.pause.name,
        MediaAction.skipToNext.name,
      ]);

      final unavailableLeft = MusicAudioHandler.buildNotificationControls(
        playing: true,
        customButtonsEnabled: true,
        actions: bridge(
          canLike: false,
          liked: false,
          lyricsEnabled: false,
          left: NotificationSlotAction.like,
          right: NotificationSlotAction.playbackMode,
        ),
      );
      expect(namesOf(unavailableLeft), [
        MediaAction.skipToPrevious.name,
        MediaAction.pause.name,
        MediaAction.skipToNext.name,
        MusicAudioHandler.cyclePlaybackModeActionName,
      ]);
    });

    test('两侧都选「不显示」只剩标准三键', () {
      final controls = MusicAudioHandler.buildNotificationControls(
        playing: true,
        customButtonsEnabled: true,
        actions: bridge(
          canLike: true,
          liked: true,
          lyricsEnabled: true,
          left: NotificationSlotAction.none,
          right: NotificationSlotAction.none,
        ),
      );

      expect(controls.length, 3);
      expect(controls.any((c) => c.action == MediaAction.custom), isFalse);
    });
  });

  group('legacyCompactActionIndices（Android 12 及以下收起态）', () {
    List<MediaControl> build(NotificationActionBridge actions) =>
        MusicAudioHandler.buildNotificationControls(
          playing: true,
          customButtonsEnabled: true,
          actions: actions,
        );

    test('两侧都有自定义按钮时标准三键在 1/2/3', () {
      final controls = build(
        bridge(canLike: true, liked: true, lyricsEnabled: true),
      );
      expect(MusicAudioHandler.legacyCompactActionIndices(controls), [1, 2, 3]);
    });

    test('没有自定义按钮时是 0/1/2（不能越界）', () {
      final controls = MusicAudioHandler.buildNotificationControls(
        playing: true,
        customButtonsEnabled: true,
      );
      expect(MusicAudioHandler.legacyCompactActionIndices(controls), [0, 1, 2]);
    });

    test('左侧按钮被隐藏时标准三键前移到 0/1/2', () {
      final controls = build(
        bridge(canLike: false, liked: false, lyricsEnabled: true),
      );
      expect(controls.length, 4);
      expect(MusicAudioHandler.legacyCompactActionIndices(controls), [0, 1, 2]);
    });

    test('未来增加 seek/stop 等标准键时仍只取上一首/播放暂停/下一首', () {
      final controls = <MediaControl>[
        MediaControl.custom(
          androidIcon: 'drawable/ic_notification_heart_filled',
          label: '收藏',
          name: 'shiyin.toggle_like',
        ),
        MediaControl.skipToPrevious,
        MediaControl.pause,
        MediaControl.skipToNext,
        MediaControl.fastForward,
        MediaControl.stop,
      ];
      expect(MusicAudioHandler.legacyCompactActionIndices(controls), [1, 2, 3]);
    });
  });

  group('refreshPlaybackControls 冷启动门控', () {
    test('未投递过媒体时不允许广播：冷启动恢复不凭空贴通知', () {
      expect(
        MusicAudioHandler.shouldRefreshPlaybackControls(hasLoadedMedia: false),
        isFalse,
      );
    });

    test('投递过媒体后允许广播：按钮刷新正常下发', () {
      expect(
        MusicAudioHandler.shouldRefreshPlaybackControls(hasLoadedMedia: true),
        isTrue,
      );
    });
  });
}
