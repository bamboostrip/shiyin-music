import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/player_page.dart';

import 'package:shiyin_music/ui/player/player_controls.dart';

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
  Future<void> Function(Duration pos)? onSeekToAndPlay;

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
    if (onSeekToAndPlay != null) {
      await onSeekToAndPlay!(pos);
      return;
    }
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

    testWidgets('车机横屏与桌面模式下顶栏保持极简通透，不展示突兀的音质 Capsule Pill',
        (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await pumpPlayerPage(tester, player: player, auth: auth);

      // 验证顶栏包含返回和更多按钮
      expect(find.byIcon(Icons.keyboard_arrow_left_rounded), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

      // 关键验证：顶栏不出现突兀的音质 Pill
      expect(find.byType(PlayerAudioQualityPill), findsNothing);
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

      // 向下轻微滚动，浏览后续歌词（原播放行仍在视口内弱化）
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.pump();
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump();
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
      await tester.pump(const Duration(milliseconds: 300));

      // 准星按钮展示对应准星行的精确时间
      final seekBtn = find.byKey(const ValueKey('lyric_seek_pointer_button'));
      expect(seekBtn, findsOneWidget);

      // 原播放行（第4句）弱化，不再是纯白 100% 30px
      Finder lyricLineStyleFinder(String text) => find.ancestor(
            of: find.text(text),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is AnimatedDefaultTextStyle &&
                  w.duration == const Duration(milliseconds: 180),
            ),
          );

      final playingLineFinder =
          lyricLineStyleFinder('这是第 4 句歌词，为你弹奏萧邦的夜曲');
      expect(playingLineFinder, findsOneWidget);
      final playingStyle =
          (tester.widget(playingLineFinder) as AnimatedDefaultTextStyle).style;
      expect(playingStyle.color, isNot(Colors.white));
      expect(playingStyle.fontSize, equals(24.0));

      // 准星指示的当前聚焦行（第6句）获得纯白 30px 高亮
      final focusedLineFinder =
          lyricLineStyleFinder('这是第 6 句歌词，为你弹奏萧邦的夜曲');
      expect(focusedLineFinder, findsOneWidget);
      final focusedStyle =
          (tester.widget(focusedLineFinder) as AnimatedDefaultTextStyle).style;
      expect(focusedStyle.color, equals(Colors.white));
      expect(focusedStyle.fontSize, equals(30.0));

      // 验证存在“回到当前”快捷入口
      expect(find.text('回到当前'), findsOneWidget);
    });

    testWidgets('进入播放页时若当前播放已在后半段（如第 20 句），能正确定位到当前播放行',
        (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      player.activeLyricIndex = 20;
      player.position = const Duration(seconds: 100);
      player.positionListenable.value = const Duration(seconds: 100);

      await pumpPlayerPage(tester, player: player, auth: auth);

      // 验证第 20 句歌词在视口中被找到并可见
      expect(find.text('这是第 21 句歌词，为你弹奏萧邦的夜曲'), findsOneWidget);
    });

    testWidgets('播放进度向前推进时，歌词高亮行与列表自动跟随滚动', (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      player.activeLyricIndex = 3;
      player.position = const Duration(seconds: 15);
      player.positionListenable.value = const Duration(seconds: 15);

      await pumpPlayerPage(tester, player: player, auth: auth);

      expect(find.text('这是第 4 句歌词，为你弹奏萧邦的夜曲'), findsOneWidget);

      // 模拟播放时间推进到第 5 句（25秒）
      player.activeLyricIndex = 4;
      player.position = const Duration(seconds: 25);
      player.positionListenable.value = const Duration(seconds: 25);
      await tester.pump(const Duration(milliseconds: 300));

      Finder lyricLineStyleFinder(String text) => find.ancestor(
            of: find.text(text),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is AnimatedDefaultTextStyle &&
                  w.duration == const Duration(milliseconds: 180),
            ),
          );

      // 第 5 句应成为纯白高亮行
      final line5Finder =
          lyricLineStyleFinder('这是第 5 句歌词，为你弹奏萧邦的夜曲');
      expect(line5Finder, findsOneWidget);
      final line5Style =
          (tester.widget(line5Finder) as AnimatedDefaultTextStyle).style;
      expect(line5Style.color, equals(Colors.white));
      expect(line5Style.fontSize, equals(30.0));
    });

    testWidgets(
        '用户在滚动浏览状态下直接退出播放页（未复位未跳转），重新进入后歌词恢复对齐当前播放并持续跟随',
        (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      player.activeLyricIndex = 3;
      player.position = const Duration(seconds: 15);
      player.positionListenable.value = const Duration(seconds: 15);

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // 宿主页面：包含打开播放页的入口
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => Navigator.push(
                  ctx,
                  MaterialPageRoute(
                    builder: (_) => PlayerPage(player: player, auth: auth),
                  ),
                ),
                child: const Text('OpenPlayer'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 打开播放页
      await tester.tap(find.text('OpenPlayer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 1. 用户手动滚动歌词
      final listFinder = find.byType(ListView);
      final center = tester.getCenter(listFinder);
      final pointer = TestPointer(4, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 150)));
      await tester.pump(const Duration(milliseconds: 100));

      // 验证处于用户浏览状态（有回到当前入口）
      expect(find.text('回到当前'), findsOneWidget);

      // 2. 用户未点击回到当前、未跳转，而是直接点击退出返回（Navigator.pop）
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      // 播放页已退出，回到宿主页
      expect(find.text('回到当前'), findsNothing);
      expect(find.text('OpenPlayer'), findsOneWidget);

      // 3. 歌曲继续在后台播放，进度推进到第 5 句（25秒）
      player.activeLyricIndex = 4;
      player.position = const Duration(seconds: 25);
      player.positionListenable.value = const Duration(seconds: 25);

      // 4. 用户重新进入播放页
      await tester.tap(find.text('OpenPlayer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      Finder lyricLineStyleFinder(String text) => find.ancestor(
            of: find.text(text),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is AnimatedDefaultTextStyle &&
                  w.duration == const Duration(milliseconds: 180),
            ),
          );

      // 重新进入后，当前正在播放的第 5 句应当高亮，且不处于用户浏览拦截状态
      expect(find.text('回到当前'), findsNothing);
      final line5Finder =
          lyricLineStyleFinder('这是第 5 句歌词，为你弹奏萧邦的夜曲');
      expect(line5Finder, findsOneWidget);
      final line5Style =
          (tester.widget(line5Finder) as AnimatedDefaultTextStyle).style;
      expect(line5Style.color, equals(Colors.white));
      expect(line5Style.fontSize, equals(30.0));

      // 5. 随着播放进一步推进到第 6 句（30秒），歌词必须能正常动、继续跟随，绝不卡死
      player.activeLyricIndex = 5;
      player.position = const Duration(seconds: 30);
      player.positionListenable.value = const Duration(seconds: 30);
      await tester.pump(const Duration(milliseconds: 300));

      final line6Finder =
          lyricLineStyleFinder('这是第 6 句歌词，为你弹奏萧邦的夜曲');
      expect(line6Finder, findsOneWidget);
      final line6Style =
          (tester.widget(line6Finder) as AnimatedDefaultTextStyle).style;
      expect(line6Style.color, equals(Colors.white));
      expect(line6Style.fontSize, equals(30.0));
    });

    testWidgets(
        '冷启动未播放状态下进入播放页，滚动歌词并点击定位指针起播，不会先闪回第0句再跳到目标句',
        (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      player.activeLyricIndex = 0;
      player.position = Duration.zero;
      player.positionListenable.value = Duration.zero;
      player.isPlaying = false;

      Finder lyricLineStyleFinder(String text) => find.ancestor(
            of: find.text(text),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is AnimatedDefaultTextStyle &&
                  w.duration == const Duration(milliseconds: 180),
            ),
          );

      player.onSeekToAndPlay = (pos) async {
        // 模拟起播前准备阶段：isPreparing = true，通知监听器
        player.isPreparing = true;
        player.notifyListeners();
      };

      await pumpPlayerPage(tester, player: player, auth: auth);

      // 1. 用户滚动歌词
      final listFinder = find.byType(ListView);
      final center = tester.getCenter(listFinder);
      final pointer = TestPointer(5, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 180)));
      await tester.pump();
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 180)));
      await tester.pump(const Duration(milliseconds: 300));

      final seekBtn = find.byKey(const ValueKey('lyric_seek_pointer_button'));
      expect(seekBtn, findsOneWidget);

      // 2. 点击定位播放指针起播
      await tester.tap(seekBtn);
      // 触发起播后准备中帧，等待行文字过渡动画 (180ms)
      await tester.pump(const Duration(milliseconds: 200));

      expect(player.seekToAndPlayCalls, contains(const Duration(seconds: 15)));

      // 此时第 4 句应当直接保持高亮，绝不能被闪退至第 1 句
      final line4Finder =
          lyricLineStyleFinder('这是第 4 句歌词，为你弹奏萧邦的夜曲');
      expect(line4Finder, findsOneWidget);
      final line4Style =
          (tester.widget(line4Finder) as AnimatedDefaultTextStyle).style;
      expect(line4Style.color, equals(Colors.white));
      expect(line4Style.fontSize, equals(30.0));

      // 验证第 1 句此时绝未作为当前播放句高亮呈现（列表保持在第 4 句，不会闪回第 1 句）
      final line1TextFinder = find.text('这是第 1 句歌词，为你弹奏萧邦的夜曲');
      if (line1TextFinder.evaluate().isNotEmpty) {
        final line1Style =
            (tester.widget(lyricLineStyleFinder('这是第 1 句歌词，为你弹奏萧邦的夜曲'))
                    as AnimatedDefaultTextStyle)
                .style;
        expect(line1Style.color, isNot(Colors.white));
      }

      // 3. 底层准备就绪，正式播放目标位置
      player.isPreparing = false;
      player.isPlaying = true;
      player.activeLyricIndex = 3;
      player.position = const Duration(seconds: 15);
      player.positionListenable.value = const Duration(seconds: 15);
      await tester.pump(const Duration(milliseconds: 300));

      // 歌词稳定停留在第 4 句
      final line4StyleAfter =
          (tester.widget(line4Finder) as AnimatedDefaultTextStyle).style;
      expect(line4StyleAfter.color, equals(Colors.white));
      expect(line4StyleAfter.fontSize, equals(30.0));
    });
  });
}
