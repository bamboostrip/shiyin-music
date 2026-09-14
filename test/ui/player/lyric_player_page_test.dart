import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/player/lyric_bottom_bar.dart';
import 'package:shiyin_music/ui/player/lyric_views.dart';
import 'package:shiyin_music/ui/player/mobile_lyric_list.dart';
import 'package:shiyin_music/ui/player/player_comment_button.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  _FakePlayerController({bool initialIsPlaying = true})
    : _isPlaying = initialIsPlaying;

  bool _isPlaying;

  @override
  bool get isPlaying => _isPlaying;

  @override
  bool get isScrubbing => false;

  @override
  bool get isPreparing => false;

  @override
  Duration get smoothPosition => Duration.zero;

  @override
  Duration get position => Duration.zero;

  @override
  List<LyricLine> lyrics = [];

  @override
  int activeLyricIndex = 0;

  final ValueNotifier<Duration> _posNotifier = ValueNotifier(Duration.zero);

  @override
  ValueNotifier<Duration> get positionListenable => _posNotifier;

  @override
  Future<void> ensureLyricsLoaded() async {}

  @override
  Future<void> togglePlay() async {
    _isPlaying = !_isPlaying;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  final testLyrics = [
    const LyricLine(
      time: Duration(seconds: 0),
      text: 'Hello world',
      translation: '你好世界',
    ),
    const LyricLine(
      time: Duration(seconds: 4),
      text: 'Sing a song',
      translation: '唱一首歌',
      romanization: 'chang yi shou ge',
    ),
  ];

  const testSong = Song(
    id: 's_test',
    hash: 'h_test',
    title: 'Test Song',
    artist: 'Test Artist',
    source: SongSource.kugou,
  );

  testWidgets('LyricPlayerPage renders empty state when lyrics are empty', (
    tester,
  ) async {
    final player = _FakePlayerController();
    player.lyrics = [];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricPlayerPage(
            player: player,
            song: testSong,
            isPageVisible: true,
          ),
        ),
      ),
    );

    expect(find.text('暂无歌词'), findsOneWidget);
    expect(find.byType(LyricBottomBar), findsNothing);
  });

  testWidgets(
    'LyricPlayerPage renders MobileLyricList and LyricBottomBar when lyrics exist',
    (tester) async {
      final player = _FakePlayerController();
      player.lyrics = testLyrics;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 700,
              child: LyricPlayerPage(
                player: player,
                song: testSong,
                isPageVisible: true,
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Verify MobileLyricList and LyricBottomBar exist
      expect(find.byType(MobileLyricList), findsOneWidget);
      expect(find.byType(LyricBottomBar), findsOneWidget);
      expect(find.byType(PlayerCommentButton), findsOneWidget);

      // Verify text & translation visible by default
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('你好世界'), findsOneWidget);

      // Verify toggle pills
      expect(find.text('词'), findsOneWidget);
      expect(find.text('译'), findsOneWidget);
      expect(find.text('音'), findsOneWidget);

      // Tap [译] to turn off translation
      await tester.tap(find.text('译'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Translation should now be hidden
      expect(find.text('你好世界'), findsNothing);
    },
  );
}
