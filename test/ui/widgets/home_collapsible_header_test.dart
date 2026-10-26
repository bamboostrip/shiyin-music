import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/pages/search_page.dart';
import 'package:shiyin_music/ui/widgets/home_collapsible_header.dart';

class _FakeMusicApi implements MusicApi {
  @override
  Future<List<SearchHotCategory>> searchHotKeywords() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier implements PlayerController {
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeMusicApi api;
  late _FakeAuthController auth;
  late _FakePlayerController player;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = _FakeMusicApi();
    auth = _FakeAuthController();
    player = _FakePlayerController();
  });

  group('HomeCollapsibleHeaderDelegate extents & rebuild', () {
    test('computes default minExtent and maxExtent correctly', () {
      final delegate = HomeCollapsibleHeaderDelegate(
        api: api,
        auth: auth,
        player: player,
        sectionIndex: 0,
        onSectionChanged: (_) {},
      );

      // minExtent = topPadding(0) + pinnedTopOffset(4) + tabBarHeight(36) + bottomPadding(6) = 46.0
      expect(delegate.minExtent, 46.0);
      // maxExtent = topPadding(0) + topMargin(8) + searchBarHeight(36) + spacing(8) + tabBarHeight(36) + bottomPadding(6) = 94.0
      expect(delegate.maxExtent, 94.0);
      expect(delegate.maxExtent - delegate.minExtent, 48.0);
    });

    test('computes minExtent and maxExtent with custom topPadding and heights', () {
      final delegate = HomeCollapsibleHeaderDelegate(
        api: api,
        auth: auth,
        player: player,
        sectionIndex: 0,
        onSectionChanged: (_) {},
        topPadding: 24.0,
        searchBarHeight: 48.0,
        tabBarHeight: 40.0,
        bottomPadding: 12.0,
        spacing: 8.0,
      );

      // minExtent = 24 + 4 + 40 + 12 = 80.0
      expect(delegate.minExtent, 80.0);
      // maxExtent = 24 + 8 + 48 + 8 + 40 + 12 = 140.0
      expect(delegate.maxExtent, 140.0);
      expect(delegate.maxExtent - delegate.minExtent, 60.0);
    });

    test('shouldRebuild returns true when relevant properties change', () {
      final delegate1 = HomeCollapsibleHeaderDelegate(
        api: api,
        auth: auth,
        player: player,
        sectionIndex: 0,
        onSectionChanged: (_) {},
        topPadding: 0.0,
      );

      final delegateSame = HomeCollapsibleHeaderDelegate(
        api: api,
        auth: auth,
        player: player,
        sectionIndex: 0,
        onSectionChanged: delegate1.onSectionChanged,
        topPadding: 0.0,
      );

      final delegateIndexChanged = HomeCollapsibleHeaderDelegate(
        api: api,
        auth: auth,
        player: player,
        sectionIndex: 1,
        onSectionChanged: delegate1.onSectionChanged,
        topPadding: 0.0,
      );

      final delegatePaddingChanged = HomeCollapsibleHeaderDelegate(
        api: api,
        auth: auth,
        player: player,
        sectionIndex: 0,
        onSectionChanged: delegate1.onSectionChanged,
        topPadding: 20.0,
      );

      final delegateRefreshChanged = HomeCollapsibleHeaderDelegate(
        api: api,
        auth: auth,
        player: player,
        sectionIndex: 0,
        onSectionChanged: delegate1.onSectionChanged,
        topPadding: 0.0,
        onRefresh: () async {},
      );

      expect(delegate1.shouldRebuild(delegateSame), isFalse);
      expect(delegate1.shouldRebuild(delegateIndexChanged), isTrue);
      expect(delegate1.shouldRebuild(delegatePaddingChanged), isTrue);
      expect(delegate1.shouldRebuild(delegateRefreshChanged), isTrue);
    });
  });

  group('HomeBrandHeader Widget', () {
    testWidgets('renders line-art svg logo', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HomeBrandHeader(),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SvgPicture), findsOneWidget);
    });
  });

  group('HomeSearchBar Widget', () {
    testWidgets('renders placeholder text and search icon', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeSearchBar(
              api: api,
              auth: auth,
              player: player,
            ),
          ),
        ),
      );

      expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    });

    testWidgets('calls custom onTap when provided', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeSearchBar(
              onTap: () => tapped = true,
            ),
          ),
        ),
      );

      await tester.tap(find.text('搜索歌曲、歌手、专辑'));
      expect(tapped, isTrue);
    });

    testWidgets('navigates to SearchPage when tapped without custom onTap', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeSearchBar(
              api: api,
              auth: auth,
              player: player,
            ),
          ),
        ),
      );

      await tester.tap(find.text('搜索歌曲、歌手、专辑'));
      await tester.pumpAndSettle();

      expect(find.byType(SearchPage), findsOneWidget);
    });
  });

  group('HomeCapsuleTabBar Widget', () {
    testWidgets('renders all tabs and highlights selected tab', (tester) async {
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeCapsuleTabBar(
              selectedIndex: 0,
              onTabSelected: (i) => selected = i,
            ),
          ),
        ),
      );

      expect(find.text('推荐'), findsOneWidget);
      expect(find.text('排行榜'), findsOneWidget);
      expect(find.text('电台'), findsOneWidget);

      final textRecommend = tester.widget<Text>(find.text('推荐'));
      final textRank = tester.widget<Text>(find.text('排行榜'));

      expect(textRecommend.style?.fontWeight, FontWeight.w800);
      expect(textRank.style?.fontWeight, FontWeight.w600);

      await tester.tap(find.text('排行榜'));
      expect(selected, 1);
    });

    testWidgets('shows refresh button when onRefresh is provided', (tester) async {
      var refreshCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeCapsuleTabBar(
              selectedIndex: 0,
              onTabSelected: (_) {},
              onRefresh: () async {
                refreshCalled = true;
              },
            ),
          ),
        ),
      );

      expect(find.byTooltip('刷新'), findsOneWidget);
      await tester.tap(find.byTooltip('刷新'));
      expect(refreshCalled, isTrue);
    });

    testWidgets('hides refresh button when onRefresh is null', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeCapsuleTabBar(
              selectedIndex: 0,
              onTabSelected: (_) {},
              onRefresh: null,
            ),
          ),
        ),
      );

      expect(find.byTooltip('刷新'), findsNothing);
    });

    testWidgets('支持任意数量标签：4 个 tab 渲染与点击不越界', (tester) async {
      // 旧实现按 3 个固定宽度硬编码，tabs.length > 3 会 RangeError。
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeCapsuleTabBar(
              selectedIndex: 0,
              onTabSelected: (i) => selected = i,
              tabs: const ['推荐', '排行榜', '电台', '歌单'],
            ),
          ),
        ),
      );

      expect(find.text('歌单'), findsOneWidget);
      await tester.tap(find.text('歌单'));
      expect(selected, 3);
    });

    testWidgets('pageTracker 使胶囊随 PageView 滑动联动', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  height: 36,
                  child: HomeCapsuleTabBar(
                    selectedIndex: selected,
                    pageTracker: controller,
                    onTabSelected: (i) => selected = i,
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: controller,
                    children: const [
                      ColoredBox(color: Colors.red, child: SizedBox.expand()),
                      ColoredBox(color: Colors.green, child: SizedBox.expand()),
                      ColoredBox(color: Colors.blue, child: SizedBox.expand()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // 初始：第 1 个 tab 高亮。
      expect(
        tester.widget<Text>(find.text('推荐')).style?.fontWeight,
        FontWeight.w800,
      );

      // 编程式滑动到第 2 页：外部没有任何 setState，
      // 胶囊/文字只凭 pageTracker（PageController）联动更新。
      // ignore: unawaited_futures
      controller.animateToPage(
        1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.text('排行榜')).style?.fontWeight,
        FontWeight.w800,
      );
      expect(
        tester.widget<Text>(find.text('推荐')).style?.fontWeight,
        FontWeight.w600,
      );
    });
  });

  group('HomeCollapsibleHeader in CustomScrollView', () {
    testWidgets('collapses search bar on scroll and pins tab bar', (tester) async {
      var selected = 0;
      final scrollController = ScrollController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: scrollController,
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: HomeCollapsibleHeaderDelegate(
                    api: api,
                    auth: auth,
                    player: player,
                    sectionIndex: selected,
                    onSectionChanged: (i) => selected = i,
                  ),
                ),
                SliverToBoxAdapter(
                  child: Container(
                    height: 1200,
                    color: Colors.blueGrey,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // Initially expanded
      expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
      expect(find.text('推荐'), findsOneWidget);

      final initialSearchOpacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.text('搜索歌曲、歌手、专辑'),
          matching: find.byType(Opacity),
        ).first,
      );
      expect(initialSearchOpacity.opacity, 1.0);

      // Scroll down by 100 pixels (past 54px collapse extent)
      scrollController.jumpTo(100.0);
      await tester.pumpAndSettle();

      // Search bar opacity should be 0.0 and IgnorePointer active
      final collapsedSearchOpacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.text('搜索歌曲、歌手、专辑'),
          matching: find.byType(Opacity),
        ).first,
      );
      expect(collapsedSearchOpacity.opacity, 0.0);

      final ignorePointer = tester.widget<IgnorePointer>(
        find.ancestor(
          of: find.text('搜索歌曲、歌手、专辑'),
          matching: find.byType(IgnorePointer),
        ).first,
      );
      expect(ignorePointer.ignoring, isTrue);

      // Tabs should still be pinned and clickable
      expect(find.text('排行榜'), findsOneWidget);
      await tester.tap(find.text('排行榜'));
      expect(selected, 1);
    });

    testWidgets('adapts to dark mode and transparent background', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            scaffoldBackgroundColor: Colors.transparent,
          ),
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: CustomScrollView(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: HomeCollapsibleHeaderDelegate(
                    api: api,
                    auth: auth,
                    player: player,
                    sectionIndex: 0,
                    onSectionChanged: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
      expect(find.text('推荐'), findsOneWidget);
    });
  });
}