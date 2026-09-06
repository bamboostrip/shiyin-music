import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/player_page.dart';
import 'package:shiyin_music/ui/player/lyric_views.dart';
import 'package:shiyin_music/ui/player/player_controls.dart';
import 'package:shiyin_music/ui/player/player_top_bar.dart';
import 'package:shiyin_music/ui/player/poster_player.dart';

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? currentSong = const Song(
    id: '1',
    title: '测试歌曲',
    artist: '测试歌手',
    hash: 'hash-1',
    source: SongSource.kugou,
  );

  @override
  List<Song> queue = const [
    Song(
      id: '1',
      title: '测试歌曲',
      artist: '测试歌手',
      hash: 'hash-1',
      source: SongSource.kugou,
    ),
  ];

  @override
  Duration duration = const Duration(minutes: 3);

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  @override
  Duration position = Duration.zero;

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
  bool isAudioEffectsSupported = false;

  @override
  bool isDesktopLyricsSupported = false;

  @override
  bool desktopLyricsEnabled = false;

  @override
  List<LyricLine> lyrics = const [];

  @override
  int get activeLyricIndex => 0;

  @override
  Future<void> ensureLyricsLoaded() async {}

  @override
  Future<void> seekToAndPlay(Duration position) async {}

  @override
  SongClimax? climax;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  group('PlayerPageIndicator', () {
    testWidgets('currentPage = 1 时右侧为长条胶囊、左侧为小圆点', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlayerPageIndicator(currentPage: 1),
            ),
          ),
        ),
      );

      final containers = tester.widgetList<AnimatedContainer>(
        find.descendant(
          of: find.byType(PlayerPageIndicator),
          matching: find.byType(AnimatedContainer),
        ),
      ).toList();

      expect(containers.length, 2);

      // 左侧对应 Page 0（歌词页）：未激活状态（圆点）
      final leftContainer = containers[0];
      expect(leftContainer.constraints?.maxWidth, 4.0);
      expect(leftContainer.constraints?.maxHeight, 3.5);
      final leftDecoration = leftContainer.decoration as BoxDecoration;
      expect(leftDecoration.color, Colors.white.withValues(alpha: 0.4));

      // 右侧对应 Page 1（封面页）：激活状态（长条胶囊）
      final rightContainer = containers[1];
      expect(rightContainer.constraints?.maxWidth, 14.0);
      expect(rightContainer.constraints?.maxHeight, 3.5);
      final rightDecoration = rightContainer.decoration as BoxDecoration;
      expect(rightDecoration.color, Colors.white);
    });

    testWidgets('currentPage = 0 时左侧为长条胶囊、右侧为小圆点', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlayerPageIndicator(currentPage: 0),
            ),
          ),
        ),
      );

      final containers = tester.widgetList<AnimatedContainer>(
        find.descendant(
          of: find.byType(PlayerPageIndicator),
          matching: find.byType(AnimatedContainer),
        ),
      ).toList();

      expect(containers.length, 2);

      // 左侧对应 Page 0（歌词页）：激活状态（长条胶囊）
      final leftContainer = containers[0];
      expect(leftContainer.constraints?.maxWidth, 14.0);
      expect(leftContainer.constraints?.maxHeight, 3.5);
      final leftDecoration = leftContainer.decoration as BoxDecoration;
      expect(leftDecoration.color, Colors.white);

      // 右侧对应 Page 1（封面页）：未激活状态（圆点）
      final rightContainer = containers[1];
      expect(rightContainer.constraints?.maxWidth, 4.0);
      expect(rightContainer.constraints?.maxHeight, 3.5);
      final rightDecoration = rightContainer.decoration as BoxDecoration;
      expect(rightDecoration.color, Colors.white.withValues(alpha: 0.4));
    });

    testWidgets('点击指示器触发 onPageSelected 回调', (tester) async {
      int? selectedPage;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlayerPageIndicator(
                currentPage: 1,
                onPageSelected: (index) => selectedPage = index,
              ),
            ),
          ),
        ),
      );

      final containers = find.descendant(
        of: find.byType(PlayerPageIndicator),
        matching: find.byType(AnimatedContainer),
      );

      // 点击左侧（歌词页，index 0）
      await tester.tap(containers.first);
      await tester.pump();
      expect(selectedPage, 0);

      // 点击右侧（封面页，index 1）
      await tester.tap(containers.last);
      await tester.pump();
      expect(selectedPage, 1);
    });
  });

  group('TopBar', () {
    testWidgets('移动端模式 (currentPage != null) 展示指示器且移除爱心与音质 Pill', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      const song = Song(id: '1', title: '晴天', artist: '周杰伦', hash: 'h1');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopBar(
              player: player,
              auth: auth,
              song: song,
              onClose: () {},
              onArtistTap: (_) {},
              currentPage: 1,
              onPageSelected: (_) {},
            ),
          ),
        ),
      );

      // 验证指示器存在
      expect(find.byType(PlayerPageIndicator), findsOneWidget);

      // 验证左侧返回、右侧更多按钮存在
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

      // 关键验证：移动端顶栏移除爱心与音质 Pill
      expect(find.byIcon(Icons.favorite_rounded), findsNothing);
      expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
      expect(find.byType(PlayerAudioQualityPill), findsNothing);
    });

    testWidgets('兼容模式 (currentPage == null) 保持原有标题、爱心与音质 Pill', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      const song = Song(id: '1', title: '晴天', artist: '周杰伦', hash: 'h1');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopBar(
              player: player,
              auth: auth,
              song: song,
              onClose: () {},
              onArtistTap: (_) {},
            ),
          ),
        ),
      );

      // 验证无指示器
      expect(find.byType(PlayerPageIndicator), findsNothing);

      // 验证标题和艺术家存在
      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('周杰伦'), findsOneWidget);

      // 验证爱心与音质 Pill 存在
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
      expect(find.byType(PlayerAudioQualityPill), findsOneWidget);
    });
  });

  group('PlayerPage 页面顺序与滑动', () {
    testWidgets('默认加载封面页（Index 0），向左滑切换至歌词页（Index 1）且顶栏指示器同步更新', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            player: player,
            auth: auth,
          ),
        ),
      );
      // ArtworkBackground 有一个无限循环的动画，单步 pump 推进
      await tester.pump(const Duration(milliseconds: 100));

      // 验证顶栏指示器显示 currentPage = 0（左长右短：代表封面页）
      final indicatorFinder = find.byType(PlayerPageIndicator);
      expect(indicatorFinder, findsOneWidget);
      final indicator = tester.widget<PlayerPageIndicator>(indicatorFinder);
      expect(indicator.currentPage, 0);

      // 验证默认处于封面页 (PosterPlayerPage)，且位于可见区域
      expect(find.byType(PosterPlayerPage), findsOneWidget);

      // 验证底部原 _PageDots 不复存在（由顶栏指示器替代）
      final allAnimatedContainers = tester.widgetList<AnimatedContainer>(
        find.byType(AnimatedContainer),
      ).toList();
      // 只应该有 PlayerPageIndicator 内的 2 个 AnimatedContainer
      expect(allAnimatedContainers.length, 2);

      // 向左滑动（手指从右滑向左 Offset(-300, 0)，进入右侧 Page 1 歌词页）
      await tester.drag(find.byType(PageView), const Offset(-300, 0));
      // 推进动画（PageView 滚动动画 250ms）
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 50));

      // 验证指示器更新为 currentPage = 1（左短右长：代表歌词页）
      final updatedIndicator = tester.widget<PlayerPageIndicator>(find.byType(PlayerPageIndicator));
      expect(updatedIndicator.currentPage, 1);

      // 验证当前显示为歌词页 (LyricPlayerPage)
      expect(find.byType(LyricPlayerPage), findsOneWidget);
    });

    testWidgets('在封面页点击歌词预览行切换至歌词页（Index 1）', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final player = _FakePlayerController();
      player.lyrics = const [
        LyricLine(time: Duration.zero, text: '故事的小黄花'),
      ];
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            player: player,
            auth: auth,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // 查找歌词预览组件并点击
      final lyricPreviewFinder = find.byType(PosterLyricPreview);
      expect(lyricPreviewFinder, findsOneWidget);
      await tester.tap(lyricPreviewFinder);
      await tester.pump();
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      // 指示器应更新为 1
      final updatedIndicator = tester.widget<PlayerPageIndicator>(find.byType(PlayerPageIndicator));
      expect(updatedIndicator.currentPage, 1);
      expect(find.byType(LyricPlayerPage), findsOneWidget);
    });
  });
}
