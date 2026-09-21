import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/player/landscape_player.dart';

const _song = Song(id: '1', title: '测试歌曲', artist: '测试歌手', hash: 'hash-1');

const _lyrics = [
  LyricLine(time: Duration.zero, text: '第一行'),
  LyricLine(time: Duration(seconds: 5), text: '第二行'),
  LyricLine(time: Duration(seconds: 10), text: '第三行'),
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

  Duration? lastSeekPosition;
  int seekCalls = 0;

  @override
  List<LyricLine> lyrics = _lyrics;

  @override
  int activeLyricIndex = 0;

  @override
  Duration get smoothPosition => Duration.zero;

  @override
  bool isScrubbing = false;

  @override
  SongClimax? climax;

  @override
  AudioQuality audioQuality = AudioQuality.standard;

  @override
  bool isDesktopLyricsSupported = false;

  @override
  bool desktopLyricsEnabled = false;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  @override
  Future<void> seekToAndPlay(Duration targetPosition) async {
    seekCalls++;
    lastSeekPosition = targetPosition;
  }

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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    player = _FakePlayerController();
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Future<LyricController> pumpPanel(WidgetTester tester) async {
    // 车机形态（非桌面）：LandscapeLyricPanel 走 flutter_lyric 分支
    debugDesktopFormFactorOverride = false;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LandscapePlayerContent(
            player: player,
            auth: _FakeAuthController(),
            song: _song,
            onClose: () {},
            onQueue: () {},
            onArtistTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final view = tester.widget<LyricView>(find.byType(LyricView));
    return view.controller;
  }

  group('车机歌词滚动准星（与移动端对齐）', () {
    testWidgets('未滚动时不出现时间胶囊，滚动选中时浮现并显示该行时间', (
      tester,
    ) async {
      final controller = await pumpPanel(tester);

      expect(
        find.byKey(const ValueKey('landscape_lyric_seek_pointer_button')),
        findsNothing,
      );

      // 模拟用户滚动：进入选区并把锚点行定到第 2 行（00:05）
      controller.selectedIndexNotifier.value = 1;
      controller.isSelectingNotifier.value = true;
      await tester.pump();

      final capsule = find.byKey(
        const ValueKey('landscape_lyric_seek_pointer_button'),
      );
      expect(capsule, findsOneWidget);
      expect(
        find.descendant(of: capsule, matching: find.text('00:05')),
        findsOneWidget,
      );
    });

    testWidgets('点击时间胶囊跳转播放到该行并立即恢复跟随', (tester) async {
      final controller = await pumpPanel(tester);

      controller.selectedIndexNotifier.value = 2;
      controller.isSelectingNotifier.value = true;
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('landscape_lyric_seek_pointer_button')),
      );
      await tester.pump();

      expect(player.seekCalls, 1);
      expect(player.lastSeekPosition, const Duration(seconds: 10));
      // 点击后立即退出选区恢复跟随（与移动端胶囊一致）
      expect(controller.isSelectingNotifier.value, isFalse);
    });
  });
}
