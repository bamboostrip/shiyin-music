import 'package:flutter/material.dart';
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

  @override
  MusicApi get api => _FakeApi();

  @override
  String? errorMessage;

  @override
  Future<void> togglePlay() async {
    isPlaying = !isPlaying;
    notifyListeners();
  }

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
  });
}
