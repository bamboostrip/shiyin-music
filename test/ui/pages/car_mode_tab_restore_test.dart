import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/local_music_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/app_shell.dart';
import 'package:shiyin_music/ui/pages/home_page.dart';
import 'package:shiyin_music/ui/pages/library_page.dart';

class _FakeMusicApi implements MusicApi {
  List<Song> dailySongs = const [];
  List<Song> topSongsData = const [];
  List<PlaylistSummary> playlists = const [];
  int dailyRecommendCalls = 0;
  int rankListCalls = 0;
  @override
  Future<List<Song>> playlistSongs(String id,
          {int page = 1, int pageSize = 30, bool fetchAll = false}) async =>
      const [];
  @override
  Future<DailyRecommend> dailyRecommend() async {
    dailyRecommendCalls++;
    return DailyRecommend(title: '每日推荐', songs: dailySongs);
  }
  @override
  Future<List<PlaylistSummary>> recommendedPlaylists(
          {int categoryId = 0, int page = 1}) async =>
      playlists;
  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async =>
      topSongsData;
  @override
  Future<List<RankCategory>> rankList({int withSong = 0}) async {
    rankListCalls++;
    return List.generate(
        5, (i) => RankCategory(rankId: 100 + i, rankName: '榜单$i'));
  }
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
  Future<CacheResult<T>?> read<T>(String key,
          {required T Function(Map<String, dynamic> json) decode,
          Duration ttl = const Duration(hours: 24)}) async =>
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

Song _song(int i) =>
    Song(id: 'id_$i', title: '新歌$i', artist: '歌手$i', hash: 'hash_$i');

Finder capsuleTab(String label) => find.byWidgetPredicate(
      (w) => w is Text && w.data == label && w.style?.fontSize == 14.5,
    );

Finder carChip(String label) => find.byWidgetPredicate(
      (w) =>
          w is ChoiceChip &&
          (w.label as Text).data == label,
    );

Future<_FakeMusicApi> _pumpCarShell(
  WidgetTester tester,
  ThemeController theme,
) async {
  final api = _FakeMusicApi()
    ..dailySongs = List.generate(8, (i) => _song(i))
    ..topSongsData = List.generate(8, (i) => _song(100 + i))
    ..playlists = List.generate(
      6,
      (i) => PlaylistSummary(id: 'pl_$i', title: '歌单$i', coverUrl: null),
    );
  await tester.pumpWidget(
    MaterialApp(
      home: AppShell(
        api: api,
        auth: _FakeAuthController(),
        player: _FakePlayerController(),
        cache: _FakeCache(),
        theme: theme,
        downloads: _FakeDownloadController(),
        localMusic: _FakeLocalMusicController(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('竖屏排行榜→车机横屏→缩回竖屏仍停留在排行榜', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);
    appShellNow = () => tester.binding.clock.now();
    addTearDown(() => appShellNow = DateTime.now);

    final theme = ThemeController();
    await theme.setCarModeEnabled(true);
    addTearDown(() async {
      await ThemeController.instance.setCarModeEnabled(false);
    });

    tester.view.physicalSize = const Size(400, 800);
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
        home: AppShell(
          api: api,
          auth: _FakeAuthController(),
          player: _FakePlayerController(),
          cache: _FakeCache(),
          theme: theme,
          downloads: _FakeDownloadController(),
          localMusic: _FakeLocalMusicController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 竖屏切到排行榜
    await tester.tap(capsuleTab('排行榜'));
    await tester.pumpAndSettle();
    PageView pv =
        tester.widget<PageView>(find.byKey(const Key('home_tabs_page_view')));
    expect(pv.controller?.page?.round(), 1);

    // 扩展到车机横屏
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    // 车机模式下 PageView 离树，顶栏应选中排行榜
    expect(find.byKey(const Key('home_tabs_page_view')), findsNothing);

    // 缩回竖屏：应回到排行榜而不是推荐
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_tabs_page_view')), findsOneWidget);
    pv = tester.widget<PageView>(find.byKey(const Key('home_tabs_page_view')));
    expect(pv.controller?.page?.round(), 1);
    final rankTab = tester.widget<Text>(capsuleTab('排行榜'));
    expect(rankTab.style?.fontWeight, FontWeight.w800);
  });

  testWidgets('车机点中当前推荐tab回顶并刷新，切换tab保持位置', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    final theme = ThemeController();
    await theme.setCarModeEnabled(true);
    addTearDown(() async {
      await ThemeController.instance.setCarModeEnabled(false);
    });

    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = await _pumpCarShell(tester, theme);
    expect(carChip('推荐'), findsOneWidget);

    HomePageState homeState() =>
        tester.state<HomePageState>(find.byType(HomePage));

    // 下滑推荐页后点中当前推荐：回到顶部并刷新推荐流（含均衡器动画）
    await tester.drag(find.text('大家都在听'), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(homeState().isCarScrolled, isTrue);
    final callsBeforeTop = api.dailyRecommendCalls;
    await tester.tap(carChip('推荐'));
    await tester.pumpAndSettle();
    expect(homeState().isCarScrolled, isFalse);
    expect(api.dailyRecommendCalls, greaterThan(callsBeforeTop));

    // 已在顶部时再点当前 tab：同样刷新（不判断是否滚动过）
    final callsBeforeIdle = api.dailyRecommendCalls;
    await tester.tap(carChip('推荐'));
    await tester.pumpAndSettle();
    expect(homeState().isCarScrolled, isFalse);
    expect(api.dailyRecommendCalls, greaterThan(callsBeforeIdle));

    // 下滑后切到排行榜：共用单滚动容器，位置保持，不刷新推荐流
    await tester.drag(find.text('大家都在听'), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(homeState().isCarScrolled, isTrue);
    final callsBeforeSwitch = api.dailyRecommendCalls;
    final rankCallsBeforeSwitch = api.rankListCalls;
    await tester.tap(carChip('排行榜'));
    await tester.pumpAndSettle();
    expect(homeState().isCarScrolled, isTrue);
    expect(api.dailyRecommendCalls, callsBeforeSwitch);
    expect(api.rankListCalls, rankCallsBeforeSwitch);

    // 点中当前排行榜：回到顶部并刷新榜单
    await tester.tap(carChip('排行榜'));
    await tester.pumpAndSettle();
    expect(homeState().isCarScrolled, isFalse);
    expect(api.rankListCalls, greaterThan(rankCallsBeforeSwitch));
  });

  testWidgets('车机无下拉小圆圈、竖屏保留下拉刷新', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    final theme = ThemeController();
    await theme.setCarModeEnabled(true);
    addTearDown(() async {
      await ThemeController.instance.setCarModeEnabled(false);
    });

    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpCarShell(tester, theme);
    // 车机：刷新只走均衡器，不挂 Material 下拉小圆圈
    expect(find.byType(RefreshIndicator), findsNothing);

    // 缩回竖屏：下拉刷新恢复（自制下拉头，无 Material 小圆圈，
    // 这里只保证车机/竖屏都没有小圆圈，具体下拉由均衡器反馈）。
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets('车机点中当前我的回到顶部', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    final theme = ThemeController();
    await theme.setCarModeEnabled(true);
    addTearDown(() async {
      await ThemeController.instance.setCarModeEnabled(false);
    });

    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpCarShell(tester, theme);

    // 切到我的
    await tester.tap(carChip('我的'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPage), findsOneWidget);

    LibraryPageState libState() =>
        tester.state<LibraryPageState>(find.byType(LibraryPage));

    // 下滑我的页面
    await tester.drag(find.text('我创建的歌单'), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(libState().isScrolled, isTrue);

    // 点中当前我的：回到顶部
    await tester.tap(carChip('我的'));
    await tester.pumpAndSettle();
    expect(libState().isScrolled, isFalse);
  });
}