import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart' hide formatDuration;
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/desktop/desktop_player_bar.dart';
import 'package:shiyin_music/ui/desktop/player_bar_widgets.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';
import 'package:shiyin_music/ui/widgets/marquee_text.dart';
import 'package:shiyin_music/ui/widgets/song_share.dart';

class _FakeDownloadController extends ChangeNotifier implements DownloadController {
  bool downloaded = false;
  int downloadCalls = 0;
  @override
  bool isDownloaded(Song song) => downloaded;
  @override
  Future<void> download(Song song, AudioQuality quality) async {
    downloadCalls++;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 评论接口 fake：[count] 非空时返回对应评论数，为空时模拟服务不可用。
class _FakeCommentApi implements MusicApi {
  _FakeCommentApi({this.count});

  final int? count;
  int calls = 0;

  @override
  Future<MusicCommentResponse> musicComments(
    String mixsongid, {
    int page = 1,
    int pageSize = 30,
  }) async {
    calls++;
    if (count == null) {
      throw Exception('评论服务暂不可用');
    }
    return MusicCommentResponse(count: count, list: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

  @override
  Song? currentSong;

  /// 评论接口 fake（真实签名为 `MusicApi get api`）；
  /// 未注入时访问抛错 → `_safeApi` 捕获后按无接口降级。
  @override
  MusicApi get api => commentApi ?? (throw Exception('api 未注入'));
  MusicApi? commentApi;
  @override
  bool isPlaying = false;
  @override
  bool isPreparing = false;
  @override
  double volume = 0.8;
  @override
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;
  @override
  Duration duration = Duration.zero;
  @override
  SongClimax? climax;
  @override
  bool isDesktopLyricsSupported = false;
  @override
  bool desktopLyricsEnabled = false;
  @override
  bool desktopLyricsLocked = false;
  int unlockDesktopLyricsCalls = 0;
  int setDesktopLyricsEnabledCalls = 0;

  @override
  DownloadController? downloadController;

  @override
  String get playbackSpeedLabel => '1.0x';

  @override
  double playbackSpeed = 1.0;

  @override
  bool get isSleepTimerActive => false;

  @override
  Duration? get sleepTimerRemaining => null;

  @override
  bool get isSleepFinishCurrentSong => false;

  bool _sleepFinishCurrentSongOption = false;
  @override
  bool get sleepFinishCurrentSongOption => _sleepFinishCurrentSongOption;
  int updateSleepTimerOptionCalls = 0;
  @override
  void updateSleepTimerOption(bool finishCurrentSong) {
    updateSleepTimerOptionCalls++;
    _sleepFinishCurrentSongOption = finishCurrentSong;
    notifyListeners();
  }

  int playClimaxPreviewCalls = 0;
  @override
  Future<bool> playClimaxPreview() async {
    playClimaxPreviewCalls++;
    return true;
  }

  int insertNextCalls = 0;
  Song? lastInsertedNextSong;
  @override
  Future<bool> insertNext(Song song) async {
    insertNextCalls++;
    lastInsertedNextSong = song;
    return true;
  }

  @override
  AudioQuality audioQuality = AudioQuality.standard;
  int setAudioQualityCalls = 0;
  AudioQuality? lastSetAudioQuality;
  bool? lastReloadCurrent;

  @override
  Future<void> setAudioQuality(
    AudioQuality quality, {
    bool reloadCurrent = false,
  }) async {
    setAudioQualityCalls++;
    lastSetAudioQuality = quality;
    lastReloadCurrent = reloadCurrent;
    audioQuality = quality;
    notifyListeners();
  }

  @override
  Future<void> unlockDesktopLyrics() async {
    unlockDesktopLyricsCalls++;
    desktopLyricsLocked = false;
    notifyListeners();
  }

  @override
  Future<void> setDesktopLyricsEnabled(bool enabled) async {
    setDesktopLyricsEnabledCalls++;
    desktopLyricsEnabled = enabled;
    notifyListeners();
  }

  @override
  final ValueNotifier<Duration> positionListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  int cyclePlaybackModeCalls = 0;
  List<double> volumeChanges = [];

  int previousCalls = 0;
  @override
  Future<void> previous() async {
    previousCalls++;
  }

  int nextCalls = 0;
  @override
  Future<void> next() async {
    nextCalls++;
  }

  @override
  PlaybackMode cyclePlaybackMode() {
    cyclePlaybackModeCalls++;
    playbackMode = switch (playbackMode) {
      PlaybackMode.playlistLoop => PlaybackMode.shuffle,
      PlaybackMode.shuffle => PlaybackMode.singleLoop,
      PlaybackMode.singleLoop => PlaybackMode.playlistLoop,
    };
    notifyListeners();
    return playbackMode;
  }

  @override
  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    volumeChanges.add(clamped);
    volume = clamped;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  bool liked = false;
  int toggleLikeCalls = 0;

  @override
  bool isLiked(Song song) => liked;

  @override
  Future<void> toggleLike(Song song) async {
    toggleLikeCalls++;
    liked = !liked;
    notifyListeners();
  }

  @override
  List<PlaylistSummary> get createdPlaylists => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _song = Song(id: '1', title: '测试歌曲', artist: '测试歌手', hash: 'hash-1');

Future<void> _pumpBar(
  WidgetTester tester,
  _FakePlayerController player, {
  _FakeAuthController? auth,
  VoidCallback? onOpenPlayerPage,
  VoidCallback? onCollapse,
  ValueChanged<String>? onOpenComment,
  bool openPlayerPageEnabled = true,
  bool overlayDark = false,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: DesktopPlayerBar(
            player: player,
            auth: auth ?? _FakeAuthController(),
            onOpenPlayerPage: onOpenPlayerPage,
            onOpenComment: onOpenComment,
            onCollapse: onCollapse,
            openPlayerPageEnabled: openPlayerPageEnabled,
            overlayDark: overlayDark,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('formatDuration', () {
    test('分秒补零', () {
      expect(formatDuration(Duration.zero), '00:00');
      expect(formatDuration(const Duration(seconds: 65)), '01:05');
      expect(formatDuration(const Duration(minutes: 9, seconds: 9)), '09:09');
    });
    test('超过一小时显示小时位', () {
      expect(
        formatDuration(const Duration(hours: 1, minutes: 1, seconds: 15)),
        '1:01:15',
      );
    });
  });

  group('播放模式按钮', () {
    testWidgets('点击切换模式，tooltip 与图标随模式更新', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..duration = const Duration(minutes: 2);
      await _pumpBar(tester, player);

      expect(player.playbackMode, PlaybackMode.playlistLoop);
      expect(find.byTooltip('列表循环（点击切换）'), findsOneWidget);
      expect(find.byIcon(Icons.repeat_rounded), findsOneWidget);

      await tester.tap(find.byTooltip('列表循环（点击切换）'));
      await tester.pump();

      expect(player.cyclePlaybackModeCalls, 1);
      expect(player.playbackMode, PlaybackMode.shuffle);
      expect(find.byTooltip('随机播放（点击切换）'), findsOneWidget);
      expect(find.byIcon(Icons.shuffle_rounded), findsOneWidget);

      await tester.tap(find.byTooltip('随机播放（点击切换）'));
      await tester.pump();
      expect(player.playbackMode, PlaybackMode.singleLoop);
      expect(find.byTooltip('单曲循环（点击切换）'), findsOneWidget);
      expect(find.byIcon(Icons.repeat_one_rounded), findsOneWidget);
    });
  });

  group('音量弹层 VolumePopoverButton', () {
    testWidgets('下一首右侧渲染音量入口，点击弹出音量卡片，再次点击收起', (tester) async {
      final player = _FakePlayerController()..volume = 0.7;
      await _pumpBar(tester, player);

      final nextButton = find.byTooltip('下一首');
      final popoverButton = find.byKey(
        const ValueKey('desktop_volume_popover_button'),
      );
      expect(nextButton, findsOneWidget);
      expect(popoverButton, findsOneWidget);
      expect(
        tester.getTopLeft(popoverButton).dx,
        greaterThan(tester.getTopRight(nextButton).dx),
      );

      // 初始未弹出
      expect(find.text('70%'), findsNothing);

      // 点击打开
      await tester.tap(popoverButton);
      await tester.pump();

      expect(find.text('70%'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('volume_popover_mute_button')),
        findsOneWidget,
      );

      // 再次点击收起
      await tester.tap(popoverButton);
      await tester.pump();
      expect(find.text('70%'), findsNothing);
    });

    testWidgets('弹层中点击静音按钮静音并记忆音量，再次点击恢复', (tester) async {
      final player = _FakePlayerController()..volume = 0.7;
      await _pumpBar(tester, player);

      final popoverButton = find.byKey(
        const ValueKey('desktop_volume_popover_button'),
      );
      await tester.tap(popoverButton);
      await tester.pump();

      final muteBtn = find.byKey(const ValueKey('volume_popover_mute_button'));
      await tester.tap(muteBtn);
      await tester.pump();

      expect(player.volume, 0.0);
      expect(find.text('0%'), findsOneWidget);

      // 再次点击恢复 70%
      await tester.tap(muteBtn);
      await tester.pump();

      expect(player.volume, 0.7);
      expect(find.text('70%'), findsOneWidget);
    });

    testWidgets('非阻塞关闭：弹层打开时点击上一首，上一首正常触发且弹层收起', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..volume = 0.7;
      await _pumpBar(tester, player);

      final popoverButton = find.byKey(
        const ValueKey('desktop_volume_popover_button'),
      );
      await tester.tap(popoverButton);
      await tester.pump();
      expect(find.text('70%'), findsOneWidget);

      // 点击外部的“上一首”按钮
      final prevBtn = find.byTooltip('上一首');
      await tester.tap(prevBtn);
      await tester.pump();

      // 弹层已收起且上一首触发
      expect(player.previousCalls, 1);
      expect(find.text('70%'), findsNothing);
    });

    testWidgets('音量条拖拽仍然生效', (tester) async {
      final player = _FakePlayerController()..volume = 0.2;
      await _pumpBar(tester, player);

      final popoverButton = find.byKey(
        const ValueKey('desktop_volume_popover_button'),
      );
      await tester.tap(popoverButton);
      await tester.pump();

      final slider = find.byType(Slider);
      expect(slider, findsOneWidget);
      await tester.drag(slider, const Offset(0, -40));
      await tester.pump();

      expect(player.volumeChanges, isNotEmpty);
      expect(player.volume, greaterThan(0.2));
    });

    testWidgets('音量条拖拽过程中实时更新百分比并在松手后恢复同步', (tester) async {
      final player = _FakePlayerController()..volume = 0.2;
      await _pumpBar(tester, player);

      final popoverButton = find.byKey(
        const ValueKey('desktop_volume_popover_button'),
      );
      await tester.tap(popoverButton);
      await tester.pump();

      expect(find.text('20%'), findsOneWidget);

      final slider = find.byType(Slider);
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();

      // 拖拽中百分比已实时变动（不再是 20%）
      expect(find.text('20%'), findsNothing);
      expect(player.volumeChanges, isNotEmpty);

      // 松手结束拖拽
      await gesture.up();
      await tester.pump();

      // 弹层仍然显示当前最终音量百分比
      final currentPercent = '${(player.volume * 100).round()}%';
      expect(find.text(currentPercent), findsOneWidget);
    });

    testWidgets('滚轮在音量入口按钮或弹层卡片上微调音量', (tester) async {
      final player = _FakePlayerController()..volume = 0.8;
      await _pumpBar(tester, player);

      final popoverButton = find.byKey(
        const ValueKey('desktop_volume_popover_button'),
      );
      final buttonCenter = tester.getCenter(popoverButton);
      final pointer = TestPointer(7, PointerDeviceKind.mouse);
      pointer.hover(buttonCenter);

      // 在入口按钮上向上滚 +5%
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
      await tester.pump();
      expect(player.volume, closeTo(0.85, 0.0001));

      // 向下滚 -5%
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await tester.pump();
      expect(player.volume, closeTo(0.8, 0.0001));

      // 打开弹层并在弹层卡片上向下滚
      await tester.tap(popoverButton);
      await tester.pump();
      expect(find.text('80%'), findsOneWidget);

      final cardCenter = tester.getCenter(find.text('80%'));
      pointer.hover(cardCenter);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await tester.pump();
      expect(player.volume, closeTo(0.75, 0.0001));
      expect(find.text('75%'), findsOneWidget);
    });
  });

  group('进度条', () {
    testWidgets('进度条最大宽度约束在 440px 居中', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..duration = const Duration(minutes: 3);
      await _pumpBar(tester, player);

      final progressFinder = find.ancestor(
        of: find.byType(Slider).first,
        matching: find.byType(SliderTheme),
      );
      expect(progressFinder, findsOneWidget);
      final size = tester.getSize(progressFinder);
      expect(size.width, lessThanOrEqualTo(440));
    });
  });

  group('进度悬停时间气泡', () {
    testWidgets('悬停显示对应时间，拖拽中隐藏，离开消失', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..duration = const Duration(minutes: 2);
      await _pumpBar(tester, player);

      final bubble = find.byKey(const ValueKey('hover_time_bubble'));
      expect(bubble, findsNothing);

      // 鼠标悬停在进度条中点 → 气泡显示 01:00。
      final mouse = TestPointer(9, PointerDeviceKind.mouse);
      final trackCenter = tester.getCenter(find.byType(Slider).first);
      await tester.sendEventToBinding(mouse.hover(trackCenter));
      await tester.pumpAndSettle();

      expect(bubble, findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.descendant(of: bubble, matching: find.byType(Text)),
            )
            .data,
        '01:00',
      );

      // 拖拽中：气泡隐藏。
      final drag = await tester.startGesture(trackCenter);
      await drag.moveBy(const Offset(56, 0));
      await tester.pump();
      expect(bubble, findsNothing);
      await drag.up();
      await tester.pump();
      // 松手后鼠标仍在原处，气泡恢复显示。
      expect(bubble, findsOneWidget);

      // 鼠标移开 → 气泡消失。
      await tester.sendEventToBinding(mouse.hover(const Offset(10, 10)));
      await tester.pump();
      expect(bubble, findsNothing);
    });
  });

  group('桌面歌词按钮', () {
    testWidgets('桌面歌词开启且锁定时仍展示歌词图标，点击可隐藏且不改锁定状态', (
      tester,
    ) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..isDesktopLyricsSupported = true
        ..desktopLyricsEnabled = true
        ..desktopLyricsLocked = true;
      await _pumpBar(tester, player);

      expect(find.byIcon(Icons.lyrics_rounded), findsOneWidget);
      expect(find.byTooltip('关闭桌面歌词'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭桌面歌词'));
      await tester.pump();

      expect(player.setDesktopLyricsEnabledCalls, 1);
      expect(player.desktopLyricsEnabled, isFalse);
      expect(player.desktopLyricsLocked, isTrue);
      expect(player.unlockDesktopLyricsCalls, 0);
      expect(find.byIcon(Icons.lyrics_outlined), findsOneWidget);
      expect(find.byTooltip('开启桌面歌词'), findsOneWidget);
    });

    testWidgets('桌面歌词未开启时展示空心图标，点击开启', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..isDesktopLyricsSupported = true
        ..desktopLyricsEnabled = false;
      await _pumpBar(tester, player);

      expect(find.byIcon(Icons.lyrics_outlined), findsOneWidget);
      expect(find.byTooltip('开启桌面歌词'), findsOneWidget);

      await tester.tap(find.byTooltip('开启桌面歌词'));
      await tester.pump();

      expect(player.setDesktopLyricsEnabledCalls, 1);
      expect(player.desktopLyricsEnabled, isTrue);
    });

    testWidgets('桌面歌词开启时展示实心图标，点击关闭', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..isDesktopLyricsSupported = true
        ..desktopLyricsEnabled = true
        ..desktopLyricsLocked = false;
      await _pumpBar(tester, player);

      expect(find.byIcon(Icons.lyrics_rounded), findsOneWidget);
      expect(find.byTooltip('关闭桌面歌词'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭桌面歌词'));
      await tester.pump();

      expect(player.setDesktopLyricsEnabledCalls, 1);
      expect(player.desktopLyricsEnabled, isFalse);
    });

    testWidgets('无歌曲时按钮禁用', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = null
        ..isDesktopLyricsSupported = true
        ..desktopLyricsEnabled = true
        ..desktopLyricsLocked = true;
      await _pumpBar(tester, player);

      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.lyrics_rounded),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('平台不支持时不渲染桌面歌词按钮', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..isDesktopLyricsSupported = false;
      await _pumpBar(tester, player);

      expect(find.byTooltip('开启桌面歌词'), findsNothing);
      expect(find.byTooltip('关闭桌面歌词'), findsNothing);
      expect(find.byIcon(Icons.lyrics_rounded), findsNothing);
      expect(find.byIcon(Icons.lyrics_outlined), findsNothing);
    });
  });

  group('音质切换按钮', () {
    testWidgets('有歌曲时渲染音质按钮，tooltip 包含音质切换提示且显示当前音质短标签', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..audioQuality = AudioQuality.standard;
      await _pumpBar(tester, player);

      // 默认标准音质：短标签展示“标准”，tooltip 包含“音质”
      expect(find.text('标准'), findsOneWidget);
      final tooltipFinder = find.byWidgetPredicate(
        (w) =>
            w is Tooltip &&
            ((w.message?.contains('音质') ?? false) ||
                (w.message?.contains('切换音质') ?? false)),
      );
      expect(tooltipFinder, findsOneWidget);

      // 高品音质
      player.audioQuality = AudioQuality.high;
      player.notifyListeners();
      await tester.pump();
      expect(find.text('高品'), findsOneWidget);

      // 无损音质，显示无损与 SQ 标识
      player.audioQuality = AudioQuality.lossless;
      player.notifyListeners();
      await tester.pump();
      expect(find.text('无损'), findsOneWidget);
      expect(find.text('SQ'), findsOneWidget);
    });

    testWidgets('无歌曲时音质按钮禁用', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = null
        ..audioQuality = AudioQuality.standard;
      await _pumpBar(tester, player);

      final buttonFinder = find.byKey(
        const ValueKey('desktop_audio_quality_button'),
      );
      expect(buttonFinder, findsOneWidget);

      final inkWell = tester.widget<InkWell>(
        find.descendant(of: buttonFinder, matching: find.byType(InkWell)),
      );
      expect(inkWell.onTap, isNull);

      // 点击禁用按钮不弹出对话框
      await tester.tap(buttonFinder);
      await tester.pump();
      expect(find.text('切换音质'), findsNothing);
      expect(player.setAudioQualityCalls, 0);
    });

    testWidgets('点击音质按钮弹出音质切换对话框并支持选择', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..audioQuality = AudioQuality.standard;
      await _pumpBar(tester, player);

      final buttonFinder = find.byKey(
        const ValueKey('desktop_audio_quality_button'),
      );
      await tester.tap(buttonFinder);
      await tester.pumpAndSettle();

      // 弹出对话框
      expect(find.text('切换音质'), findsOneWidget);
      expect(find.text('高品音质'), findsOneWidget);

      // 点击高品音质
      await tester.tap(find.text('高品音质'));
      await tester.pumpAndSettle();

      expect(player.setAudioQualityCalls, 1);
      expect(player.lastSetAudioQuality, AudioQuality.high);
      expect(player.lastReloadCurrent, isTrue);
    });
  });

  group('左区歌曲信息与操作行', () {
    testWidgets('展示 48x48 封面、单行跑马灯歌名-歌手及操作行按钮', (tester) async {
      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(tester, player);

      // 封面 48x48
      final artworkFinder = find.byType(Artwork);
      expect(artworkFinder, findsOneWidget);
      final artworkWidget = tester.widget<Artwork>(artworkFinder);
      expect(artworkWidget.size, 48);

      // 单行跑马灯 MarqueeText
      expect(find.byType(MarqueeText), findsOneWidget);
      expect(find.text('测试歌曲 - 测试歌手', findRichText: true), findsOneWidget);

      // 操作行包含喜欢、评论、更多操作按钮
      expect(find.byTooltip('喜欢'), findsOneWidget);
      expect(find.byTooltip('暂无评论'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('desktop_song_more_button')),
        findsOneWidget,
      );
      expect(find.byTooltip('更多操作'), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    });

    testWidgets('有评论接口时拉取评论数并显示右上角角标', (tester) async {
      final commentApi = _FakeCommentApi(count: 169);
      final player = _FakePlayerController()
        ..currentSong = _song
        ..commentApi = commentApi;
      await _pumpBar(tester, player, onOpenComment: (_) {});

      await tester.pumpAndSettle();
      expect(commentApi.calls, 1);
      expect(find.text('169'), findsOneWidget);
    });

    testWidgets('评论数拉取失败时静默降级为无角标气泡', (tester) async {
      final commentApi = _FakeCommentApi(); // count 为空 → 模拟服务不可用
      // 独立歌曲 id：避免命中上一条测试留下的评论数会话缓存
      const song = Song(id: 'no-comment', title: '无声曲', artist: '某人', hash: 'h2');
      final player = _FakePlayerController()
        ..currentSong = song
        ..commentApi = commentApi;
      await _pumpBar(tester, player, onOpenComment: (_) {});

      await tester.pumpAndSettle();
      expect(find.text('169'), findsNothing);
      // 气泡图标本体仍渲染（无缺口样式）
      expect(find.byType(CommentBubbleIcon), findsOneWidget);
      final bubble = tester.widget<CommentBubbleIcon>(
        find.byType(CommentBubbleIcon),
      );
      expect(bubble.showBadgeGap, isFalse);
    });

    test('评论数按紧凑规范格式化展示（方案 A：999+ / xxw+ / 99w+ 封顶）', () {
      expect(formatCommentCount(0), '0');
      expect(formatCommentCount(169), '169');
      expect(formatCommentCount(999), '999');
      expect(formatCommentCount(1000), '999+');
      expect(formatCommentCount(9999), '999+');
      expect(formatCommentCount(10000), '1w+');
      expect(formatCommentCount(16800), '1w+');
      expect(formatCommentCount(167000), '16w+');
      expect(formatCommentCount(989999), '98w+');
      expect(formatCommentCount(990000), '99w+');
      expect(formatCommentCount(120000000), '99w+');
    });

    testWidgets('无歌曲时展示"尚未播放"，更多操作按钮禁用', (tester) async {
      final player = _FakePlayerController()..currentSong = null;
      await _pumpBar(tester, player);

      expect(find.text('尚未播放', findRichText: true), findsOneWidget);

      final moreBtn = tester.widget<IconButton>(
        find.byKey(const ValueKey('desktop_song_more_button')),
      );
      expect(moreBtn.onPressed, isNull);
    });

    testWidgets('点击更多操作按钮（···）使用 anchorAbove 弹出菜单且包含各项操作', (tester) async {
      debugDesktopFormFactorOverride = true;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      final downloadCtrl = _FakeDownloadController();
      final player = _FakePlayerController()
        ..currentSong = _song
        ..downloadController = downloadCtrl;
      await _pumpBar(tester, player);

      final moreBtn = find.byKey(const ValueKey('desktop_song_more_button'));
      expect(moreBtn, findsOneWidget);

      await tester.tap(moreBtn);
      await tester.pumpAndSettle();

      // 弹出菜单中包含全部 QQ 音乐风格扩展操作
      // 「下一首播放」在底栏无意义（就是当前歌曲），已移除
      expect(find.text('下一首播放'), findsNothing);
      expect(find.text('添加到歌单'), findsOneWidget);
      expect(find.text('试听高潮'), findsOneWidget);
      expect(find.text('倍速播放'), findsOneWidget);
      expect(find.text('定时播放'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('查看歌手'), findsOneWidget);
      // 原「复制歌曲信息」列表项已合并为菜单头部「分享歌曲」单入口。
      expect(find.text('复制歌曲信息'), findsNothing);
      expect(find.byTooltip('分享歌曲'), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
    });

    testWidgets('点击更多菜单中的"试听高潮"调用 player.playClimaxPreview', (tester) async {
      debugDesktopFormFactorOverride = true;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(tester, player);

      await tester.tap(find.byKey(const ValueKey('desktop_song_more_button')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('试听高潮'));
      await tester.pumpAndSettle();

      expect(player.playClimaxPreviewCalls, 1);
    });

    testWidgets('更多操作按钮呈现圆形线框包裹视觉', (tester) async {
      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(tester, player);

      final moreBtn = find.byKey(const ValueKey('desktop_song_more_button'));
      expect(moreBtn, findsOneWidget);

      final circleContainer = find.descendant(
        of: moreBtn,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
      );
      expect(circleContainer, findsOneWidget);
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    });

    testWidgets('点击更多菜单中的"倍速播放"弹出二级菜单而非对话框', (tester) async {
      debugDesktopFormFactorOverride = true;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(tester, player);

      await tester.tap(find.byKey(const ValueKey('desktop_song_more_button')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('倍速播放'));
      await tester.pumpAndSettle();

      // 级联：一级仍可见，右侧二级列出档位；不出现 Dialog
      expect(find.text('倍速播放'), findsWidgets);
      expect(find.text('0.5x'), findsOneWidget);
      expect(find.text('1x'), findsOneWidget);
      expect(find.text('2x'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsWidgets);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('悬停"倍速播放"延时后展开二级，一级菜单保持可见', (tester) async {
      debugDesktopFormFactorOverride = true;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(tester, player);

      await tester.tap(find.byKey(const ValueKey('desktop_song_more_button')));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.text('倍速播放')));
      // 未到悬停延迟：二级尚未出现
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('0.5x'), findsNothing);
      // Tooltip 会再挂一份同文案 Text，故用 findsWidgets
      expect(find.text('倍速播放'), findsWidgets);

      // 越过悬停延迟：先触发定时器重建，再等一帧完成二级测量定位
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('0.5x'), findsOneWidget);
      expect(find.text('倍速播放'), findsWidgets);
      expect(find.text('添加到歌单'), findsWidgets);

      // 移到无二级的一级项：二级应立即收起，一级仍在
      await gesture.moveTo(tester.getCenter(find.text('添加到歌单')));
      await tester.pump();
      await tester.pump();
      expect(find.text('0.5x'), findsNothing);
      expect(find.text('添加到歌单'), findsWidgets);
      expect(find.text('倍速播放'), findsWidgets);
    });

    testWidgets('点击更多菜单中的"定时播放"弹出二级菜单而非对话框', (tester) async {
      debugDesktopFormFactorOverride = true;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(tester, player);

      await tester.tap(find.byKey(const ValueKey('desktop_song_more_button')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('定时播放'));
      await tester.pumpAndSettle();

      expect(find.text('到点立即暂停'), findsOneWidget);
      expect(find.text('到点后听完这首'), findsOneWidget);
      expect(find.text('15 分钟'), findsOneWidget);
      expect(find.text('30 分钟'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('定时二级单选「到点后听完这首」会记住偏好且菜单不关', (tester) async {
      debugDesktopFormFactorOverride = true;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(tester, player);

      await tester.tap(find.byKey(const ValueKey('desktop_song_more_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('定时播放'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('到点后听完这首'));
      await tester.pumpAndSettle();

      expect(player.updateSleepTimerOptionCalls, 1);
      expect(player.sleepFinishCurrentSongOption, isTrue);
      // 单选项不关闭菜单，仍可接着选时长
      expect(find.text('15 分钟'), findsOneWidget);
      expect(find.text('到点立即暂停'), findsOneWidget);
    });

    testWidgets('点击更多菜单头部的"分享歌曲"写入统一分享文案', (tester) async {
      debugDesktopFormFactorOverride = true;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            copiedText = (methodCall.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(tester, player);

      await tester.tap(find.byKey(const ValueKey('desktop_song_more_button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('分享歌曲'));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      // 与移动端/车机共用 song_share.dart 的统一文案（含「来自 时音」品牌行）。
      expect(copiedText, buildSongShareText(_song));
      expect(copiedText, contains('来自 时音'));
    });
  });

  group('底栏全域空白点击进入播放页', () {
    testWidgets('有歌曲时，点击底栏非交互空白区域触发进入全屏播放页', (tester) async {
      int openCalls = 0;
      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(
        tester,
        player,
        onOpenPlayerPage: () => openCalls++,
      );

      // 点击底栏最左侧空白边距 (x: 4, y: 860)
      await tester.tapAt(const Offset(4, 860));
      await tester.pump();
      expect(openCalls, 1);

      // 点击歌曲标题跑马灯区域也可以进入播放页
      await tester.tap(find.byType(MarqueeText));
      await tester.pump();
      expect(openCalls, 2);
    });

    testWidgets('点击具名控制按钮不触发进入全屏播放页', (tester) async {
      int openCalls = 0;
      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(
        tester,
        player,
        onOpenPlayerPage: () => openCalls++,
      );

      // 点击下一首
      await tester.tap(find.byTooltip('下一首'));
      await tester.pump();
      expect(openCalls, 0);

      // 点击播放模式
      await tester.tap(find.byTooltip('列表循环（点击切换）'));
      await tester.pump();
      expect(openCalls, 0);

      // 点击喜欢
      await tester.tap(find.byTooltip('喜欢'));
      await tester.pump();
      expect(openCalls, 0);
    });

    testWidgets('无歌曲时，点击空白处不触发进入全屏播放页', (tester) async {
      int openCalls = 0;
      final player = _FakePlayerController()..currentSong = null;
      await _pumpBar(
        tester,
        player,
        onOpenPlayerPage: () => openCalls++,
      );

      await tester.tapAt(const Offset(4, 860));
      await tester.pump();
      expect(openCalls, 0);
    });
  });

  // 播放页底部复用同一条底栏，靠这几个开关切换成「页内态」。
  group('播放页内嵌模式（收起 / 禁止再进播放页）', () {
    testWidgets('传 onCollapse 时最左侧渲染收起键且位于歌曲信息左侧，点击触发返回', (tester) async {
      int collapseCalls = 0;
      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(
        tester,
        player,
        onCollapse: () => collapseCalls++,
      );

      final collapseBtn = find.byTooltip('收起播放页');
      expect(collapseBtn, findsOneWidget);
      // 播放页内嵌态不渲染封面，收起键顶替封面位置（QQ 音乐 PC 式）
      expect(find.byType(Artwork), findsNothing);
      // 最左：收起键在歌曲信息（歌名跑马灯）左侧
      expect(
        tester.getTopLeft(collapseBtn).dx,
        lessThan(tester.getTopLeft(find.byType(MarqueeText)).dx),
      );

      await tester.tap(collapseBtn);
      await tester.pump();
      expect(collapseCalls, 1);
    });

    testWidgets('主界面底栏（无 onCollapse）正常渲染封面，播放页内嵌则不渲染', (tester) async {
      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(tester, player);
      expect(find.byType(Artwork), findsOneWidget);

      await _pumpBar(tester, player, onCollapse: () {});
      expect(find.byType(Artwork), findsNothing);
    });

    testWidgets('openPlayerPageEnabled=false 时点击底栏空白与歌曲信息都不再进入播放页', (tester) async {
      int openCalls = 0;
      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(
        tester,
        player,
        onOpenPlayerPage: () => openCalls++,
        openPlayerPageEnabled: false,
      );

      await tester.tapAt(const Offset(4, 860));
      await tester.pump();
      await tester.tap(find.byType(MarqueeText));
      await tester.pump();
      expect(openCalls, 0);
      // 不可展开时也不再提示「展开歌曲详情页」
      expect(find.byTooltip('展开歌曲详情页'), findsNothing);
    });

    testWidgets('overlayDark 下底栏前景翻为浅色（深底可见），播放键仍点品牌色', (tester) async {
      final player = _FakePlayerController()..currentSong = _song;
      await _pumpBar(
        tester,
        player,
        onCollapse: () {},
        overlayDark: true,
      );

      // 收起键：对角双直角图标（右上└ + 左下┐，QQ 音乐 PC 截图同款），白色前景
      final collapseIcon = tester.widget<ExpandDetailIcon>(
        find.descendant(
          of: find.byTooltip('收起播放页'),
          matching: find.byType(ExpandDetailIcon),
        ),
      );
      expect(collapseIcon.color, Colors.white);
      expect(collapseIcon.size, 22);

      // 相邻控制键：同样拿到浅色前景，证明确保局部主题覆写已下发到子部件
      // （PlayModeButton / VolumePopoverButton 这些共用件只读 Theme）
      final prevButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('上一首'),
          matching: find.byType(IconButton),
        ),
      );
      expect(prevButton.color, Colors.white);

      // 播放键仍沿用品牌色：沉浸深色只翻承载色，不整体反转
      final playButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('播放'),
          matching: find.byType(IconButton),
        ),
      );
      expect(playButton.color, isNot(Colors.white));
    });
  });
}
