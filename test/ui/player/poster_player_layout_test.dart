import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/player/player_controls.dart';
import 'package:shiyin_music/ui/player/poster_player.dart';

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
  );

  @override
  List<Song> queue = const [
    Song(
      id: 'test-song-1',
      title: '晴天',
      artist: '周杰伦',
      hash: 'hash-test-1',
      source: SongSource.kugou,
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
  bool isPlaying = true;

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
    LyricLine(time: Duration(seconds: 25), text: '从出生那年就飘着'),
    LyricLine(time: Duration(seconds: 50), text: '童年的荡秋千'),
  ];

  @override
  int get activeLyricIndex => 1;

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

  Widget buildTestWidget({
    required PlayerController player,
    required AuthController auth,
    required Song song,
    ValueChanged<Song>? onArtistTap,
    VoidCallback? onLyricTap,
    VoidCallback? onQueue,
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
              onArtistTap: onArtistTap ?? (_) {},
              onLyricTap: onLyricTap,
              onQueue: onQueue ?? () {},
            ),
          ),
        ),
      ),
    );
  }

  const testSong = Song(
    id: 'test-song-1',
    title: '晴天',
    artist: '周杰伦',
    hash: 'hash-test-1',
    source: SongSource.kugou,
  );

  group('PosterPlayerPage QQ 音乐布局重构', () {
    testWidgets('封面下方存在大字号标题、歌手名、精致音质 Pill 且支持歌手点击', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      Song? tappedArtistSong;

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
          onArtistTap: (s) => tappedArtistSong = s,
        ),
      );
      await tester.pump();

      // 验证大标题与样式
      final titleFinder = find.text('晴天');
      expect(titleFinder, findsOneWidget);
      final Text titleWidget = tester.widget(titleFinder);
      expect(titleWidget.style?.fontSize, 22);
      expect(titleWidget.style?.fontWeight, FontWeight.w800);
      expect(titleWidget.style?.color, Colors.white);

      // 验证歌手名与样式
      final artistFinder = find.text('周杰伦');
      expect(artistFinder, findsOneWidget);
      final Text artistWidget = tester.widget(artistFinder);
      expect(artistWidget.style?.fontSize, 14);
      expect(artistWidget.style?.fontWeight, FontWeight.w600);

      // 验证音质 Pill
      expect(find.byType(PlayerAudioQualityPill), findsOneWidget);

      // 点击歌手名触发 onArtistTap
      await tester.tap(artistFinder);
      expect(tappedArtistSong, equals(testSong));
    });

    testWidgets('右侧爱心按钮存在，44x44 尺寸，能够切换喜欢状态', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
        ),
      );
      await tester.pump();

      // 初始未喜欢，应为 favorite_border_rounded
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsNothing);

      // 验证尺寸 (44x44)
      final heartFinder = find.byIcon(Icons.favorite_border_rounded);
      final heartIconButton = find.ancestor(
        of: heartFinder,
        matching: find.byType(SizedBox),
      );
      expect(heartIconButton, findsWidgets);
      final RenderBox box = tester.renderObject(heartIconButton.first);
      expect(box.size.width, 44.0);
      expect(box.size.height, 44.0);

      // 点击切换为喜欢
      await tester.tap(heartFinder);
      await tester.pump();

      expect(auth.isLiked(testSong), isTrue);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);

      // 再次点击取消喜欢
      await tester.tap(find.byIcon(Icons.favorite_rounded));
      await tester.pump();

      expect(auth.isLiked(testSong), isFalse);
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    });

    testWidgets('快捷操作栏存在收藏到歌单、音效、下载、评论 4 个入口', (tester) async {
      final player = _FakePlayerController();
      player.isAudioEffectsSupported = true;
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
        ),
      );
      await tester.pump();

      // 收藏到歌单
      expect(find.byIcon(Icons.playlist_add_rounded), findsOneWidget);

      // 音效（当支持音效时）
      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);

      // 下载
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);

      // 评论
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
    });

    testWidgets('不支持音效时快捷操作栏展示定时播放图标', (tester) async {
      final player = _FakePlayerController();
      player.isAudioEffectsSupported = false;
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
        ),
      );
      await tester.pump();

      // 应展示定时图标
      expect(find.byIcon(Icons.bedtime_rounded), findsOneWidget);
      expect(find.byIcon(Icons.graphic_eq_rounded), findsNothing);
    });

    testWidgets('非酷狗源歌曲评论按钮不可点击/置灰', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      const nonKugouSong = Song(
        id: 'netease-1',
        title: '网易云歌曲',
        artist: '某歌手',
        hash: 'netease-hash-1',
        source: SongSource.netease,
      );

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: nonKugouSong,
        ),
      );
      await tester.pump();

      final commentBtn = find.ancestor(
        of: find.byIcon(Icons.chat_bubble_outline_rounded),
        matching: find.byType(IconButton),
      );
      expect(commentBtn, findsOneWidget);
      final IconButton button = tester.widget(commentBtn);
      expect(button.onPressed, isNull);
    });

    testWidgets('点击歌词预览行触发 onLyricTap 回调', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();
      var lyricTapped = false;

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
          onLyricTap: () => lyricTapped = true,
        ),
      );
      await tester.pump();

      // 点击歌词预览区域
      final lyricFinder = find.byType(PosterLyricPreview);
      expect(lyricFinder, findsOneWidget);

      await tester.tap(lyricFinder);
      expect(lyricTapped, isTrue);
    });

    testWidgets('小屏高度 (height: 520) 下无任何 RenderFlex 溢出', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        buildTestWidget(
          player: player,
          auth: auth,
          song: testSong,
          size: const Size(360, 520),
        ),
      );
      await tester.pump();

      // 无溢出异常
      expect(tester.takeException(), isNull);
    });
  });
}
