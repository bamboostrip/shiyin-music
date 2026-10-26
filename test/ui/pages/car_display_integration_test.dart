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
import 'package:shiyin_music/ui/car_display_viewport.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/app_shell.dart';
import 'package:shiyin_music/ui/pages/home_page.dart';
import 'package:shiyin_music/ui/widgets/car_left_player_panel.dart';

/// 车机显示视口与真实壳层的集成冒烟测试：
/// 主要验证「缩放 + 上下留白」接入 MaterialApp.builder 后，车机横屏壳层
/// 仍能正常布局（无 RenderFlex 溢出等 FlutterError），且关闭时不介入。

class _FakeMusicApi implements MusicApi {
  @override
  Future<List<Song>> playlistSongs(String id,
          {int page = 1, int pageSize = 30, bool fetchAll = false}) async =>
      const [];
  @override
  Future<DailyRecommend> dailyRecommend() async =>
      DailyRecommend(title: '每日推荐', songs: List.generate(8, _song));
  @override
  Future<List<PlaylistSummary>> recommendedPlaylists(
          {int categoryId = 0, int page = 1}) async =>
      List.generate(
        6,
        (i) => PlaylistSummary(id: 'pl_$i', title: '歌单$i', coverUrl: null),
      );
  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async =>
      List.generate(8, (i) => _song(100 + i));
  @override
  Future<List<RankCategory>> rankList({int withSong = 0}) async =>
      List.generate(5, (i) => RankCategory(rankId: 100 + i, rankName: '榜单$i'));
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

Song _song(int i) =>
    Song(id: 'id_$i', title: '新歌$i', artist: '歌手$i', hash: 'hash_$i');

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

  _FakePlayerController({this.currentSong});

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
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;
  @override
  Duration get smoothPosition => position;
  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier(Duration.zero);

  @override
  Future<void> togglePlay() async {}
  @override
  PlaybackMode cyclePlaybackMode() => playbackMode;
  @override
  void previewSeek(Duration position) {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> previous() async {}
  @override
  Future<void> next() async {}

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

/// 真实 AppShell（车机壳层测试共用的假依赖集合）。
Widget _shell(ThemeController theme, {PlayerController? player}) {
  return AppShell(
    api: _FakeMusicApi(),
    auth: _FakeAuthController(),
    player: player ?? _FakePlayerController(),
    cache: _FakeCache(),
    theme: theme,
    downloads: _FakeDownloadController(),
    localMusic: _FakeLocalMusicController(),
  );
}

/// 在横屏手机/车机尺寸下 pump 真实 AppShell，可注入 builder 包装。
Future<void> _pumpCarShell(
  WidgetTester tester, {
  required ThemeController theme,
  TransitionBuilder? builder,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      builder: builder,
      home: _shell(theme),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    debugDesktopFormFactorOverride = false;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  testWidgets('车机横屏 + 缩放 1.3 + 上下留白：壳层正常渲染，无布局异常', (tester) async {
    final theme = ThemeController();
    await theme.load();
    await theme.setCarModeEnabled(true);

    await _pumpCarShell(
      tester,
      theme: theme,
      // 与 main.dart 的接线方式保持一致：包住整个 Navigator。
      builder: (context, child) => CarDisplayViewport.maybe(
        enabled: theme.carModeEnabled,
        scale: 1.3,
        marginTop: 20,
        marginBottom: 10,
        child: child ?? const SizedBox.shrink(),
      ),
    );

    expect(tester.takeException(), isNull);
    // 车机顶栏存在（缩放不影响布局分支选择）。
    expect(find.text('推荐'), findsWidgets);
    expect(find.byType(CarDisplayViewport), findsOneWidget);
  });

  testWidgets('切换缩放档位（1.3 → 0.9 → 1.0）重建不崩溃', (tester) async {
    final theme = ThemeController();
    await theme.load();
    await theme.setCarModeEnabled(true);

    Future<void> pumpWith(double scale) async {
      await _pumpCarShell(
        tester,
        theme: theme,
        builder: (context, child) => CarDisplayViewport.maybe(
          enabled: theme.carModeEnabled,
          scale: scale,
          marginTop: 0,
          marginBottom: 0,
          child: child ?? const SizedBox.shrink(),
        ),
      );
      expect(tester.takeException(), isNull);
    }

    await pumpWith(1.3);
    await pumpWith(0.9);
    await pumpWith(1.0);
  });

  testWidgets('车机模式关闭：视口不介入，普通用户路径零变化', (tester) async {
    final theme = ThemeController();
    await theme.load();

    await _pumpCarShell(
      tester,
      theme: theme,
      builder: (context, child) => CarDisplayViewport.maybe(
        enabled: theme.carModeEnabled,
        scale: 1.3,
        marginTop: 20,
        marginBottom: 10,
        child: child ?? const SizedBox.shrink(),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(CarDisplayViewport), findsNothing);
  });

  testWidgets('顶栏已消费顶部 inset：内容区不再重复消费，左面板仍保留', (tester) async {
    final theme = ThemeController();
    await theme.load();
    await theme.setCarModeEnabled(true);

    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    await tester.pumpWidget(MaterialApp(home: _shell(theme)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 顶栏（app_shell）已经手动让出 24dp；其下内容区必须为 0，否则旧实现
    // 会在顶栏下方多出一整条空白。
    expect(
      MediaQuery.paddingOf(tester.element(find.byType(HomePage).first)).top,
      0,
    );
    // 左侧播放面板不在顶栏之下，仍应看到完整系统 inset 自行让位。
    expect(
      MediaQuery.paddingOf(
        tester.element(find.byType(CarLeftPlayerPanel).first),
      ).top,
      24,
    );
  });

  testWidgets('播放中的车机横屏 + 130% 缩放 + 留白：左面板不溢出', (tester) async {
    final theme = ThemeController();
    await theme.load();
    await theme.setCarModeEnabled(true);
    final player = _FakePlayerController(currentSong: _song(0))
      ..duration = const Duration(minutes: 3, seconds: 57);

    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => CarDisplayViewport.maybe(
          enabled: theme.carModeEnabled,
          scale: 1.3,
          marginTop: 20,
          marginBottom: 10,
          child: child ?? const SizedBox.shrink(),
        ),
        home: _shell(theme, player: player),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(CarLeftPlayerPanel), findsOneWidget);
  });

  testWidgets('常见车机分辨率 × 缩放档位：播放中壳层无布局异常', (tester) async {
    final cases = <(Size, double)>[
      (const Size(1280, 720), 1.3),
      (const Size(1024, 600), 1.3),
      (const Size(1280, 480), 1.3),
      (const Size(1280, 720), 0.8),
      // 用户实车日志复现：虚拟高度 564（非车机缩放，矮窗口/分屏同类形态）。
      (const Size(1280, 564), 1.0),
      (const Size(1280, 600), 1.0),
    ];
    final theme = ThemeController();
    await theme.load();
    await theme.setCarModeEnabled(true);

    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    for (final (size, scale) in cases) {
      tester.view.physicalSize = size;
      final player = _FakePlayerController(currentSong: _song(0))
        ..duration = const Duration(minutes: 3, seconds: 57);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => CarDisplayViewport.maybe(
            enabled: theme.carModeEnabled,
            scale: scale,
            marginTop: 20,
            marginBottom: 10,
            child: child ?? const SizedBox.shrink(),
          ),
          home: _shell(theme, player: player),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason:
            '${size.width.toInt()}x${size.height.toInt()} @ $scale 出现布局异常',
      );
    }
  });
}