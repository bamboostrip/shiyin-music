import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/local_music_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/home_page.dart';
import 'package:shiyin_music/ui/pages/recommended_playlists_page.dart';
import 'package:shiyin_music/ui/pages/top_songs_page.dart';

class _FakeMusicApi implements MusicApi {
  List<Song> dailySongs = const [];
  List<Song> topSongsData = const [];
  List<PlaylistSummary> playlists = const [];

  @override
  Future<DailyRecommend> dailyRecommend() async =>
      DailyRecommend(title: '每日推荐', songs: dailySongs);

  @override
  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async =>
      playlists;

  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async =>
      topSongsData;

  @override
  Future<List<RankCategory>> rankList({int withSong = 0}) async => const [];

  @override
  Future<List<Song>> newSongs({int rankId = 0, int page = 1}) async => const [];

  @override
  Future<List<FmStation>> fmRecommendedStations() async => const [];

  @override
  Future<List<FmClassGroup>> fmClassGroups() async => const [];

  @override
  Future<Map<String, FmImage>> fmImages(List<String> fmids) async => const {};

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

  @override
  Song? currentSong;
  @override
  bool isPlaying = false;
  @override
  List<Song> queue = const [];
  Song? playedSong;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier(Duration.zero);
  @override
  Duration get duration => Duration.zero;
  @override
  Duration get position => Duration.zero;
  @override
  String? get errorMessage => null;
  @override
  bool get isPreparing => false;
  bool get isClimaxSupported => false;
  @override
  bool autoPlayOnStartupEnabled = false;
  @override
  bool hasRestoredPlaybackState = false;

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
    bool preservePersonalFmSession = false,
  }) async {
    currentSong = song;
    playedSong = song;
    if (queue != null) this.queue = queue;
    isPlaying = true;
    notifyListeners();
  }

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
  bool isRestoring = false;
  @override
  bool isLiked(Song song) => false;
  @override
  Future<void> toggleLike(Song song) async {}
  @override
  bool get isLoggedIn => false;
  @override
  int get likedCount => 0;
  @override
  UserProfile? get profile => null;
  @override
  UserVipInfo? get vipInfo => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCache implements CacheService {
  @override
  Future<CacheResult<T>?> read<T>(
    String key, {
    required T Function(Map<String, dynamic> json) decode,
    Duration ttl = const Duration(hours: 24),
  }) async =>
      null;

  @override
  Future<void> write(String key, Map<String, dynamic> payload) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDownloadController extends ChangeNotifier
    implements DownloadController {
  @override
  List<Song> get downloadedSongs => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalMusicController extends ChangeNotifier
    implements LocalMusicController {
  @override
  List<Song> get songs => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(int i) => Song(
      id: 'id_$i',
      title: '歌曲_$i',
      artist: '歌手_$i',
      hash: 'hash_$i',
    );

void main() {
  ThemeController();

  testWidgets('点击首页「推荐歌单」标题可以跳转到 RecommendedPlaylistsPage 且不包含播放全部按钮',
      (tester) async {
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    tester.view.physicalSize = const Size(400, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeMusicApi()
      ..dailySongs = List.generate(4, (i) => _song(i))
      ..playlists = List.generate(
        6,
        (i) => PlaylistSummary(
          id: 'pl_$i',
          title: '歌单$i',
          coverUrl: null,
          playCount: 123456,
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePage(
            api: api,
            auth: _FakeAuthController(),
            player: _FakePlayerController(),
            cache: _FakeCache(),
            theme: ThemeController(),
            downloads: _FakeDownloadController(),
            localMusic: _FakeLocalMusicController(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final recommendTitle = find.text('推荐歌单');
    expect(recommendTitle, findsOneWidget);

    await tester.tap(recommendTitle);
    await tester.pumpAndSettle();

    expect(find.byType(RecommendedPlaylistsPage), findsOneWidget);
    expect(find.text('播放全部'), findsNothing);
    expect(find.text('歌单0'), findsOneWidget);

    // 验证固定置顶返回按钮可点击返回
    final backBtn = find.byIcon(Icons.arrow_back_rounded);
    expect(backBtn, findsOneWidget);
    await tester.tap(backBtn);
    await tester.pumpAndSettle();

    expect(find.byType(RecommendedPlaylistsPage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets(
      '点击首页「新歌速递」标题可以跳转到 TopSongsPage，不含播放全部按钮且支持点歌播放与返回',
      (tester) async {
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    tester.view.physicalSize = const Size(400, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fakePlayer = _FakePlayerController();
    final api = _FakeMusicApi()
      ..dailySongs = List.generate(4, (i) => _song(i))
      ..topSongsData = List.generate(8, (i) => _song(100 + i));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePage(
            api: api,
            auth: _FakeAuthController(),
            player: fakePlayer,
            cache: _FakeCache(),
            theme: ThemeController(),
            downloads: _FakeDownloadController(),
            localMusic: _FakeLocalMusicController(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final newSongsTitle = find.text('新歌速递');
    expect(newSongsTitle, findsOneWidget);

    await tester.tap(newSongsTitle);
    await tester.pumpAndSettle();

    expect(find.byType(TopSongsPage), findsOneWidget);
    // 验证新歌速递二级页已去除「播放全部」按钮
    expect(find.text('播放全部'), findsNothing);

    // 点击歌曲进行播放
    final songItem = find.text('歌曲_100');
    expect(songItem, findsOneWidget);
    await tester.tap(songItem);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(fakePlayer.playedSong?.title, '歌曲_100');
    expect(fakePlayer.queue.length, 8);

    // 验证固定置顶返回按钮可点击返回
    final backBtn = find.byIcon(Icons.arrow_back_rounded);
    expect(backBtn, findsOneWidget);
    await tester.tap(backBtn);
    await tester.pumpAndSettle();

    expect(find.byType(TopSongsPage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
  });
}