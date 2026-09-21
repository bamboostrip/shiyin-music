import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/player_page.dart';

/// 播放页「保持屏幕常亮」的行为契约。
///
/// 原生实现只在 Android（`MainActivity.kt` 的 `shiyin_music/screen` 通道 →
/// `FLAG_KEEP_SCREEN_ON`）。历史实现进页面就无条件
/// `setKeepScreenOn(true)`，且之后再也不碰——`FLAG_KEEP_SCREEN_ON` 只关心
/// 窗口是否可见、与播放状态无关，于是暂停/停播后停在播放页依然不会息屏。
///
/// 现在收敛为「用户开关 **且** 正在播放」，这些用例锁住：
/// - 播放中才置常亮，暂停/停播立刻交回系统休眠；
/// - 开关关闭后播放中也不常亮；
/// - 状态未变时不重复打平台通道（playerStateStream 每次变化都会 notify）；
/// - 离开播放页必定清 flag，不留悬挂。
class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? currentSong = const Song(
    id: '1001',
    hash: 'hash1001',
    title: '夜曲',
    artist: '周杰伦',
    duration: Duration(minutes: 3, seconds: 46),
  );

  @override
  bool isPlaying = true;

  @override
  bool keepScreenOnEnabled = true;

  @override
  Duration duration = const Duration(minutes: 3, seconds: 46);

  @override
  Duration position = const Duration(seconds: 15);

  @override
  Duration get smoothPosition => position;

  @override
  List<LyricLine> lyrics = List.generate(
    30,
    (i) => LyricLine(
      time: Duration(seconds: i * 5),
      text: '这是第 ${i + 1} 句歌词，为你弹奏萧邦的夜曲',
    ),
  );

  @override
  int activeLyricIndex = 3;

  @override
  bool isPreparing = false;

  @override
  bool isScrubbing = false;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier(const Duration(seconds: 15));

  @override
  SongClimax? climax;

  @override
  double volume = 0.8;

  @override
  String get playbackModeLabel => '列表循环';

  @override
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;

  @override
  AudioQuality audioQuality = AudioQuality.standard;

  @override
  bool isDesktopLyricsSupported = false;

  @override
  bool desktopLyricsEnabled = false;

  @override
  bool desktopLyricsLocked = false;

  @override
  bool isAudioEffectsSupported = false;

  @override
  bool isSleepTimerActive = false;

  @override
  bool isSleepFinishCurrentSong = false;

  @override
  String playbackSpeedLabel = '1.0X';

  @override
  String audioEffectsLabel = '无音效';

  @override
  Future<void> seek(Duration pos) async {
    position = pos;
    positionListenable.value = pos;
    notifyListeners();
  }

  @override
  Future<void> seekToAndPlay(Duration pos) async => seek(pos);

  @override
  Future<void> togglePlay() async => setPlaying(!isPlaying);

  @override
  Future<void> ensureLyricsLoaded() async {}

  /// 模拟引擎上报播放/暂停（真实链路上 playerStateStream 会 notifyListeners）。
  void setPlaying(bool value) {
    if (isPlaying == value) return;
    isPlaying = value;
    notifyListeners();
  }

  /// 模拟用户在设置里拨开关。
  void setKeepScreenOn(bool value) {
    if (keepScreenOnEnabled == value) return;
    keepScreenOnEnabled = value;
    notifyListeners();
  }

  /// 模拟与常亮无关的状态变化（音量、队列等）：只通知，不改常亮条件。
  void notifyUnrelatedChange() => notifyListeners();

  // 歌词进度偏移（PlayerController 接口）：测试默认零偏移。
  @override
  Duration get lyricPosition => smoothPosition;

  @override
  Duration lyricOffset = Duration.zero;

  @override
  bool get hasLyricOffset => false;

  @override
  String get lyricOffsetLabel => '无偏移';

  @override
  Future<void> adjustLyricOffset(Duration delta) async {}

  @override
  Future<void> resetLyricOffset() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  Future<void> toggleLike(Song song) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const screenChannel = MethodChannel('shiyin_music/screen');
  late List<bool> screenCalls;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    screenCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, (call) async {
          if (call.method == 'setKeepScreenOn') {
            screenCalls.add(call.arguments as bool);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, null);
    debugDesktopFormFactorOverride = null;
  });

  Future<void> pumpPlayerPage(
    WidgetTester tester,
    _FakePlayerController player,
  ) async {
    debugDesktopFormFactorOverride = true;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(home: PlayerPage(player: player, auth: _FakeAuthController())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /* 离开播放页：换成空 widget 触发 dispose。 */
  Future<void> unmountPlayerPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
  }

  group('播放页保持屏幕常亮', () {
    testWidgets('播放中进入播放页：置为常亮', (tester) async {
      final player = _FakePlayerController()..isPlaying = true;

      await pumpPlayerPage(tester, player);

      expect(screenCalls, [true]);
    });

    testWidgets('暂停后交回系统休眠（历史实现的常亮永不解除）', (tester) async {
      final player = _FakePlayerController()..isPlaying = true;
      await pumpPlayerPage(tester, player);
      expect(screenCalls, [true]);

      player.setPlaying(false);
      await tester.pump();

      expect(screenCalls, [true, false]);
    });

    testWidgets('恢复播放后重新常亮', (tester) async {
      final player = _FakePlayerController()..isPlaying = true;
      await pumpPlayerPage(tester, player);

      player.setPlaying(false);
      await tester.pump();
      player.setPlaying(true);
      await tester.pump();

      expect(screenCalls, [true, false, true]);
    });

    testWidgets('暂停态进入播放页：一次都不置常亮', (tester) async {
      final player = _FakePlayerController()..isPlaying = false;

      await pumpPlayerPage(tester, player);

      expect(screenCalls, isEmpty);
    });

    testWidgets('开关关闭：播放中也不常亮', (tester) async {
      final player = _FakePlayerController()
        ..isPlaying = true
        ..keepScreenOnEnabled = false;

      await pumpPlayerPage(tester, player);

      expect(screenCalls, isEmpty);
    });

    testWidgets('播放中关掉开关：立刻解除常亮', (tester) async {
      final player = _FakePlayerController()..isPlaying = true;
      await pumpPlayerPage(tester, player);
      expect(screenCalls, [true]);

      player.setKeepScreenOn(false);
      await tester.pump();

      expect(screenCalls, [true, false]);
    });

    testWidgets('播放中打开开关：恢复常亮', (tester) async {
      final player = _FakePlayerController()
        ..isPlaying = true
        ..keepScreenOnEnabled = false;
      await pumpPlayerPage(tester, player);
      expect(screenCalls, isEmpty);

      player.setKeepScreenOn(true);
      await tester.pump();

      expect(screenCalls, [true]);
    });

    testWidgets('无关状态变化不重复打平台通道', (tester) async {
      final player = _FakePlayerController()..isPlaying = true;
      await pumpPlayerPage(tester, player);
      expect(screenCalls, [true]);

      // playerStateStream 之外的通知（音量、队列等）不该重复下发。
      player.notifyUnrelatedChange();
      player.notifyUnrelatedChange();
      await tester.pump();

      expect(screenCalls, [true]);
    });

    testWidgets('离开播放页必定清掉常亮 flag', (tester) async {
      final player = _FakePlayerController()..isPlaying = true;
      await pumpPlayerPage(tester, player);
      expect(screenCalls, [true]);

      await unmountPlayerPage(tester);

      expect(screenCalls, [true, false]);
    });

    testWidgets('从未常亮过时离开页面不重复清 flag', (tester) async {
      final player = _FakePlayerController()..isPlaying = false;
      await pumpPlayerPage(tester, player);

      await unmountPlayerPage(tester);

      expect(screenCalls, isEmpty);
    });

    testWidgets('离开页面后播放器再通知不会打平台通道（监听已摘除）', (tester) async {
      final player = _FakePlayerController()..isPlaying = true;
      await pumpPlayerPage(tester, player);
      await unmountPlayerPage(tester);
      expect(screenCalls, [true, false]);

      player.setPlaying(false);
      player.setPlaying(true);
      await tester.pump();

      expect(screenCalls, [true, false]);
    });
  });
}
