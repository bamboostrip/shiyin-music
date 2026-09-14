import 'dart:async';

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
import 'package:shiyin_music/ui/widgets/refresh_equalizer.dart';

/// 可阻塞的推荐流接口：挡住刷新中的网络 Future，让均衡器保持可见可断言。
class _BlockingApi implements MusicApi {
  Completer<DailyRecommend>? dailyGate;
  Completer<List<PlaylistSummary>>? plGate;
  Completer<List<Song>>? topGate;

  DailyRecommend get releasedDaily =>
      DailyRecommend(title: '每日推荐', songs: const []);

  @override
  Future<DailyRecommend> dailyRecommend() async {
    final g = dailyGate;
    if (g != null) await g.future;
    return releasedDaily;
  }

  @override
  Future<List<PlaylistSummary>> recommendedPlaylists(
      {int categoryId = 0, int page = 1}) async {
    final g = plGate;
    if (g != null) await g.future;
    return const [];
  }

  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async {
    final g = topGate;
    if (g != null) await g.future;
    return const [];
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
  Future<List<Song>> playlistSongs(String id,
          {int page = 1, int pageSize = 30, bool fetchAll = false}) async =>
      const [];
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

void main() {
  testWidgets('车机推荐刷新时均衡器唯一且出现在内容顶部', (tester) async {
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

    final api = _BlockingApi();
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

    Finder visibleEqualizer() => find.byWidgetPredicate(
          (w) => w is RefreshEqualizer && w.visible,
        );
    expect(visibleEqualizer(), findsNothing);

    // 挡住下一次刷新，让均衡器保持可见可断言
    api.dailyGate = Completer<DailyRecommend>();
    api.plGate = Completer<List<PlaylistSummary>>();
    api.topGate = Completer<List<Song>>();
    final st = tester.state<HomePageState>(find.byType(HomePage));
    unawaited(st.scrollToTopAndRefresh());
    // 手动推进越过 350ms 回顶动画（均衡器常动，不能 pumpAndSettle）
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));

    // 只有一个可见均衡器，且位于内容顶部（头部大卡之上，且与顶栏/Divider 保持 16px 呼吸间距，与排行榜/电台对齐）
    expect(visibleEqualizer(), findsOneWidget);
    final box =
        visibleEqualizer().evaluate().single.findRenderObject() as RenderBox;
    final top = box.localToGlobal(Offset.zero).dy;
    final headerTop =
        find.text('猜你喜欢').evaluate().single.findRenderObject() as RenderBox;
    final headerDy = headerTop.localToGlobal(Offset.zero).dy;
    expect(top, lessThan(headerDy));
    // 顶栏高度 72 + 分割线 1 = 73，均衡器距分割线 16px 呼吸间距，对应全局 dy 89（与排行榜/电台严格对齐）
    expect(top, equals(89.0));

    api.dailyGate?.complete(api.releasedDaily);
    api.plGate?.complete(const []);
    api.topGate?.complete(const []);
    await tester.pumpAndSettle();
    expect(visibleEqualizer(), findsNothing);
  });
}
