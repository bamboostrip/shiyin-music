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
import 'package:shiyin_music/ui/pages/app_shell.dart';
import 'package:shiyin_music/ui/widgets/home_collapsible_header.dart';
import 'package:shiyin_music/ui/widgets/touch_sidebar.dart';

class _FakeMusicApi implements MusicApi {
  int dailyRecommendCalls = 0;
  int recommendedPlaylistsCalls = 0;
  int topSongsCalls = 0;

  List<Song> dailySongs = const [];
  List<Song> topSongsData = const [];
  List<PlaylistSummary> playlists = const [];
  List<Song> playlistSongsData = const [];
  List<RankCategory> ranks = const [];

  @override
  Future<List<Song>> playlistSongs(
    String id, {
    int page = 1,
    int pageSize = 30,
    bool fetchAll = false,
  }) async {
    return playlistSongsData;
  }

  @override
  Future<DailyRecommend> dailyRecommend() async {
    dailyRecommendCalls++;
    return DailyRecommend(title: '每日推荐', songs: dailySongs);
  }

  @override
  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async {
    recommendedPlaylistsCalls++;
    return playlists;
  }

  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async {
    topSongsCalls++;
    return topSongsData;
  }

  @override
  Future<List<RankCategory>> rankList({int withSong = 0}) async => ranks;

  @override
  Future<List<Song>> newSongs({int rankId = 0, int page = 1}) async =>
      const [];

  @override
  Future<List<FmStation>> fmRecommendedStations() async => fmRecommended;

  @override
  Future<List<FmClassGroup>> fmClassGroups() async => fmGroups;

  List<FmStation> fmRecommended = const [];
  List<FmClassGroup> fmGroups = const [];

  @override
  Future<Map<String, FmImage>> fmImages(List<String> fmids) async => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
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
      title: '新歌$i',
      artist: '歌手$i',
      hash: 'hash_$i',
    );

void main() {
  ThemeController();

  Future<_FakeMusicApi> pumpAppShell(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    List<FmStation>? radioRecommended,
    List<FmClassGroup>? radioGroups,
  }) async {
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    appShellNow = () => tester.binding.clock.now();
    addTearDown(() => appShellNow = DateTime.now);

    tester.view.physicalSize = size;
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
      ..ranks = List.generate(
        10,
        (i) => RankCategory(rankId: 100 + i, rankName: '榜单$i'),
      )
      ..fmRecommended = radioRecommended ?? const []
      ..fmGroups = radioGroups ?? const [];

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          api: api,
          auth: _FakeAuthController(),
          player: _FakePlayerController(),
          cache: _FakeCache(),
          theme: ThemeController(),
          downloads: _FakeDownloadController(),
          localMusic: _FakeLocalMusicController(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  ScrollableState getVerticalScrollable(WidgetTester tester) {
    final scrollables =
        tester.stateList<ScrollableState>(find.byType(Scrollable));
    return scrollables.firstWhere(
      (s) =>
          s.axisDirection == AxisDirection.down ||
          s.axisDirection == AxisDirection.up,
    );
  }

  testWidgets('滚动首页后双击底部「首页」，平滑回顶并展开搜索栏且触发刷新 API', (tester) async {
    final api = await pumpAppShell(tester);
    final initialDailyCalls = api.dailyRecommendCalls;
    expect(initialDailyCalls, greaterThanOrEqualTo(1));

    final searchBarTextFinder = find.text('搜索歌曲、歌手、专辑');
    expect(searchBarTextFinder, findsOneWidget);

    // Initial search opacity should be 1.0
    final initialOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: searchBarTextFinder,
        matching: find.byType(Opacity),
      ).first,
    );
    expect(initialOpacity.opacity, 1.0);

    final scrollable = getVerticalScrollable(tester);
    expect(scrollable.position.pixels, 0.0);

    // Scroll down 250 pixels
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, greaterThan(40.0));
    final collapsedOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: searchBarTextFinder,
        matching: find.byType(Opacity),
      ).first,
    );
    expect(collapsedOpacity.opacity, 0.0);

    // Double tap '首页' item on bottom bar
    final homeTabFinder = find.text('首页');
    expect(homeTabFinder, findsOneWidget);

    await tester.tap(homeTabFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(homeTabFinder);
    await tester.pumpAndSettle();

    // Verify it smoothly scrolled back to top
    expect(scrollable.position.pixels, 0.0);

    // Verify search bar is expanded again
    final restoredOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: searchBarTextFinder,
        matching: find.byType(Opacity),
      ).first,
    );
    expect(restoredOpacity.opacity, 1.0);

    // Verify refresh API was called
    expect(api.dailyRecommendCalls, greaterThan(initialDailyCalls));
  });

  testWidgets('滚动内容区后双击底部「首页」，内层回顶且搜索栏展开并刷新', (tester) async {
    final api = await pumpAppShell(tester);
    final initialDailyCalls = api.dailyRecommendCalls;

    final searchBarTextFinder = find.text('搜索歌曲、歌手、专辑');
    expect(searchBarTextFinder, findsOneWidget);

    // 直接拖动推荐 tab 的内层列表（模拟真实手指滚动内容区）。
    final innerFinder = find.byKey(
      const PageStorageKey<String>('home_tab_recommend'),
    );
    expect(innerFinder, findsOneWidget);
    await tester.drag(innerFinder, const Offset(0, -800));
    await tester.pumpAndSettle();

    final collapsedOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: searchBarTextFinder,
        matching: find.byType(Opacity),
      ).first,
    );
    expect(collapsedOpacity.opacity, 0.0);

    // Double tap '首页' item on bottom bar
    final homeTabFinder = find.text('首页');
    await tester.tap(homeTabFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(homeTabFinder);
    await tester.pumpAndSettle();

    // 内层回到顶部
    final innerState =
        tester.state<ScrollableState>(find.descendant(
      of: innerFinder,
      matching: find.byType(Scrollable),
    ).first);
    expect(innerState.position.pixels, 0.0);

    // 搜索栏重新展开
    final restoredOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: searchBarTextFinder,
        matching: find.byType(Opacity),
      ).first,
    );
    expect(restoredOpacity.opacity, 1.0);

    // Verify refresh API was called
    expect(api.dailyRecommendCalls, greaterThan(initialDailyCalls));
  });

  testWidgets('直接双击底部「首页」，触发刷新 API', (tester) async {
    final api = await pumpAppShell(tester);
    final initialDailyCalls = api.dailyRecommendCalls;

    final homeTabFinder = find.text('首页');
    await tester.tap(homeTabFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(homeTabFinder);
    await tester.pumpAndSettle();

    expect(api.dailyRecommendCalls, greaterThan(initialDailyCalls));
  });

  testWidgets('在「我的」页双击「首页」，切换回首页并触发回顶刷新', (tester) async {
    final api = await pumpAppShell(tester);
    final initialDailyCalls = api.dailyRecommendCalls;

    // Switch to '我的' tab
    final myTabFinder = find.text('我的');
    await tester.tap(myTabFinder);
    await tester.pumpAndSettle();

    // Now double tap '首页' tab
    final homeTabFinder = find.text('首页');
    await tester.tap(homeTabFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(homeTabFinder);
    await tester.pumpAndSettle();

    // HomePage is displayed again and refreshed
    expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
    expect(api.dailyRecommendCalls, greaterThan(initialDailyCalls));
  });

  testWidgets('单击「首页」不触发刷新', (tester) async {
    final api = await pumpAppShell(tester);
    final initialDailyCalls = api.dailyRecommendCalls;

    final homeTabFinder = find.text('首页');
    await tester.tap(homeTabFinder);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // Refresh API should NOT be called on single tap
    expect(api.dailyRecommendCalls, initialDailyCalls);
  });

  ScrollableState playlistRailScrollable(WidgetTester tester) {
    final states = tester.stateList<ScrollableState>(
      find.ancestor(
        of: find.text('歌单1'),
        matching: find.byType(Scrollable),
      ),
    );
    // 横轨是离卡片最近的横向 Scrollable（ancestor 按由近到远排序，取 first；
    // 外层 PageView 也是横向，在更后面）。
    return states.where((s) => s.position.axis == Axis.horizontal).first;
  }

  testWidgets('刷新后推荐歌单横轨回到最左侧', (tester) async {
    final api = await pumpAppShell(tester);
    expect(find.text('歌单1'), findsOneWidget);

    // 把推荐歌单横轨滚到中间（直接定位，避免手势被 PageView 抢走）。
    playlistRailScrollable(tester).position.jumpTo(200);
    await tester.pump();
    expect(playlistRailScrollable(tester).position.pixels, 200);

    // 双击底部「首页」触发刷新
    final homeTabFinder = find.text('首页');
    await tester.tap(homeTabFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(homeTabFinder);
    await tester.pumpAndSettle();

    // 横轨被重建，回到最左
    expect(playlistRailScrollable(tester).position.pixels, 0.0);
    expect(api.dailyRecommendCalls, greaterThan(0));
  });

  testWidgets('未滚动时单击本页顶部 tab 同样刷新', (tester) async {
    final api = await pumpAppShell(tester);
    final initialDailyCalls = api.dailyRecommendCalls;

    await tester.tap(find.text('推荐'));
    await tester.pumpAndSettle();

    expect(api.dailyRecommendCalls, greaterThan(initialDailyCalls));
  });

  testWidgets('下滑后单击本页顶部 tab 回顶并刷新', (tester) async {
    final api = await pumpAppShell(tester);
    final initialDailyCalls = api.dailyRecommendCalls;

    // 模拟手指下滑内容
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
    await tester.pumpAndSettle();

    // 单击当前页的顶部 tab「推荐」
    await tester.tap(find.text('推荐'));
    await tester.pumpAndSettle();

    expect(api.dailyRecommendCalls, greaterThan(initialDailyCalls));
    // 回到顶部，搜索栏重新展开
    final restoredOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('搜索歌曲、歌手、专辑'),
        matching: find.byType(Opacity),
      ).first,
    );
    expect(restoredOpacity.opacity, 1.0);
  });

  testWidgets('点击其他顶部 tab 只切换不刷新推荐流', (tester) async {
    final api = await pumpAppShell(tester);
    final initialDailyCalls = api.dailyRecommendCalls;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
    await tester.pumpAndSettle();

    await tester.tap(find.text('排行榜'));
    await tester.pumpAndSettle();

    expect(api.dailyRecommendCalls, initialDailyCalls);
  });

  ScrollableState nearestScrollableOf(WidgetTester tester, Finder finder) {
    // ancestor 按由近到远排序，first 即离目标最近的 Scrollable。
    return tester.state<ScrollableState>(
      find.ancestor(of: finder, matching: find.byType(Scrollable)).first,
    );
  }

  /// 顶部胶囊 tab（14.5px）：与内容区同名标题（如 17px 的「排行榜」分区标题）区分。
  Finder capsuleTab(String label) => find.byWidgetPredicate(
        (w) => w is Text && w.data == label && w.style?.fontSize == 14.5,
      );

  /// 内容区分区标题（17px），直接处于内层纵滑之下，适合取内层滚动位置。
  Finder sectionTitle(String label) => find.byWidgetPredicate(
        (w) => w is Text && w.data == label && w.style?.fontSize == 17,
      );

  testWidgets('切换 tab 顶栏收折态统一、深滚位置互不影响', (tester) async {
    await pumpAppShell(tester);

    // 推荐页下滑：顶栏收起（搜索框折叠）。
    await tester.drag(find.text('大家都在听'), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(
      nearestScrollableOf(tester, find.text('大家都在听')).position.pixels,
      greaterThan(100),
    );

    // 切到排行榜：顶栏是三 tab 共用的同一个行动主体，头部跟随收起
    //（48.0 = 顶栏完全收折距离，见 HomePageState._headerCollapseRange），
    // 而不是重新展开冒出搜索框。
    await tester.tap(capsuleTab('排行榜'));
    await tester.pumpAndSettle();
    expect(
      nearestScrollableOf(tester, sectionTitle('排行榜')).position.pixels,
      48.0,
    );

    // 深滚位置互不影响：排行榜继续深滚后切回推荐再切回，
    // 双方各自的内容进度都保留。
    await tester.drag(sectionTitle('排行榜'), const Offset(0, -600));
    await tester.pumpAndSettle();
    final rankDeep =
        nearestScrollableOf(tester, sectionTitle('排行榜')).position.pixels;
    expect(rankDeep, greaterThan(100));
    await tester.tap(capsuleTab('推荐'));
    await tester.pumpAndSettle();
    expect(
      nearestScrollableOf(tester, find.text('大家都在听')).position.pixels,
      greaterThan(100),
    );
    await tester.tap(capsuleTab('排行榜'));
    await tester.pumpAndSettle();
    expect(
      nearestScrollableOf(tester, sectionTitle('排行榜')).position.pixels,
      rankDeep,
    );
  });

  testWidgets('刷新推荐页后排行榜 tab 的滚动位置保持不变', (tester) async {
    await pumpAppShell(tester);

    double rankNow() => nearestScrollableOf(
          tester,
          sectionTitle('排行榜'),
        ).position.pixels;

    // 切到排行榜并下滑
    await tester.tap(capsuleTab('排行榜'));
    await tester.pumpAndSettle();
    await tester.drag(sectionTitle('排行榜'), const Offset(0, -600));
    await tester.pumpAndSettle();
    final recorded = rankNow();
    expect(recorded, greaterThan(100));

    // 回到推荐页并下滑
    await tester.tap(capsuleTab('推荐'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('大家都在听'), const Offset(0, -300));
    await tester.pumpAndSettle();

    // 单击本页顶部 tab「推荐」触发刷新
    await tester.tap(capsuleTab('推荐'));
    await tester.pumpAndSettle();

    // 再切回排行榜：位置应该还在
    await tester.tap(capsuleTab('排行榜'));
    await tester.pumpAndSettle();
    expect(rankNow(), recorded);
  });

  testWidgets('点按切页飞行被手势打断后，当前页仍可上滑回顶展开顶栏', (tester) async {
    await pumpAppShell(tester);

    // 推荐页下滑收起顶栏。
    await tester.drag(find.text('大家都在听'), const Offset(0, -500));
    await tester.pumpAndSettle();
    final deep = nearestScrollableOf(
      tester,
      find.text('大家都在听'),
    ).position.pixels;
    expect(deep, greaterThan(100));

    // 点按「电台」起飞跨页飞行（全程 260ms），逐帧推进到飞行中途：
    // 单次 pump(80ms) 不会 tick 滚动动画，需小步 pump 才能停在半路。
    // 中途手势反向滑动打断：修复前被打断的 _switchTarget 永远等不到
    // 落地清理，落地分支把推荐页一直 jumpTo 顶在地板高度，用户上滑
    // 回不了顶、点当前 tab 的回顶刷新也被打回。
    await tester.tap(capsuleTab('电台'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 从左下纵向内容区反向横滑打断飞行（该处无横滚滑轨，横向手势
    // 由 PageView 接管）。
    await tester.dragFrom(const Offset(80, 300), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(
      nearestScrollableOf(tester, find.text('大家都在听')).position.pixels,
      deep,
    );

    // 回顶恢复：点中当前 tab（推荐）触发 scrollToTopAndRefresh 回顶刷新，
    // 修复前残留的飞行标记会一直 jumpTo 打回回顶动画（只能换 tab 解锁）。
    await tester.tap(capsuleTab('推荐'));
    await tester.pumpAndSettle();
    expect(
      nearestScrollableOf(tester, find.text('大家都在听')).position.pixels,
      lessThan(1.0),
    );
    // 顶栏（搜索框）重新可见。
    expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
  });

  testWidgets('两次点击间隔超过 350ms 时不触发刷新', (tester) async {
    final api = await pumpAppShell(tester);
    final initialDailyCalls = api.dailyRecommendCalls;

    final homeTabFinder = find.text('首页');
    await tester.tap(homeTabFinder);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(homeTabFinder);
    await tester.pumpAndSettle();

    expect(api.dailyRecommendCalls, initialDailyCalls);
  });

  testWidgets('宽屏触屏侧栏下双击「推荐」触发刷新 API', (tester) async {
    final api = await pumpAppShell(tester, size: const Size(800, 1000));
    final initialDailyCalls = api.dailyRecommendCalls;

    // 旧 80dp NavigationRail 已被平板触屏侧栏取代（平板形态重设计）。
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(TouchSidebar), findsOneWidget);
    final recommendItem = find.descendant(
      of: find.byType(TouchSidebar),
      matching: find.text('推荐'),
    );
    expect(recommendItem, findsOneWidget);

    await tester.tap(recommendItem);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(recommendItem);
    await tester.pumpAndSettle();

    expect(api.dailyRecommendCalls, greaterThan(initialDailyCalls));
  });

  testWidgets('平板触屏侧栏：一级导航提升 + 搜索入口，内容区无胶囊 tab', (tester) async {
    await pumpAppShell(tester, size: const Size(1000, 800));

    expect(find.byType(NavigationRail), findsNothing);
    final sidebar = find.byType(TouchSidebar);
    expect(sidebar, findsOneWidget);
    // 首页三个子 tab（推荐/排行榜/电台）与「我的」全部提升为一级导航。
    for (final label in ['推荐', '排行榜', '电台', '我的']) {
      expect(
        find.descendant(of: sidebar, matching: find.text(label)),
        findsOneWidget,
      );
    }
    // 搜索入口胶囊在侧栏顶部（移动端顶栏搜索栏已随收折头一起移除）。
    expect(
      find.descendant(of: sidebar, matching: find.text('搜索')),
      findsOneWidget,
    );
    // 内容区不再渲染胶囊 tab，导航完全收敛到侧栏。
    expect(find.byType(HomeCapsuleTabBar), findsNothing);
    expect(find.text('大家都在听'), findsOneWidget);
  });

  testWidgets('平板侧栏点「电台」直接驱动首页切到电台分区', (tester) async {
    await pumpAppShell(tester, size: const Size(1000, 800));

    PageView homePageView() => tester.widget<PageView>(
          find.byKey(const Key('home_tabs_page_view')),
        );
    expect(homePageView().controller?.page ?? -1, 0);

    await tester.tap(
      find.descendant(
        of: find.byType(TouchSidebar),
        matching: find.text('电台'),
      ),
    );
    await tester.pumpAndSettle();

    expect(homePageView().controller?.page ?? -1, 2);
  });

  testWidgets('平板↔竖屏跨阈值来回切换不重挂滚动控制器', (tester) async {
    await pumpAppShell(tester, size: const Size(1000, 800));
    expect(find.byType(TouchSidebar), findsOneWidget);

    // 缩到 720 以下回到竖屏：HomePage 从「分区标题 + PageView」重构为
    // 「Stack + 吸顶头」。若 PageView 子树被销毁重建，三个 _tabControllers
    // 会在同一帧内短暂附着新旧两套 CustomScrollView（旧视图帧末才卸载），
    // 任何 .position/.offset 读取都会命中
    // '_positions.length == 1' 断言（Windows 自由拉伸窗口必现路径）。
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    expect(find.byType(TouchSidebar), findsNothing);
    expect(find.byType(HomeCapsuleTabBar), findsOneWidget);

    // 再拉回平板形态，同样不允许重挂。
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(find.byType(TouchSidebar), findsOneWidget);
    expect(find.byType(HomeCapsuleTabBar), findsNothing);
  });

  testWidgets('从排行榜切到「我的」不被弹回首页，回来仍停留在排行榜', (tester) async {
    await pumpAppShell(tester);

    // 切到首页的「排行榜」子 tab（PageView 第 2 页）。
    await tester.tap(capsuleTab('排行榜'));
    await tester.pumpAndSettle();
    expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);

    // 切到「我的」：修复前 HomePage.sectionIndex 会从 1 塌缩为 0，
    // didUpdateWidget 触发 animateToPage(0)，动画途中 onPageChanged(0)
    // 回调 onTabSwitch(1) 把用户弹回首页推荐 tab。
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    // 首页应保持退场（折叠头搜索框不可见），停留在我页面。
    expect(find.text('搜索歌曲、歌手、专辑'), findsNothing);

    // 单击「首页」返回：应恢复到排行榜子 tab，而非重置为推荐。
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
    final rankTabText = tester.widget<Text>(capsuleTab('排行榜'));
    expect(rankTabText.style?.fontWeight, FontWeight.w800);
  });

  testWidgets('推荐页收起后首次切到电台顶栏保持收起（跨页懒加载不对齐会闪出）', (
    tester,
  ) async {
    FmStation station(int i) => FmStation(id: 'fm_$i', name: '电台$i', type: 0);
    // 非车机分支分组渲染为 188 高的横滑轨道，需多组数据把内容撑到
    // 超出一屏，否则列表滚不到 48（完全收折距离）。
    await pumpAppShell(
      tester,
      radioRecommended: [station(1), station(2)],
      radioGroups: List.generate(
        4,
        (g) => FmClassGroup(
          id: 'g$g',
          name: '电台组$g',
          stations: List.generate(8, (i) => station(100 + g * 10 + i)),
        ),
      ),
    );

    // 推荐页下滑收起顶栏。
    await tester.drag(find.text('大家都在听'), const Offset(0, -500));
    await tester.pumpAndSettle();

    // 首次切到电台（推荐 0 → 电台 2，跨过排行榜且电台页首访懒加载）：
    // 顶栏应保持收起，电台内容推到 48（完全收折距离）而不是顶着 0
    // 把搜索框闪出来。
    await tester.tap(capsuleTab('电台'));
    await tester.pumpAndSettle();
    expect(
      nearestScrollableOf(tester, sectionTitle('推荐电台')).position.pixels,
      48.0,
    );

    // 再切回推荐、切回电台：依然保持收起。
    await tester.tap(capsuleTab('推荐'));
    await tester.pumpAndSettle();
    await tester.tap(capsuleTab('电台'));
    await tester.pumpAndSettle();
    expect(
      nearestScrollableOf(tester, sectionTitle('推荐电台')).position.pixels,
      48.0,
    );
  });
}
