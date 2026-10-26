// 顶栏搜索结果页的路由治理回归测试：
// 连续搜索必须 replace 栈顶搜索页而非叠层（pushReplacement 下旧路由
// popped 迟到不得误清跟踪标记），搜索页上方有其它详情页时不得误 replace。
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
import 'package:shiyin_music/services/desktop_lyrics_service.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/desktop/desktop_shell.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/search_page.dart';

class _FakeMusicApi implements MusicApi {
  @override
  Future<List<SearchHotCategory>> searchHotKeywords() async => const [];

  @override
  Future<List<String>> searchSuggest(String keywords) async => const [];

  @override
  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async => const [];

  @override
  Future<List<SearchArtistResult>> searchArtists(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async => const [];

  @override
  Future<List<SearchAlbumResult>> searchAlbums(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async => const [];

  @override
  Future<List<Song>> searchNetEaseSongs(
    String keywords, {
    int limit = 30,
    int offset = 0,
  }) async => const [];

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
  final ValueNotifier<bool> openLyricsSettingsRequest =
      ValueNotifier<bool>(false);

  @override
  DesktopLyricsSettings desktopLyricsSettings = const DesktopLyricsSettings();

  @override
  bool desktopLyricsEnabled = true;

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
  bool isDesktopLyricsSupported = true;

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ThemeController();

  Future<void> pumpShell(WidgetTester tester) async {
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopShell(
          api: _FakeMusicApi(),
          auth: _FakeAuthController(),
          player: _FakePlayerController(),
          cache: _FakeCache(),
          downloads: _FakeDownloadController(),
          theme: ThemeController(),
          localMusic: _FakeLocalMusicController(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> submitSearch(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField).first, query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  testWidgets('连续搜索 replace 栈顶搜索页，一次返回即回内容根', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpShell(tester);

    expect(find.byType(SearchPage), findsNothing);

    // 三连搜：第 2/3 次提交时第 1 次的路由 popped 已完成（防抖竞态窗口
    // 已过），replace 判定必须仍准确——若用布尔标记跟踪，旧路由的
    // whenComplete 会把标记误清，第 3 次退化为叠层 push。
    await submitSearch(tester, '第一次');
    expect(find.byType(SearchPage), findsOneWidget);
    await submitSearch(tester, '第二次');
    await submitSearch(tester, '第三次');
    expect(find.byType(SearchPage), findsOneWidget);

    // 栈上只有一个搜索页：点一次返回应回到内容根，而不是露出上一轮
    // 搜索结果页。
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsNothing);
    // 内容根仍在（侧栏可见）。
    expect(find.text('推荐'), findsWidgets);
  });
}