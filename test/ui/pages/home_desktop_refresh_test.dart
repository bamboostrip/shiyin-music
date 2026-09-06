import 'package:flutter/gestures.dart';
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
import 'package:shiyin_music/ui/widgets/cover_play_overlay.dart';

class _FakeMusicApi implements MusicApi {
  int dailyRecommendCalls = 0;
  int recommendedPlaylistsCalls = 0;
  int topSongsCalls = 0;

  List<Song> dailySongs = const [];
  List<Song> topSongsData = const [];
  List<PlaylistSummary> playlists = const [];

  List<Song> playlistSongsData = const [];

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
  Future<List<RankCategory>> rankList({int withSong = 0}) async => const [];

  @override
  Future<List<Song>> newSongs({int rankId = 0, int page = 1}) async =>
      const [];

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

  int playCalls = 0;
  Song? lastPlayedSong;
  List<Song>? lastQueue;

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
  }) async {
    playCalls++;
    lastPlayedSong = song;
    lastQueue = queue;
    this.queue = queue ?? [song];
    currentSong = song;
    isPlaying = true;
    notifyListeners();
  }

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCache implements CacheService {
  @override
  Future<CacheResult<T>?> read<T>(
    String key, {
    required T Function(Map<String, dynamic> json) decode,
    Duration ttl = const Duration(hours: 24),
  }) async {
    return null;
  }

  @override
  Future<void> write(String key, Map<String, dynamic> payload) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDownloadController extends ChangeNotifier
    implements DownloadController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalMusicController extends ChangeNotifier
    implements LocalMusicController {
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
  // _RecommendHeader / ThemeController.instance 读取车机开关，默认 false。
  ThemeController();

  Future<(_FakeMusicApi, _FakePlayerController)> pumpHome(
    WidgetTester tester, {
    required bool desktop,
  }) async {
    debugDesktopFormFactorOverride = desktop;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    // 桌面端窗口宽度须过网格起点（840），覆盖 _TopSongRail 网格分支。
    tester.view.physicalSize = desktop
        ? const Size(1200, 900)
        : const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeMusicApi()
      ..dailySongs = [_song(1), _song(2)]
      ..topSongsData = [
        _song(101),
        _song(102),
        _song(103),
        _song(104),
        _song(105),
        _song(106),
      ]
      ..playlists = const [
        PlaylistSummary(id: 'pl_1', title: '歌单一', coverUrl: null),
      ]
      ..playlistSongsData = [
        _song(201),
        _song(202),
      ];
    final player = _FakePlayerController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePage(
            api: api,
            auth: _FakeAuthController(),
            player: player,
            cache: _FakeCache(),
            theme: ThemeController(),
            downloads: _FakeDownloadController(),
            localMusic: _FakeLocalMusicController(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (api, player);
  }

  testWidgets('桌面端：无下拉刷新，页头刷新按钮存在且触发数据重载', (tester) async {
    final (api, _) = await pumpHome(tester, desktop: true);

    expect(find.byType(RefreshIndicator), findsNothing);
    final refreshButton = find.byTooltip('刷新');
    expect(refreshButton, findsOneWidget);

    final before = api.dailyRecommendCalls;
    await tester.tap(refreshButton);
    await tester.pumpAndSettle();
    expect(api.dailyRecommendCalls, greaterThan(before));
  });

  testWidgets('桌面端：新歌速递封面 hover 浮现播放蒙层，点击直接播放对应队列', (tester) async {
    final (api, player) = await pumpHome(tester, desktop: true);

    final topSongTitle = find.text('新歌101');
    expect(topSongTitle, findsOneWidget);
    final topSongCard = find.ancestor(
      of: topSongTitle,
      matching: find.byType(InkWell),
    ).first;
    final topSongOverlay = find.descendant(
      of: topSongCard,
      matching: find.byType(CoverPlayOverlay),
    );
    expect(topSongOverlay, findsOneWidget);

    double overlayOpacity(Finder finder) => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: finder,
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;

    // 未 hover：新歌速递封面播放按钮隐藏（透明度 0）
    final unhoveredTopSongPlayIcon = find.descendant(
      of: topSongOverlay,
      matching: find.byIcon(Icons.play_arrow_rounded),
    );
    expect(overlayOpacity(unhoveredTopSongPlayIcon), 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(topSongOverlay));
    await tester.pumpAndSettle();

    final playIcon = find.descendant(
      of: topSongOverlay,
      matching: find.byIcon(Icons.play_arrow_rounded),
    );
    expect(playIcon, findsOneWidget);
    expect(overlayOpacity(playIcon), 1);

    await tester.tap(playIcon);
    await tester.pumpAndSettle();
    expect(player.lastPlayedSong?.hash, 'hash_101');
    expect(player.lastQueue?.map((s) => s.hash), api.topSongsData.map((s) => s.hash));
  });

  testWidgets('桌面端：推荐歌单卡片 hover 右下角浮现播放按钮，点击直接播放歌单', (tester) async {
    final (api, player) = await pumpHome(tester, desktop: true);

    // 找到推荐歌单卡片（标题为 '歌单一'）
    final playlistTitle = find.text('歌单一');
    expect(playlistTitle, findsOneWidget);

    // 找到包含该卡片的 InkWell
    final cardFinder = find.ancestor(
      of: playlistTitle,
      matching: find.byType(InkWell),
    ).first;

    // 未 hover 时，卡片上播放按钮透明度为 0
    final unhoveredCardPlayIcon = find.descendant(
      of: cardFinder,
      matching: find.byIcon(Icons.play_arrow_rounded),
    );
    double cardPlayOpacity(Finder finder) => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: finder,
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;
    expect(cardPlayOpacity(unhoveredCardPlayIcon), 0);

    // 鼠标悬停到歌单卡片上
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(cardFinder));
    await tester.pumpAndSettle();

    // 悬停后右下角浮现播放按钮
    final playBtnFinder = find.descendant(
      of: cardFinder,
      matching: find.byIcon(Icons.play_arrow_rounded),
    );
    expect(playBtnFinder, findsOneWidget);

    // 验证播放按钮底色使用项目主题色 primary（而非硬编码的 QQ 音乐绿）
    final playMaterial = tester.widgetList<Material>(
      find.descendant(of: cardFinder, matching: find.byType(Material)),
    ).firstWhere((m) => m.shape is CircleBorder && m.elevation == 2);
    final theme = Theme.of(tester.element(cardFinder));
    expect(playMaterial.color, theme.colorScheme.primary);

    // 单击右下角播放按钮直接播放该歌单曲目
    await tester.tap(playBtnFinder);
    await tester.pumpAndSettle();

    expect(player.lastPlayedSong?.hash, 'hash_201');
    expect(player.lastQueue?.map((s) => s.hash), api.playlistSongsData.map((s) => s.hash));
  });

  testWidgets('移动端：保留下拉刷新，无页头刷新按钮、无悬浮播放蒙层', (tester) async {
    await pumpHome(tester, desktop: false);

    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(find.byTooltip('刷新'), findsNothing);
    // 蒙层动画层（AnimatedOpacity）在移动端不存在（enabled=false 直接返回封面）。
    expect(find.byType(AnimatedOpacity), findsNothing);
  });
}
