import 'dart:async';

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
import 'package:shiyin_music/ui/desktop/desktop_shell.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/refresh_equalizer.dart';

/// 可门控的假 API：dailyRecommend 首次直返（冷启动加载），
/// 之后若挂上 [gate] 则挂起（测试中观察刷新在途的均衡器动画）。
class _GateMusicApi implements MusicApi {
  int dailyRecommendCalls = 0;
  Completer<DailyRecommend>? gate;

  List<Song> dailySongs = const [];

  int fmRecommendedCalls = 0;
  Completer<List<FmStation>>? fmGate;
  List<FmStation> fmStations = const [];

  @override
  Future<DailyRecommend> dailyRecommend() async {
    dailyRecommendCalls++;
    if (gate != null) return gate!.future;
    return DailyRecommend(title: '每日推荐', songs: dailySongs);
  }

  @override
  Future<List<FmStation>> fmRecommendedStations() async {
    fmRecommendedCalls++;
    if (fmGate != null) return fmGate!.future;
    return fmStations;
  }

  @override
  Future<List<Song>> playlistSongs(
    String id, {
    int page = 1,
    int pageSize = 30,
    bool fetchAll = false,
  }) async =>
      const [];

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
  Future<List<RankCategory>> rankList({int withSong = 0}) async => const [];

  @override
  Future<List<Song>> newSongs({int rankId = 0, int page = 1}) async =>
      const [];

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
  bool isDesktopLyricsSupported = false;

  @override
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;

  @override
  AudioQuality audioQuality = AudioQuality.standard;

  @override
  double get volume => 1.0;

  @override
  bool get isAudioEffectsSupported => false;

  @override
  bool get desktopLyricsLocked => false;

  @override
  bool get isSleepTimerActive => false;

  @override
  bool get isSleepFinishCurrentSong => false;

  @override
  Duration? sleepTimerRemaining;

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
      title: '歌$i',
      artist: '歌手$i',
      hash: 'hash_$i',
    );

Finder _visibleEqualizer() => find.byWidgetPredicate(
      (w) => w is RefreshEqualizer && w.visible,
    );

void main() {
  // HomePage / DesktopShell 读取车机开关，默认 false。
  ThemeController();

  // 可控时钟：驱动侧栏双击检测窗口（desktopShellNow）。
  var fakeNow = DateTime(2026, 1, 1);
  setUp(() => desktopShellNow = () => fakeNow);
  tearDown(() => desktopShellNow = DateTime.now);
  void advanceClock(Duration delta) => fakeNow = fakeNow.add(delta);

  Future<_GateMusicApi> pumpShell(WidgetTester tester) async {
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _GateMusicApi()..dailySongs = [_song(1), _song(2)];

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopShell(
          api: api,
          auth: _FakeAuthController(),
          player: _FakePlayerController(),
          cache: _FakeCache(),
          downloads: _FakeDownloadController(),
          theme: ThemeController(),
          localMusic: _FakeLocalMusicController(),
        ),
      ),
    );
    // 冷启动加载落地（首次 dailyRecommend 直返）。
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('桌面端：双击侧栏当前分区触发回顶刷新，顶部均衡器动画出现后收起', (tester) async {
    final api = await pumpShell(tester);

    // 侧栏「推荐」是默认选中分区；标题文本同时出现在内容区工具条，
    // 侧栏在布局树更前，取 first。
    final navItem = find.text('推荐').first;
    final before = api.dailyRecommendCalls;

    api.gate = Completer<DailyRecommend>();
    await tester.tap(navItem); // 第一击：单击语义（选中当前分区，无刷新）
    await tester.pump();
    expect(api.dailyRecommendCalls, before, reason: '单击不触发刷新');
    await tester.tap(navItem); // 第二击：与第一击间隔远小于 350ms，视为双击
    // 回顶动画（已在顶部即回）后的微任务里才启动 refresh()，多 pump
    // 两帧让 refresh 的 setState 落地、均衡器重建出来。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(api.dailyRecommendCalls, greaterThan(before), reason: '双击触发刷新');
    expect(
      _visibleEqualizer(),
      findsWidgets,
      reason: '刷新在途时顶部出现均衡器动画',
    );

    api.gate!.complete(
      DailyRecommend(title: '每日推荐', songs: [_song(1), _song(2)]),
    );
    await tester.pumpAndSettle();
    // 最短展示保持期（600ms）过后才真正收起。
    await tester.pump(const Duration(milliseconds: 700));
    expect(_visibleEqualizer(), findsNothing, reason: '刷新完成后均衡器收起');
  });

  testWidgets('桌面端：切到电台后双击侧栏「电台」，电台刷新且顶部均衡器出现后收起', (tester) async {
    final api = await pumpShell(tester);

    // 电台初始数据（首次直返），让电台 pane 渲染出内容。
    api.fmStations = const [FmStation(id: 'fm_1', name: '电台一', type: 2)];
    await tester.tap(find.text('电台').first); // 单击切换到电台（不刷新）
    await tester.pumpAndSettle();
    final before = api.fmRecommendedCalls;
    expect(before, greaterThan(0), reason: '前置：电台初始加载已发生');

    api.fmGate = Completer<List<FmStation>>();
    await tester.tap(find.text('电台').first); // 第一击
    await tester.pump();
    await tester.tap(find.text('电台').first); // 第二击：视为双击
    // 回顶（已在顶部即回）后的微任务里启动 refresh，多 pump 一帧。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(api.fmRecommendedCalls, greaterThan(before), reason: '双击触发电台刷新');
    expect(
      _visibleEqualizer(),
      findsWidgets,
      reason: '刷新在途时顶部出现均衡器动画',
    );

    api.fmGate!.complete(const [FmStation(id: 'fm_1', name: '电台一', type: 2)]);
    await tester.pumpAndSettle();
    // 最短展示保持期（600ms）过后才真正收起。
    await tester.pump(const Duration(milliseconds: 700));
    expect(_visibleEqualizer(), findsNothing, reason: '刷新完成后均衡器收起');
  });

  testWidgets('桌面端：双击间隔约 400ms（鼠标常见节奏）仍触发刷新', (tester) async {
    final api = await pumpShell(tester);

    final navItem = find.text('推荐').first;
    final before = api.dailyRecommendCalls;

    api.gate = Completer<DailyRecommend>();
    await tester.tap(navItem);
    advanceClock(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.tap(navItem);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(api.dailyRecommendCalls, greaterThan(before), reason: '400ms 间隔仍视为双击');
    expect(_visibleEqualizer(), findsWidgets);

    api.gate!.complete(DailyRecommend(title: '每日推荐', songs: const []));
    await tester.pumpAndSettle();
  });

  testWidgets('桌面端：双击间隔超过 500ms 不触发刷新（仍是两次单击）', (tester) async {
    final api = await pumpShell(tester);

    final navItem = find.text('推荐').first;
    final before = api.dailyRecommendCalls;

    await tester.tap(navItem);
    // 推进假时钟越过 500ms 双击窗口（与 pump 的帧时钟独立）。
    advanceClock(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.tap(navItem);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(api.dailyRecommendCalls, before, reason: '间隔超窗不视为双击');
  });
}