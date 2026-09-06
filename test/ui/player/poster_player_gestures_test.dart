import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/player_page.dart';
import 'package:shiyin_music/ui/player/poster_player.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';

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
  DownloadController? downloadController;

  @override
  MusicApi get api => _FakeApi();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  final Set<String> _likedHashes = {};

  @override
  bool isLiked(Song song) => _likedHashes.contains(song.hash);

  @override
  Future<void> toggleLike(Song song) async {
    if (_likedHashes.contains(song.hash)) {
      _likedHashes.remove(song.hash);
    } else {
      _likedHashes.add(song.hash);
    }
    notifyListeners();
  }

  @override
  List<PlaylistSummary> get createdPlaylists => const [];

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

  const testSong = Song(
    id: 'test-song-1',
    title: '晴天',
    artist: '周杰伦',
    hash: 'hash-test-1',
    source: SongSource.kugou,
    coverUrl: 'https://example.com/cover.jpg',
  );

  Widget buildTestWidget({
    required PlayerController player,
    required AuthController auth,
    required Song song,
    VoidCallback? onCoverTap,
    VoidCallback? onDismiss,
    Size size = const Size(390, 844),
  }) {
    return MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(size: size),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: PosterPlayerPage(
              player: player,
              song: song,
              auth: auth,
              onArtistTap: (_) {},
              onQueue: () {},
              onCoverTap: onCoverTap,
              onDismiss: onDismiss,
            ),
          ),
        ),
      ),
    );
  }

  group('PosterPlayerPage 手势交互测试', () {
    testWidgets('在封面区域点击能成功触发 onCoverTap 回调', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      var coverTapped = false;

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
          onCoverTap: () => coverTapped = true,
        ),
      );
      await tester.pump();

      final artworkFinder = find.byType(Artwork).first;
      expect(artworkFinder, findsOneWidget);

      await tester.tap(artworkFinder);
      await tester.pump();

      expect(coverTapped, isTrue);
    });

    testWidgets('在封面页向下拖拽超过 80px 释放能触发 onDismiss', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      var dismissed = false;

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
          onDismiss: () => dismissed = true,
        ),
      );
      await tester.pump();

      // 从封面区域开始向下拖拽 100px
      await tester.drag(
        find.byType(Artwork).first,
        const Offset(0, 100),
      );
      await tester.pump();

      expect(dismissed, isTrue);
    });

    testWidgets('在封面页快速向下甩动 (velocity > 800px/s) 释放触发 onDismiss', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      var dismissed = false;

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
          onDismiss: () => dismissed = true,
        ),
      );
      await tester.pump();

      await tester.fling(
        find.byType(Artwork).first,
        const Offset(0, 60),
        1000,
      );
      await tester.pump();

      expect(dismissed, isTrue);
    });

    testWidgets('在封面页轻微下拉 (<40px) 释放不触发 onDismiss 并回弹复位', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      var dismissed = false;

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
          onDismiss: () => dismissed = true,
        ),
      );
      await tester.pump();

      // 下拉 30px
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Artwork).first),
      );
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();

      final transformFinder = find.byKey(
        const Key('poster_player_dismiss_transform'),
      );
      expect(transformFinder, findsOneWidget);

      await gesture.up();
      await tester.pump();

      // 未达到 80px，不应触发 onDismiss
      expect(dismissed, isFalse);

      // 回弹动画完成 (250ms)
      await tester.pump(const Duration(milliseconds: 300));

      final Transform transform = tester.widget(transformFinder);
      expect(transform.transform.getTranslation().y, equals(0.0));
    });

    testWidgets('水平向右拖拽不触发 onDismiss 并交由 PageView 切换至上一页', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      var dismissed = false;
      final pageController = PageController(initialPage: 1);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageView(
              controller: pageController,
              children: [
                const SizedBox(key: Key('page_0')),
                PosterPlayerPage(
                  player: player,
                  song: testSong,
                  auth: auth,
                  onArtistTap: (_) {},
                  onQueue: () {},
                  onDismiss: () => dismissed = true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // 水平向右滑动 500px（超过半屏以触发切页）
      await tester.drag(find.byType(PosterPlayerPage), const Offset(500, 0));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      // 不触发 onDismiss
      expect(dismissed, isFalse);
      // PageView 切换到第 0 页
      expect(pageController.page, closeTo(0.0, 0.01));
    });

    testWidgets('在 PlayerPage 中点击封面呼出更多操作 Sheet', (tester) async {
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
      await tester.pump();

      // 点击封面
      final coverFinder = find.byType(Artwork).first;
      await tester.tap(coverFinder);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      // 验证 Sheet 中存在倍速和音质选项
      expect(find.text('倍速'), findsOneWidget);
      expect(find.text('音质'), findsOneWidget);
    });

    testWidgets('在 PlayerPage 中向下拉动超过 80px 退出播放页', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlayerPage(player: player, auth: auth),
                ),
              ),
              child: const Text('Open Player'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Player'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(find.byType(PlayerPage), findsOneWidget);

      // 下拉超过 80px
      await tester.drag(find.byType(Artwork).first, const Offset(0, 100));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      // 页面已 pop
      expect(find.byType(PlayerPage), findsNothing);
    });
  });
}
