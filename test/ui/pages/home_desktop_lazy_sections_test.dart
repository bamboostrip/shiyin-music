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
import 'package:shiyin_music/ui/widgets/home_song_row.dart';

/// 桌面宽窗下首页三个分区改懒构建 sliver（P0-2）后的回归验证：
/// 「大家都在听」初始只实例化滚动可见附近的行，滚动到底后尾部分区
/// （推荐歌单 / 新歌速递网格）仍能懒构建并可见。
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
  // 首页分区读取车机开关，默认 false。
  ThemeController();

  testWidgets('桌面宽窗：推荐 tab 首屏不全量构建歌曲行，滚动到底尾部分区懒构建且可见',
      (tester) async {
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    // 1200x900 → 内容区宽 1164 ≥ 1050，「大家都在听」按 3 列布局。
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const songCount = 120;
    final api = _FakeMusicApi()
      ..dailySongs = List.generate(songCount, _song)
      ..topSongsData = List.generate(10, (i) => _song(1000 + i))
      ..playlists = List.generate(
        6,
        (i) => PlaylistSummary(
          id: 'pl_$i',
          title: '歌单$i',
          coverUrl: null,
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

    // 首屏只实例化视口 + 缓存区附近的行，不再全量 eager 构建 120 行。
    final recommendTabScrollable = find
        .descendant(
          of: find.byKey(const PageStorageKey<String>('home_tab_recommend')),
          matching: find.byType(Scrollable),
        )
        .first;
    int builtRows() =>
        tester.widgetList<HomeSongRow>(find.byType(HomeSongRow)).length;

    expect(builtRows(), lessThan(songCount));
    expect(builtRows(), greaterThan(0));
    // 最后一行（行主序尾格）首屏不可见、未构建。
    expect(find.text('歌曲_${songCount - 1}'), findsNothing);

    // 滚动到「大家都在听」末行：懒构建按需补齐尾部行。
    await tester.scrollUntilVisible(
      find.text('歌曲_${songCount - 1}'),
      300,
      scrollable: recommendTabScrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('歌曲_${songCount - 1}'), findsOneWidget);
    // 远离视口的行已回收，实例化数量仍有界（未退化成全量常驻）。
    expect(builtRows(), lessThan(songCount));

    // 继续滚到 tab 底部：尾部分区（推荐歌单 / 新歌速递网格）懒构建且可见。
    await tester.scrollUntilVisible(find.text('歌单5'), 300,
        scrollable: recommendTabScrollable);
    await tester.scrollUntilVisible(find.text('歌曲_1009'), 300,
        scrollable: recommendTabScrollable);
    await tester.pumpAndSettle();
    expect(find.text('歌单5'), findsOneWidget);
    expect(find.text('歌曲_1009'), findsOneWidget);
    expect(builtRows(), lessThan(songCount));
  });
}
