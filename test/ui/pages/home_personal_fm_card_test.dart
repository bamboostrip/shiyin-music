// 首页「猜你喜欢」私人 FM 卡片：加载态/可点性回归（用户反馈：明明已经在播放，
// 右上角还转圈很久、点不动）。
// 根因：卡片 loading 混入了后台「预览批次预取」；且播放器 FM 拉取在已经出声后
// 仍按 isLoadingPersonalFm 显示转圈。修复后：
//   - 预览预取无论多慢都不影响卡片（不转圈、不禁用点按）；
//   - FM 首播/续批只要已经出声就不再转圈，播放/暂停随时可点。
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

Song _song(int i) => Song(
      id: 'id_$i',
      title: '歌曲_$i',
      artist: '歌手_$i',
      hash: 'hash_$i',
    );

class _FakeMusicApi implements MusicApi {
  /// 预览批次请求挂起不返回：模拟真实网络下 /personal/fm 慢（实测 4s+）。
  @override
  Future<List<Song>> personalFm({
    String? hash,
    String? songId,
    int? playtime,
    bool isOverplay = false,
  }) => Future<List<Song>>.delayed(const Duration(minutes: 5));

  @override
  Future<DailyRecommend> dailyRecommend() async =>
      DailyRecommend(title: '每日推荐', songs: List.generate(3, _song));

  @override
  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async =>
      const [];

  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async =>
      const [];

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
  List<Song> queue = const [];

  int togglePlayCalls = 0;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier(Duration.zero);
  @override
  Duration get duration => Duration.zero;
  @override
  Duration get position => Duration.zero;
  @override
  String? errorMessage;
  @override
  bool get isPreparing => false;
  @override
  bool autoPlayOnStartupEnabled = false;
  @override
  bool hasRestoredPlaybackState = false;

  @override
  Future<void> togglePlay() async {
    togglePlayCalls++;
    isPlaying = !isPlaying;
    notifyListeners();
  }

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
    bool preservePersonalFmSession = false,
  }) async {
    currentSong = song;
    if (queue != null) this.queue = queue;
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
  bool isLiked(Song song) => false;
  @override
  Future<void> toggleLike(Song song) async {}
  @override
  bool get isLoggedIn => false;
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

void main() {
  ThemeController();

  Future<_FakePlayerController> pumpHomePage(WidgetTester tester) async {
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);
    tester.view.physicalSize = const Size(400, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final player = _FakePlayerController()
      ..isPersonalFmActive = true
      ..isPlaying = true
      ..currentSong = _song(0)
      ..queue = [_song(0), _song(1)];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePage(
            api: _FakeMusicApi(),
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
    // 多放几帧：让首帧的预览预取请求真正挂起（它永不返回）。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return player;
  }

  /// 元素在屏幕上的矩形（卡片按钮用坐标区分底部唱片的小暂停图标）。
  Rect? rectOf(Element element) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 卡片右上角的播放/暂停键（排除底部导航唱片上的小暂停图标）。
  Finder cardPlayButton() {
    final icons = find.byIcon(Icons.pause_rounded);
    final inCard = icons.evaluate().where((element) {
      final rect = rectOf(element);
      return rect != null && rect.top < 420;
    }).toList();
    expect(inCard.length, 1, reason: '猜你喜欢卡片应保留播放/暂停键');
    return find.byWidget(inCard.single.widget);
  }

  testWidgets('预览批次预取未完成时，正在播放的 FM 卡片不转圈、可暂停', (tester) async {
    final player = await pumpHomePage(tester);

    // 不应该出现「正在开启私人 FM…」的转圈态文案。
    expect(find.text('正在开启私人 FM…'), findsNothing);
    expect(find.text('私人 FM 播放中 · 点击暂停'), findsOneWidget);

    await tester.tap(cardPlayButton());
    await tester.pump();
    expect(player.togglePlayCalls, 1);
    expect(player.isPlaying, isFalse);
  });

  testWidgets('FM 续批拉取中但已经出声：不转圈、播放/暂停仍可点', (tester) async {
    final player = await pumpHomePage(tester);
    // 模拟「曲末续拉下一批」：isLoadingPersonalFm=true 但当前歌还在播。
    player.isLoadingPersonalFm = true;
    player.notifyListeners();
    await tester.pump();

    expect(find.text('正在开启私人 FM…'), findsNothing);
    await tester.tap(cardPlayButton());
    await tester.pump();
    expect(player.togglePlayCalls, 1);
  });
}
