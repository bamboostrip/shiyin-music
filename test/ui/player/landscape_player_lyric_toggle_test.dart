import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/player/landscape_player.dart';
import 'package:shiyin_music/ui/player/lyric_views.dart';

const _song = Song(id: '1', title: '测试歌曲', artist: '测试歌手', hash: 'hash-1');

const _lyrics = [
  LyricLine(
    time: Duration.zero,
    text: '第一行',
    translation: '翻译第一行',
    romanization: 'di yi hang',
  ),
];

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong = _song;

  @override
  bool isPlaying = false;

  @override
  bool isPreparing = false;

  @override
  double volume = 0.8;

  @override
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;

  @override
  String get playbackModeLabel => '列表循环';

  @override
  Duration duration = const Duration(minutes: 3);

  @override
  Duration position = Duration.zero;

  @override
  Duration get smoothPosition => Duration.zero;

  @override
  bool isScrubbing = false;

  @override
  SongClimax? climax;

  @override
  AudioQuality audioQuality = AudioQuality.standard;

  @override
  List<LyricLine> lyrics = _lyrics;

  @override
  int activeLyricIndex = -1;

  @override
  bool isDesktopLyricsSupported = false;

  @override
  bool desktopLyricsEnabled = false;

  @override
  bool desktopLyricsLocked = false;

  @override
  DownloadController? downloadController;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  // 歌词进度偏移（PlayerController 接口）：测试默认零偏移。
  @override
  Duration get lyricPosition => smoothPosition;

  @override
  Duration lyricOffset = Duration.zero;

  @override
  bool get hasLyricOffset => false;

  @override
  String get lyricOffsetLabel => '无偏移';

  @override
  Future<void> adjustLyricOffset(Duration delta) async {}

  @override
  Future<void> resetLyricOffset() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  Future<void> toggleLike(Song song) async {}

  @override
  List<PlaylistSummary> get createdPlaylists => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakePlayerController player;
  late _FakeAuthController auth;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    player = _FakePlayerController();
    auth = _FakeAuthController();
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Future<void> pumpContent(WidgetTester tester, {required bool desktop}) async {
    debugDesktopFormFactorOverride = desktop;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LandscapePlayerContent(
            player: player,
            auth: auth,
            song: _song,
            onClose: () {},
            onQueue: () {},
            onArtistTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('分栏播放页译/音切换按钮', () {
    testWidgets('桌面形态：封面左下渲染 译/音 按钮，默认译开音关', (tester) async {
      await pumpContent(tester, desktop: true);

      expect(find.byTooltip('翻译 (已开启)'), findsOneWidget);
      expect(find.byTooltip('拼音/音译 (已关闭)'), findsOneWidget);
      // 按钮位于封面（左）列：横坐标落在左半屏
      expect(
        tester.getTopLeft(find.byTooltip('翻译 (已开启)')).dx,
        lessThan(640),
      );
      // 默认开启翻译：歌词区渲染翻译行
      expect(find.text('翻译第一行'), findsOneWidget);
    });

    testWidgets('桌面形态：点「译」关闭翻译并落盘，歌词区翻译行消失', (tester) async {
      await pumpContent(tester, desktop: true);

      await tester.tap(find.byTooltip('翻译 (已开启)'));
      await tester.pump();

      expect(find.byTooltip('翻译 (已关闭)'), findsOneWidget);
      expect(find.text('翻译第一行'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(kLyricShowTranslationPrefKey),
        isFalse,
      );
    });

    testWidgets('桌面形态：译关时开「音」显示音译行', (tester) async {
      await pumpContent(tester, desktop: true);

      await tester.tap(find.byTooltip('翻译 (已开启)'));
      await tester.pump();
      await tester.tap(find.byTooltip('拼音/音译 (已关闭)'));
      await tester.pump();

      expect(find.text('di yi hang'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kLyricShowRomanizationPrefKey), isTrue);
    });

    testWidgets('歌词无翻译/音译内容时不渲染按钮', (tester) async {
      player.lyrics = const [LyricLine(time: Duration.zero, text: '第一行')];
      await pumpContent(tester, desktop: true);

      expect(find.byTooltip('翻译 (已开启)'), findsNothing);
      expect(find.byTooltip('拼音/音译 (已关闭)'), findsNothing);
    });

    testWidgets('车机横屏：同样渲染并可用，切换结果落盘共用设置', (tester) async {
      await pumpContent(tester, desktop: false);

      expect(find.byTooltip('翻译 (已开启)'), findsOneWidget);
      await tester.tap(find.byTooltip('翻译 (已开启)'));
      await tester.pump();

      expect(find.byTooltip('翻译 (已关闭)'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kLyricShowTranslationPrefKey), isFalse);
    });
  });
}
