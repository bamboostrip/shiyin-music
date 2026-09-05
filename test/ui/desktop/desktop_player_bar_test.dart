import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart' hide formatDuration;
import 'package:shiyin_music/ui/desktop/desktop_player_bar.dart';

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? currentSong;
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
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  int cyclePlaybackModeCalls = 0;
  List<double> volumeChanges = [];

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
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _song = Song(id: '1', title: '测试歌曲', artist: '测试歌手', hash: 'hash-1');

Future<void> _pumpBar(WidgetTester tester, _FakePlayerController player) async {
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
            auth: _FakeAuthController(),
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

  group('音量图标', () {
    testWidgets('点击静音并记忆音量，再次点击恢复', (tester) async {
      final player = _FakePlayerController()..volume = 0.8;
      await _pumpBar(tester, player);

      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      expect(find.byTooltip('静音'), findsOneWidget);

      await tester.tap(find.byTooltip('静音'));
      await tester.pump();

      expect(player.volume, 0.0);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      expect(find.byTooltip('取消静音'), findsOneWidget);

      await tester.tap(find.byTooltip('取消静音'));
      await tester.pump();

      expect(player.volume, 0.8);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    });

    testWidgets('滚轮在图标区 ±5% 微调并钳制边界', (tester) async {
      final player = _FakePlayerController()..volume = 0.8;
      await _pumpBar(tester, player);

      final iconCenter = tester.getCenter(find.byTooltip('静音'));
      final pointer = TestPointer(7, PointerDeviceKind.mouse);
      pointer.hover(iconCenter);

      // 向上滚 +5%
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
      await tester.pump();
      expect(player.volume, closeTo(0.85, 0.0001));

      // 向下滚 -5%
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await tester.pump();
      expect(player.volume, closeTo(0.8, 0.0001));

      // 连续向下滚钳制到 0
      for (var i = 0; i < 25; i++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      }
      await tester.pump();
      expect(player.volume, 0.0);
    });

    testWidgets('音量条拖拽仍然生效（既有行为保持）', (tester) async {
      final player = _FakePlayerController()..volume = 0.2;
      await _pumpBar(tester, player);

      // 无歌曲时进度区不渲染，页面上唯一的 Slider 就是音量条。
      final sliders = find.byType(Slider);
      expect(sliders, findsOneWidget);
      await tester.drag(sliders, const Offset(80, 0));
      await tester.pump();

      expect(player.volumeChanges, isNotEmpty);
      expect(player.volume, greaterThan(0.2));
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
      expect(tester.widget<Text>(find.descendant(
        of: bubble,
        matching: find.byType(Text),
      )).data, '01:00');

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
    testWidgets('桌面歌词开启且锁定时展示锁定图标与一键解锁 tooltip，点击触发解锁', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..isDesktopLyricsSupported = true
        ..desktopLyricsEnabled = true
        ..desktopLyricsLocked = true;
      await _pumpBar(tester, player);

      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      expect(find.byTooltip('桌面歌词已锁定，点击一键解锁'), findsOneWidget);

      await tester.tap(find.byTooltip('桌面歌词已锁定，点击一键解锁'));
      await tester.pump();

      expect(player.unlockDesktopLyricsCalls, 1);
      expect(player.desktopLyricsLocked, isFalse);
      expect(find.byIcon(Icons.lyrics_rounded), findsOneWidget);
      expect(find.byTooltip('关闭桌面歌词'), findsOneWidget);
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

    testWidgets('桌面歌词开启且未锁定时展示实心图标，点击关闭', (tester) async {
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
        find.widgetWithIcon(IconButton, Icons.lock_rounded),
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
      expect(find.byTooltip('桌面歌词已锁定，点击一键解锁'), findsNothing);
    });
  });

  group('音质切换按钮', () {
    testWidgets(
      '有歌曲时渲染音质按钮，tooltip 包含音质切换提示且显示当前音质短标签',
      (tester) async {
        final player = _FakePlayerController()
          ..currentSong = _song
          ..audioQuality = AudioQuality.standard;
        await _pumpBar(tester, player);

        // 默认标准音质：短标签展示“标准”，tooltip 包含“音质”
        expect(find.text('标准'), findsOneWidget);
        final tooltipFinder = find.byWidgetPredicate(
          (w) => w is Tooltip && ((w.message?.contains('音质') ?? false) || (w.message?.contains('切换音质') ?? false)),
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
      },
    );

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
}


