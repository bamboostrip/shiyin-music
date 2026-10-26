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
import 'package:shiyin_music/ui/pages/rank_page.dart';

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
  Future<List<RecommendedSongCard>> recommendedSongCards() async => const [];

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
  bool isPreparing = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = Duration.zero;
  @override
  String? errorMessage;
  @override
  List<Song> queue = [];
  @override
  bool autoPlayOnStartupEnabled = false;
  @override
  bool hasRestoredPlaybackState = false;
  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier(Duration.zero);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isRestoring = false;
  @override
  bool get isLoggedIn => true;
  @override
  bool isLiked(Song song) => false;
  @override
  Future<void> toggleLike(Song song) async {}
  @override
  List<PlaylistSummary> get createdPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedAlbums => const [];
  @override
  PlaylistSummary? get likedPlaylist => null;
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

  Future<void> pumpHomePage(
    WidgetTester tester, {
    Size size = const Size(400, 1100),
  }) async {
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeMusicApi()
      ..dailySongs = List.generate(8, (i) => _song(i))
      ..topSongsData = List.generate(8, (i) => _song(100 + i))
      ..playlists = List.generate(
        6,
        (i) => PlaylistSummary(id: 'pl_$i', title: '歌单$i', coverUrl: null),
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
  }

  testWidgets('在非横向滑轨区域左右滑动可切换「推荐 / 排行榜 / 电台」页面', (tester) async {
    await pumpHomePage(tester);

    // Initial state: 推荐 is displayed
    expect(find.text('大家都在听'), findsOneWidget);

    // Find PageView
    final pageViewFinder = find.byKey(const Key('home_tabs_page_view'));
    expect(pageViewFinder, findsOneWidget);
    final pageView = tester.widget<PageView>(pageViewFinder);
    expect(pageView.controller?.page, 0.0);

    // Swipe left on non-horizontal area (e.g. the section title '大家都在听')
    await tester.drag(find.text('大家都在听'), const Offset(-300, 0));
    await tester.pumpAndSettle();

    // Now PageView has transitioned to page 1: 排行榜
    expect(pageView.controller?.page, 1.0);
    expect(find.byType(RankPage), findsOneWidget);

    // Swipe left again to switch to page 2: 电台
    await tester.drag(find.byType(RankPage), const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(pageView.controller?.page, 2.0);

    // Swipe right to switch back to page 1: 排行榜
    await tester.drag(pageViewFinder, const Offset(300, 0));
    await tester.pumpAndSettle();

    expect(pageView.controller?.page, 1.0);
    expect(find.byType(RankPage), findsOneWidget);
  });

  testWidgets('点击顶部胶囊 Tab 可以跳转到对应页面', (tester) async {
    await pumpHomePage(tester);

    final pageViewFinder = find.byKey(const Key('home_tabs_page_view'));
    final pageView = tester.widget<PageView>(pageViewFinder);
    expect(pageView.controller?.page, 0.0);

    // Tap on '电台' tab
    await tester.tap(find.text('电台'));
    await tester.pumpAndSettle();

    expect(pageView.controller?.page, 2.0);

    // Tap on '推荐' tab
    await tester.tap(find.text('推荐'));
    await tester.pumpAndSettle();

    expect(pageView.controller?.page, 0.0);
  });

  testWidgets('在横向滚动歌单区域滑动时，优先滚动歌单滑轨，不触发页面切换', (tester) async {
    await pumpHomePage(tester);

    final pageViewFinder = find.byKey(const Key('home_tabs_page_view'));
    final pageView = tester.widget<PageView>(pageViewFinder);
    expect(pageView.controller?.page, 0.0);

    // Find first playlist item
    final firstPlaylistItem = find.text('歌单0');
    expect(firstPlaylistItem, findsOneWidget);

    // Drag horizontally on the playlist rail
    await tester.drag(firstPlaylistItem, const Offset(-120, 0));
    await tester.pumpAndSettle();

    // PageView must still remain on page 0: 推荐
    expect(pageView.controller?.page, 0.0);
    expect(find.text('大家都在听'), findsOneWidget);
  });
}