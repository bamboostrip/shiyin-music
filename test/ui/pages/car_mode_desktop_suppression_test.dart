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
import 'package:shiyin_music/ui/pages/home_page.dart';
import 'package:shiyin_music/ui/widgets/home_song_row.dart';
import 'package:shiyin_music/ui/widgets/horizontal_wheel_scroll.dart';

/// 桌面形态必须屏蔽移动端残留的车机开关（v3.0.6 回归）：
/// PC 窗口恒横屏，`横屏 && carModeEnabled` 若在桌面当真，全项目约 18 处
/// 车机分支会把移动端/车机布局整套套到 PC 上（AppShell 早已桌面先行
/// 返回，页面层缺同款护栏）；v3.0.5 之所以没暴露，是 `_SongSection`
/// 盒子路径里残留的 `isDesktopFormFactor` 桌面分支恰好兜住了首页，
/// 12c3a08 把它当死代码删除后 PC 即回归移动端观感。
class _FakeMusicApi implements MusicApi {
  List<Song> dailySongs = const [];

  @override
  Future<DailyRecommend> dailyRecommend() async =>
      DailyRecommend(title: '每日推荐', songs: dailySongs);

  @override
  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async => const [];

  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async =>
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
  List<Song> queue = const [];
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
  @override
  bool autoPlayOnStartupEnabled = false;
  @override
  bool hasRestoredPlaybackState = false;

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
  bool get isLoggedIn => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCache implements CacheService {
  @override
  Future<CacheResult<T>?> read<T>(
    String key, {
    required T Function(Map<String, dynamic> json) decode,
    Duration ttl = const Duration(hours: 24),
  }) async => null;

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
      title: '歌曲_$i',
      artist: '歌手_$i',
      hash: 'hash_$i',
    );

void main() {
  testWidgets('桌面形态：车机开关读取恒为 false，移动形态不受影响', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    await theme.setCarModeEnabled(true);
    addTearDown(() async {
      await theme.setCarModeEnabled(false);
    });

    debugDesktopFormFactorOverride = true;
    expect(theme.carModeEnabled, isFalse,
        reason: '桌面形态必须屏蔽移动端残留的车机开关');

    debugDesktopFormFactorOverride = false;
    expect(theme.carModeEnabled, isTrue,
        reason: '移动形态（Android 车机/手机横屏）行为不变');
    debugDesktopFormFactorOverride = null;
  });

  testWidgets('桌面宽窗：残留车机开关不再把首页劫持成车机/移动布局', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    await theme.setCarModeEnabled(true);
    addTearDown(() async {
      await theme.setCarModeEnabled(false);
    });

    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    // PC 常见几何：横屏（宽>高在桌面恒成立），残留开关若当真即走车机分支。
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeMusicApi()
      ..dailySongs = List.generate(30, _song);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePage(
            api: api,
            auth: _FakeAuthController(),
            player: _FakePlayerController(),
            cache: _FakeCache(),
            theme: theme,
            downloads: _FakeDownloadController(),
            localMusic: _FakeLocalMusicController(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 桌面宽壳：歌曲以纵向多列网格直出（HomeSongRow 可见），不出现
    // 车机/移动口径的横向分页 PageView。
    expect(find.byType(HorizontalWheelPageScroll), findsNothing,
        reason: '车机分支会把「大家都在听」渲染成横向分页（移动端观感）');
    expect(find.byType(HomeSongRow), findsWidgets);
    // 猜你喜欢卡片与网格行都会带上首曲标题，断言存在即可。
    expect(find.text('歌曲_0'), findsWidgets);
  });
}
