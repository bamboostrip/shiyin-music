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
import 'package:shiyin_music/ui/widgets/home_collapsible_header.dart';

class _FakeMusicApi implements MusicApi {
  List<Song> dailySongs = const [];
  List<Song> topSongsData = const [];
  List<PlaylistSummary> playlists = const [];
  List<RankCategory> ranks = const [];

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
  Future<List<RankCategory>> rankList({int withSong = 0}) async => ranks;

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

  Future<void> pumpHomePage(WidgetTester tester) async {
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeMusicApi()
      ..dailySongs = List.generate(10, (i) => _song(i))
      ..topSongsData = List.generate(12, (i) => _song(100 + i))
      ..playlists = List.generate(
        8,
        (i) => PlaylistSummary(id: 'pl_$i', title: '歌单$i', coverUrl: null),
      )
      // 排行榜 tab 内容必须足够高：收起态切页时目标页要能被推到 48px 地板。
      ..ranks = List.generate(
        10,
        (i) => RankCategory(rankId: 100 + i, rankName: '榜单$i'),
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

  double headerShrink(WidgetTester tester) =>
      tester.widget<HomeCollapsibleHeaderView>(
        find.byType(HomeCollapsibleHeaderView),
      ).shrinkOffset;

  Finder recommendList() =>
      find.byKey(const PageStorageKey<String>('home_tab_recommend'));

  /// 深滚后再轻微上滑：顶栏 floating 重新展开（shrink=0），内容仍在深处。
  Future<void> expandHeaderOverDeepContent(WidgetTester tester) async {
    await tester.drag(recommendList(), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(headerShrink(tester), closeTo(48.0, 0.5));
    await tester.drag(recommendList(), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(headerShrink(tester), 0.0);
  }

  testWidgets('顶栏展开时点胶囊切子 tab：顶栏保持展开不自动收起', (tester) async {
    await pumpHomePage(tester);
    expect(headerShrink(tester), 0.0);

    await expandHeaderOverDeepContent(tester);

    await tester.tap(find.text('排行榜'));
    await tester.pumpAndSettle();

    // 用户没有在新 tab 上滚动过，切 tab 本身不得改变顶栏展示。
    expect(headerShrink(tester), 0.0);
  });

  testWidgets('顶栏展开时横滑切子 tab：顶栏保持展开不自动收起', (tester) async {
    await pumpHomePage(tester);

    // 先切到排行榜并在其上深滚后轻微上滑：顶栏重新展开、内容在深处。
    // 深滚后推荐页的标题都滚出了屏幕（没有可命中的起拖点），而排行榜
    // 内容是竖向卡片（无横滑滑轨抢手势），适合作为横滑起拖点。
    await tester.tap(find.text('排行榜'));
    await tester.pumpAndSettle();
    final rankList = find.byKey(const PageStorageKey<String>('home_tab_rank'));
    await tester.drag(rankList, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(headerShrink(tester), closeTo(48.0, 0.5));
    await tester.drag(rankList, const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(headerShrink(tester), 0.0);

    // timedDrag 跨多帧滑动，覆盖切页飞行中的每一帧（单帧 drag 落地太快，
    // 飞行分支完全不跑，暴露不了旧实现的插值收起问题）。拖 450px 明确
    // 越过半页。
    await tester.timedDrag(
      rankList,
      const Offset(450, 0),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();

    // 确认横滑确实切回了推荐页（防止手势无效导致断言空过）。
    final pageView = tester.widget<PageView>(
      find.byKey(const Key('home_tabs_page_view')),
    );
    expect(pageView.controller?.page, 0.0);
    expect(headerShrink(tester), 0.0);
  });

  testWidgets('顶栏收起时点胶囊切子 tab：顶栏保持收起不自动展开', (tester) async {
    await pumpHomePage(tester);

    await tester.drag(recommendList(), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(headerShrink(tester), closeTo(48.0, 0.5));

    await tester.tap(find.text('排行榜'));
    await tester.pumpAndSettle();

    expect(headerShrink(tester), closeTo(48.0, 0.5));
  });
}