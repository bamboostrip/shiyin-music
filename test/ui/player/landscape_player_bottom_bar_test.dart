import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/desktop/desktop_player_bar.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/player/landscape_player.dart';
import 'package:shiyin_music/ui/player/player_controls.dart';

const _song = Song(id: '1', title: '测试歌曲', artist: '测试歌手', hash: 'hash-1');

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
  List<LyricLine> lyrics = const [];

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
  var closeCalls = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    player = _FakePlayerController();
    auth = _FakeAuthController();
    closeCalls = 0;
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
            onClose: () => closeCalls++,
            onQueue: () {},
            onArtistTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('PC 播放页底部常驻播放栏', () {
    testWidgets('桌面形态：底部挂载整条常驻播放栏，最左为「收起」键', (tester) async {
      await pumpContent(tester, desktop: true);

      expect(find.byType(DesktopPlayerBar), findsOneWidget);
      expect(find.byTooltip('收起播放页'), findsOneWidget);
      // 收起键在曲目信息左侧（QQ 音乐 PC 正在播放页的最左位）
      expect(
        tester.getTopLeft(find.byTooltip('收起播放页')).dx,
        lessThan(tester.getTopLeft(find.byType(DesktopPlayerBar)).dx + 60),
      );

      // 底栏落在内容区下方：其顶边在歌词/封面区域之下
      final barRect = tester.getRect(find.byType(DesktopPlayerBar));
      expect(barRect.bottom, closeTo(800, 1));
      expect(barRect.height, 80);
    });

    testWidgets('桌面形态：进度/控制下沉到底栏，右栏不再重复渲染', (tester) async {
      await pumpContent(tester, desktop: true);

      expect(find.byType(Progress), findsNothing);
      expect(find.byType(Controls), findsNothing);
      // 但控制能力没丢：底栏里播放模式/上一首/下一首/队列都在
      expect(find.byTooltip('列表循环（点击切换）'), findsOneWidget);
      expect(find.byTooltip('上一首'), findsOneWidget);
      expect(find.byTooltip('下一首'), findsOneWidget);
      expect(find.byTooltip('播放队列'), findsOneWidget);
    });

    testWidgets('桌面形态：点击最左收起键返回主界面', (tester) async {
      await pumpContent(tester, desktop: true);

      await tester.tap(find.byTooltip('收起播放页'));
      await tester.pump();
      expect(closeCalls, 1);
    });

    testWidgets('桌面形态：点底栏不再叠第二层播放页（不触发任何 push）', (tester) async {
      await pumpContent(tester, desktop: true);

      // openPlayerPageEnabled=false：点空白处应无任何导航/异常
      await tester.tapAt(const Offset(4, 760));
      await tester.pump();
      expect(find.byType(DesktopPlayerBar), findsOneWidget);
      expect(closeCalls, 0);
    });
  });

  group('车机横屏不受影响', () {
    testWidgets('非桌面形态：不挂常驻底栏，右栏保留进度 + 控制', (tester) async {
      await pumpContent(tester, desktop: false);

      expect(find.byType(DesktopPlayerBar), findsNothing);
      expect(find.byTooltip('收起播放页'), findsNothing);
      expect(find.byType(Progress), findsOneWidget);
      expect(find.byType(Controls), findsOneWidget);
    });
  });
}
