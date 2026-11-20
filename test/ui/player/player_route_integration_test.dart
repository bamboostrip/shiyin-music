import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/app_shell.dart';
import 'package:shiyin_music/ui/pages/player_page.dart';
import 'package:shiyin_music/ui/player/player_route.dart';
import 'package:shiyin_music/ui/player/player_top_bar.dart';
import 'package:shiyin_music/ui/widgets/car_left_player_panel.dart';
import 'package:shiyin_music/ui/widgets/mini_player.dart';

class _FakeApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

  /// PlayerPage 的 KEEP_SCREEN_ON 门控会读写这两个成员。
  @override
  bool keepScreenOnEnabled = true;

  @override
  Future<void> setKeepScreenOnEnabled(bool enabled) async {
    keepScreenOnEnabled = enabled;
    notifyListeners();
  }

  @override
  Song? currentSong = const Song(
    id: 'test-song-1',
    title: '晴天',
    artist: '周杰伦',
    hash: 'hash-test-1',
    source: SongSource.kugou,
    coverUrl: 'https://example.com/cover.jpg',
  );

  @override
  List<Song> queue = const [
    Song(
      id: 'test-song-1',
      title: '晴天',
      artist: '周杰伦',
      hash: 'hash-test-1',
      source: SongSource.kugou,
      coverUrl: 'https://example.com/cover.jpg',
    ),
  ];

  @override
  Duration duration = const Duration(minutes: 4, seconds: 29);

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  @override
  Duration position = const Duration(seconds: 30);

  @override
  Duration get smoothPosition => position;

  @override
  bool isPlaying = false;

  // 歌词页切歌键开关（issue #3）：默认关 = QQ 原版底栏。
  @override
  bool lyricPageSkipButtonsEnabled = false;

  int previousCalls = 0;
  int nextCalls = 0;

  @override
  Future<void> previous() async => previousCalls++;

  @override
  Future<void> next() async => nextCalls++;

  @override
  bool isPreparing = false;

  @override
  bool isScrubbing = false;

  @override
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;

  @override
  String get playbackModeLabel => '列表循环';

  @override
  AudioQuality audioQuality = AudioQuality.standard;

  @override
  String playbackSpeedLabel = '1.0x';

  @override
  bool isAudioEffectsSupported = true;

  @override
  String get audioEffectsLabel => '音效已开启';

  @override
  bool isDesktopLyricsSupported = false;

  @override
  bool desktopLyricsEnabled = false;

  @override
  List<LyricLine> lyrics = const [
    LyricLine(time: Duration.zero, text: '故事的小黄花'),
  ];

  @override
  int get activeLyricIndex => 0;

  @override
  Future<void> ensureLyricsLoaded() async {}

  @override
  Future<void> seekToAndPlay(Duration position) async {}

  @override
  SongClimax? climax;

  /// 桌面播放页底部常驻播放栏（DesktopPlayerBar）会读音量。
  @override
  double volume = 0.8;

  /// 快捷键 seek 落点（←/→ 各一次 ±5 秒）。
  final List<Duration> seeks = [];

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setVolume(double value) async => volume = value;

  @override
  MusicApi get api => _FakeApi();

  @override
  String? errorMessage;

  @override
  Future<void> togglePlay() async {
    isPlaying = !isPlaying;
    notifyListeners();
  }

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushedRoutes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    pushedRoutes.add(route);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    debugDesktopFormFactorOverride = false;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget buildTestApp({
    required PlayerController player,
    required AuthController auth,
    required NavigatorObserver observer,
    Size size = const Size(390, 844),
  }) {
    return MaterialApp(
      navigatorObservers: [observer],
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(
          body: Stack(
            children: [
              const Center(
                child: Text('Underlying HomePage Content'),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: MiniPlayer(
                  player: player,
                  auth: auth,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> pumpUntilSettled(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  group('PlayerRoute 集成测试', () {
    testWidgets(
      '移动端点击 MiniPlayer 使用 PlayerPageRoute 打开 PlayerPage，底层页面保持挂载',
      (tester) async {
        final player = _FakePlayerController();
        final auth = _FakeAuthController();
        final observer = _TestNavigatorObserver();

        await tester.pumpWidget(
          buildTestApp(player: player, auth: auth, observer: observer),
        );
        await tester.pump();

        expect(find.text('Underlying HomePage Content'), findsOneWidget);
        expect(find.byType(MiniPlayer), findsOneWidget);
        expect(find.byType(PlayerPage), findsNothing);

        // 点击 MiniPlayer
        await tester.tap(find.byType(MiniPlayer));
        await tester.pump();

        // 验证推进的路由为非不透明的 PlayerPageRoute
        expect(observer.pushedRoutes.last, isA<PlayerPageRoute<void>>());
        expect((observer.pushedRoutes.last as ModalRoute).opaque, isFalse);

        await pumpUntilSettled(tester);

        // 验证播放页已打开
        expect(find.byType(PlayerPage), findsOneWidget);

        // 验证底层页面依然挂载渲染（未被移除或隐藏）
        expect(find.text('Underlying HomePage Content'), findsOneWidget);
        final bgElement = tester.element(find.text('Underlying HomePage Content'));
        expect(bgElement.renderObject?.attached, isTrue);
      },
    );

    testWidgets(
      '从 MiniPlayer 打开 PlayerPage 后下拉，露出底层页面并能平滑 Pop 返回',
      (tester) async {
        final player = _FakePlayerController();
        final auth = _FakeAuthController();
        final observer = _TestNavigatorObserver();

        await tester.pumpWidget(
          buildTestApp(player: player, auth: auth, observer: observer),
        );
        await tester.pump();

        // 打开播放页
        await tester.tap(find.byType(MiniPlayer));
        await pumpUntilSettled(tester);

        expect(find.byType(PlayerPage), findsOneWidget);
        expect(find.text('Underlying HomePage Content'), findsOneWidget);

        // 下拉 100px
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(TopBar)),
        );
        await gesture.moveBy(const Offset(0, 100));
        await tester.pump();

        // 验证整页平移且带出圆角
        final transformFinder =
            find.byKey(const Key('player_body_dismiss_transform'));
        final Transform transform = tester.widget(transformFinder);
        expect(transform.transform.getTranslation().y, closeTo(100.0, 1.0));

        final clipFinder = find.byKey(const Key('player_body_dismiss_clip'));
        final ClipRRect clip = tester.widget(clipFinder);
        final borderRadius = clip.borderRadius as BorderRadius;
        expect(borderRadius.topLeft, equals(const Radius.circular(12.0)));
        expect(borderRadius.topRight, equals(const Radius.circular(12.0)));

        // 底层页面依然可见
        expect(find.text('Underlying HomePage Content'), findsOneWidget);

        // 释放手势触发 dismiss 退出（无 200ms 本地延时，立即触发 Navigator pop 并协同原生 SlideTransition 退场）
        await gesture.up();
        await tester.pump();

        // 验证 PlayerPageRoute 的 SlideTransition 原生退场已立即执行
        await tester.pump(const Duration(milliseconds: 100));
        final slideFinder = find.ancestor(
          of: find.byType(PlayerPage),
          matching: find.byType(SlideTransition),
        );
        expect(slideFinder, findsOneWidget);
        final slide = tester.widget<SlideTransition>(slideFinder);
        expect(slide.position.value.dy, greaterThan(0.0));

        // 等待退场完全结束
        await pumpUntilSettled(tester);

        // 播放页已完全 pop
        expect(find.byType(PlayerPage), findsNothing);
        // 回到底层页面
        expect(find.text('Underlying HomePage Content'), findsOneWidget);
      },
    );

    testWidgets(
      '桌面端点击 MiniPlayer 使用 MaterialPageRoute 打开 PlayerPage',
      (tester) async {
        debugDesktopFormFactorOverride = true;
        final player = _FakePlayerController();
        final auth = _FakeAuthController();
        final observer = _TestNavigatorObserver();

        await tester.pumpWidget(
          buildTestApp(player: player, auth: auth, observer: observer),
        );
        await tester.pump();

        await tester.tap(find.byType(MiniPlayer));
        await tester.pump();

        expect(observer.pushedRoutes.last, isA<MaterialPageRoute<void>>());
        expect(observer.pushedRoutes.last, isNot(isA<PlayerPageRoute<void>>()));

        await pumpUntilSettled(tester);
        expect(find.byType(PlayerPage), findsOneWidget);
      },
    );

    testWidgets(
      '移动端在车机左侧面板点击封面使用 PlayerPageRoute 打开 PlayerPage',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final player = _FakePlayerController();
        final auth = _FakeAuthController();
        final observer = _TestNavigatorObserver();

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: Scaffold(
              body: Row(
                children: [
                  CarLeftPlayerPanel(player: player, auth: auth),
                  const Expanded(child: Text('Main Car Content')),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(CarLeftPlayerPanel), findsOneWidget);
        expect(find.text('Main Car Content'), findsOneWidget);

        // 点击封面
        await tester.tap(find.text('晴天'));
        await tester.pump();

        expect(observer.pushedRoutes.last, isA<PlayerPageRoute<void>>());
        expect((observer.pushedRoutes.last as ModalRoute).opaque, isFalse);

        await pumpUntilSettled(tester);
        expect(find.byType(PlayerPage), findsOneWidget);
        // 背景内容依然在树中
        expect(find.text('Main Car Content'), findsOneWidget);
      },
    );

    testWidgets(
      '移动端点击底部导航栏 CenterDisc 使用 PlayerPageRoute 打开 PlayerPage',
      (tester) async {
        final player = _FakePlayerController();
        final auth = _FakeAuthController();
        final observer = _TestNavigatorObserver();

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: Scaffold(
              body: Center(
                child: CenterDisc(player: player, auth: auth),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(CenterDisc), findsOneWidget);

        await tester.tap(find.byType(CenterDisc));
        await tester.pump();

        expect(observer.pushedRoutes.last, isA<PlayerPageRoute<void>>());
        expect((observer.pushedRoutes.last as ModalRoute).opaque, isFalse);

        await pumpUntilSettled(tester);
        expect(find.byType(PlayerPage), findsOneWidget);
      },
    );

    testWidgets(
      '桌面端点击底部导航栏 CenterDisc 使用 MaterialPageRoute 打开 PlayerPage',
      (tester) async {
        debugDesktopFormFactorOverride = true;
        final player = _FakePlayerController();
        final auth = _FakeAuthController();
        final observer = _TestNavigatorObserver();

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: Scaffold(
              body: Center(
                child: CenterDisc(player: player, auth: auth),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byType(CenterDisc));
        await tester.pump();

        expect(observer.pushedRoutes.last, isA<MaterialPageRoute<void>>());
        expect(observer.pushedRoutes.last, isNot(isA<PlayerPageRoute<void>>()));

        await pumpUntilSettled(tester);
        expect(find.byType(PlayerPage), findsOneWidget);
      },
    );

    testWidgets(
      '歌词页切歌键随 PlayerController 开关即时显隐，且点击触发切歌',
      (tester) async {
        // 显式 390x844 视口：与 buildTestApp 的 MediaQuery 尺寸一致，
        // 保证 PageView 的翻页手势位移（-390）足以跨过半屏阈值。
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final player = _FakePlayerController();
        final auth = _FakeAuthController();
        final observer = _TestNavigatorObserver();

        await tester.pumpWidget(
          buildTestApp(player: player, auth: auth, observer: observer),
        );
        await tester.pump();

        await tester.tap(find.byType(MiniPlayer));
        await pumpUntilSettled(tester);
        expect(find.byType(PlayerPage), findsOneWidget);

        // 左滑切到歌词页（第 1 页），底部栏此时应保持 QQ 原版（无切歌键）。
        await tester.drag(find.byType(PageView), const Offset(-390, 0));
        await pumpUntilSettled(tester);

        const prevKey = ValueKey('lyric_previous_button');
        const nextKey = ValueKey('lyric_next_button');
        expect(find.byKey(prevKey), findsNothing);

        // 设置项从关到开：依赖 PlayerPage 的 AnimatedBuilder(player) 重建，
        // 底栏切歌键应即时出现（不需要重开播放页）。
        player.lyricPageSkipButtonsEnabled = true;
        player.notifyListeners();
        await tester.pump();
        expect(find.byKey(prevKey), findsOneWidget);
        expect(find.byKey(nextKey), findsOneWidget);

        await tester.tap(find.byKey(prevKey));
        await tester.tap(find.byKey(nextKey));
        expect(player.previousCalls, 1);
        expect(player.nextCalls, 1);

        // 设置项从开到关：底栏即时还原。
        player.lyricPageSkipButtonsEnabled = false;
        player.notifyListeners();
        await tester.pump();
        expect(find.byKey(prevKey), findsNothing);
        expect(find.byKey(nextKey), findsNothing);
      },
    );
  });

  // 全屏播放页是**根导航上的新路由**，与 home 路由互为兄弟：`Shortcuts` 只对
  // 自身焦点子树里的按键生效，作用域挂在 AppShell 内部时，进了播放页就只剩
  // 播放页自己的 Esc 还能用——空格/←→/↑↓ 全部静默失效（PC 用户体感是
  // 「一进全屏播放页快捷键就没了」）。这里按 main.dart 的 `MaterialApp.builder`
  // 结构复现真实挂载位置。
  group('全屏播放页快捷键（作用域在 Navigator 之上）', () {
    testWidgets('空格 / ←→ / Ctrl+←→ / ↑↓ 在播放页内全部生效，Esc 仍然只退出播放页', (
      tester,
    ) async {
      debugDesktopFormFactorOverride = true;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        MaterialApp(
          // 与 main.dart 的 MaterialApp.builder 同构：作用域包住 Navigator。
          // 把这一层挪回 AppShell 内部，本用例立刻变红。
          builder: (context, child) => AppShortcutScope(
            player: player,
            child: child ?? const SizedBox.shrink(),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => PlayerPageRoute.open(
                    context,
                    player: player,
                    auth: auth,
                  ),
                  child: const Text('打开播放页'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('打开播放页'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsOneWidget);

      // 空格：播放/暂停（注意此后唱片/歌词 ticker 会持续出帧，
      // 只能 pump 固定帧数，不能用 pumpAndSettle）。
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.isPlaying, isTrue, reason: '空格应切换播放状态');

      // →/←：±5 秒快退/快进（桌面默认键位）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(player.seeks, [const Duration(seconds: 35)]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(player.seeks.last, const Duration(seconds: 25));

      // Ctrl+→：下一首（裸 → 已被 seek 占用）。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(player.nextCalls, 1);
      expect(player.seeks.length, 2, reason: 'Ctrl+→ 不该同时触发 seek');

      // ↑：音量 +5%。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(player.volume, closeTo(0.85, 1e-6));

      // Esc 仍是「退出播放页」，不能被快捷键作用域抢走。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlayerPage), findsNothing);
    });
  });
}