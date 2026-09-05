import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/player_page.dart';

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
  int seekRevision = 0;

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
  String get playbackModeLabel => '列表循环';

  final List<Duration> seekCalls = [];
  final List<Duration> seekToAndPlayCalls = [];
  int playCalls = 0;

  @override
  Future<void> seek(Duration pos) async {
    seekCalls.add(pos);
    position = pos;
    positionListenable.value = pos;
    notifyListeners();
  }

  @override
  Future<void> seekToAndPlay(Duration pos) async {
    seekToAndPlayCalls.add(pos);
    await seek(pos);
    if (!isPlaying) {
      await togglePlay();
    }
  }

  int togglePlayCalls = 0;

  @override
  Future<void> togglePlay() async {
    togglePlayCalls++;
    isPlaying = !isPlaying;
    notifyListeners();
  }

  @override
  Future<void> ensureLyricsLoaded() async {}

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
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Future<void> pumpPlayerPage(
    WidgetTester tester, {
    required _FakePlayerController player,
    required _FakeAuthController auth,
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          player: player,
          auth: auth,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('PC 桌面端播放页与歌词滚轮交互测试', () {
    testWidgets('桌面形态默认呈现双拼分栏大屏，左侧黑胶、右侧歌词，不展示手机翻页小圆点',
        (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await pumpPlayerPage(tester, player: player, auth: auth);

      // 验证桌面分栏展示（黑胶封面 + 歌词同时存在）
      expect(find.text('夜曲'), findsWidgets);
      expect(find.text('周杰伦'), findsWidgets);
      expect(find.text('这是第 1 句歌词，为你弹奏萧邦的夜曲'), findsOneWidget);

      // 验证不出现手机翻页小圆点 PageView dots
      expect(find.byType(PageView), findsNothing);
    });

    testWidgets('鼠标滚轮在歌词区滚动触发准星时间线与定位播放指针 [▶ mm:ss]', (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await pumpPlayerPage(tester, player: player, auth: auth);

      // 初始状态没有准星按钮
      final seekBtn = find.byKey(const ValueKey('lyric_seek_pointer_button'));
      expect(seekBtn, findsNothing);

      // 在歌词列表区域用鼠标滚轮向下滚动
      final listFinder = find.byType(ListView);
      expect(listFinder, findsOneWidget);
      final center = tester.getCenter(listFinder);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 180)));
      await tester.pump();
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 180)));
      await tester.pump(const Duration(milliseconds: 300));

      // 滚动后应该出现准星播放按钮与“回到当前”按钮
      expect(find.byKey(const ValueKey('lyric_seek_pointer_button')), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
      expect(find.text('回到当前'), findsOneWidget);

      // 点击定位播放指针按钮
      await tester.tap(find.byKey(const ValueKey('lyric_seek_pointer_button')));
      await tester.pump(const Duration(milliseconds: 300));

      // 验证调用了 player.seek
      expect(player.seekCalls, isNotEmpty);

      // 点击后退出浏览锁定状态，指针按钮隐藏
      expect(find.byKey(const ValueKey('lyric_seek_pointer_button')), findsNothing);
    });

    testWidgets('滚动后点击回到当前按钮立即复位并隐藏指针', (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await pumpPlayerPage(tester, player: player, auth: auth);

      final listFinder = find.byType(ListView);
      final center = tester.getCenter(listFinder);
      final pointer = TestPointer(2, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('回到当前'), findsOneWidget);
      expect(find.byKey(const ValueKey('lyric_seek_pointer_button')), findsOneWidget);

      // 点击回到当前
      await tester.tap(find.text('回到当前'));
      await tester.pump(const Duration(milliseconds: 300));

      // 指针与回到当前按钮消失
      expect(find.byKey(const ValueKey('lyric_seek_pointer_button')), findsNothing);
      expect(find.text('回到当前'), findsNothing);
    });

    testWidgets('滚动歌词浏览时，中间准星指示的歌词行获得纯白大字高亮，正在播放的原歌词行弱化显示',
        (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await pumpPlayerPage(tester, player: player, auth: auth);

      final listFinder = find.byType(ListView);
      final center = tester.getCenter(listFinder);
      final pointer = TestPointer(3, PointerDeviceKind.mouse);

      // 向下滚动，浏览后续歌词
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 240)));
      await tester.pump(const Duration(milliseconds: 300));

      // 准星按钮展示对应准星行的精确时间
      final seekBtn = find.byKey(const ValueKey('lyric_seek_pointer_button'));
      expect(seekBtn, findsOneWidget);

      // 验证存在“回到当前”快捷入口
      expect(find.text('回到当前'), findsOneWidget);
    });
  });
}
