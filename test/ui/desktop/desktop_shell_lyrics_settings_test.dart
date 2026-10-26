import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:shiyin_music/ui/pages/desktop_lyrics_settings_page.dart';

class _FakeMusicApi implements MusicApi {
  @override
  Future<DailyRecommend> dailyRecommend() async =>
      const DailyRecommend(title: '每日推荐', songs: []);

  @override
  Future<List<FmStation>> fmRecommendedStations() async => const [];

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
  Future<List<RecommendedSongCard>> recommendedSongCards() async => const [];

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
  final ValueNotifier<bool> openLyricsSettingsRequest =
      ValueNotifier<bool>(false);

  @override
  DesktopLyricsSettings desktopLyricsSettings = const DesktopLyricsSettings();

  @override
  bool desktopLyricsEnabled = true;

  @override
  Future<void> setDesktopLyricsPreviewVisible(bool visible) async {}

  @override
  Future<void> updateDesktopLyricsSettings(
    DesktopLyricsSettings settings,
  ) async {
    desktopLyricsSettings = settings;
    notifyListeners();
  }

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ThemeController();

  late _FakePlayerController player;
  late int windowRestorerCalls;

  setUp(() {
    player = _FakePlayerController();
    windowRestorerCalls = 0;
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    _FakePlayerController? customPlayer,
    Future<void> Function()? customWindowRestorer,
  }) async {
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
          player: customPlayer ?? player,
          cache: _FakeCache(),
          downloads: _FakeDownloadController(),
          theme: ThemeController(),
          localMusic: _FakeLocalMusicController(),
          windowRestorer: customWindowRestorer ??
              () async {
                windowRestorerCalls++;
              },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'When openLyricsSettingsRequest is toggled to true, windowRestorer is called and DesktopLyricsSettingsPage is pushed',
    (tester) async {
      await pumpShell(tester);

      expect(find.byType(DesktopLyricsSettingsPage), findsNothing);
      expect(windowRestorerCalls, 0);

      // Trigger request
      player.openLyricsSettingsRequest.value = true;
      await tester.pumpAndSettle();

      expect(windowRestorerCalls, 1);
      expect(find.byType(DesktopLyricsSettingsPage), findsOneWidget);
      // Sidebar should still be present in the shell
      expect(find.text('推荐'), findsWidgets);
    },
  );

  testWidgets(
    'When openLyricsSettingsRequest fires again while page is open, does not push duplicate routes',
    (tester) async {
      await pumpShell(tester);

      player.openLyricsSettingsRequest.value = true;
      await tester.pumpAndSettle();

      expect(windowRestorerCalls, 1);
      expect(find.byType(DesktopLyricsSettingsPage), findsOneWidget);

      // Fire request again
      player.openLyricsSettingsRequest.value = false;
      player.openLyricsSettingsRequest.value = true;
      await tester.pumpAndSettle();

      expect(windowRestorerCalls, 2);
      expect(find.byType(DesktopLyricsSettingsPage), findsOneWidget);
    },
  );

  testWidgets('Unregistering listener on dispose does not leak', (
    tester,
  ) async {
    await pumpShell(tester);

    // Replace shell with an empty widget to trigger dispose
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    final callsBefore = windowRestorerCalls;
    // Toggling request should not trigger windowRestorer or throw
    player.openLyricsSettingsRequest.value = true;
    await tester.pumpAndSettle();

    expect(windowRestorerCalls, callsBefore);
  });

  testWidgets('didUpdateWidget correctly updates openLyricsSettingsRequest listener', (
    tester,
  ) async {
    final player1 = _FakePlayerController();
    final player2 = _FakePlayerController();

    await pumpShell(tester, customPlayer: player1);

    // Rebuild DesktopShell with player2
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopShell(
          api: _FakeMusicApi(),
          auth: _FakeAuthController(),
          player: player2,
          cache: _FakeCache(),
          downloads: _FakeDownloadController(),
          theme: ThemeController(),
          localMusic: _FakeLocalMusicController(),
          windowRestorer: () async {
            windowRestorerCalls++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Triggering player1 should do nothing
    player1.openLyricsSettingsRequest.value = true;
    await tester.pumpAndSettle();
    expect(windowRestorerCalls, 0);

    // Triggering player2 should open settings
    player2.openLyricsSettingsRequest.value = true;
    await tester.pumpAndSettle();
    expect(windowRestorerCalls, 1);
    expect(find.byType(DesktopLyricsSettingsPage), findsOneWidget);
  });
}