import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/player/mobile_lyric_list.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  _FakePlayerController({
    Duration initialPosition = Duration.zero,
    bool initialIsPlaying = false,
  }) : _position = initialPosition,
       _isPlaying = initialIsPlaying;

  Duration _position;
  bool _isPlaying;
  Duration? lastSeekPosition;
  int seekCalls = 0;

  @override
  Duration get smoothPosition => _position;

  @override
  Duration get position => _position;

  @override
  bool get isPlaying => _isPlaying;

  @override
  bool get isScrubbing => false;

  @override
  bool get isPreparing => false;

  @override
  List<LyricLine> lyrics = [];

  @override
  int activeLyricIndex = 0;

  final ValueNotifier<Duration> _posNotifier = ValueNotifier(Duration.zero);

  @override
  ValueNotifier<Duration> get positionListenable => _posNotifier;

  void updatePosition(Duration newPos, int newActiveIndex) {
    _position = newPos;
    activeLyricIndex = newActiveIndex;
    _posNotifier.value = newPos;
    notifyListeners();
  }

  @override
  Future<void> seekToAndPlay(Duration targetPosition) async {
    seekCalls++;
    lastSeekPosition = targetPosition;
    _position = targetPosition;
    _posNotifier.value = targetPosition;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final testLyrics = [
    const LyricLine(
      time: Duration(seconds: 0),
      text: 'First line of lyric',
      translation: '第一句歌词',
    ),
    const LyricLine(
      time: Duration(seconds: 5),
      text: 'Second line of lyric',
      translation: '第二句歌词',
      romanization: 'di er ju ge ci',
    ),
    const LyricLine(
      time: Duration(seconds: 10),
      text: 'Third line of lyric',
      translation: '第三句歌词',
    ),
  ];

  testWidgets('MobileLyricList renders lines and translations based on switches', (tester) async {
    final player = _FakePlayerController();
    player.lyrics = testLyrics;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 640,
            child: MobileLyricList(
              player: player,
              songHash: 'hash1',
              lyrics: testLyrics,
              activeIndex: 0,
              showTranslation: true,
              showRomanization: false,
              lyricScale: 1.0,
              isPageVisible: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('First line of lyric'), findsOneWidget);
    expect(find.text('第一句歌词'), findsOneWidget);
    expect(find.text('di er ju ge ci'), findsNothing);

    // Rebuild with romanization enabled
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 640,
            child: MobileLyricList(
              player: player,
              songHash: 'hash1',
              lyrics: testLyrics,
              activeIndex: 0,
              showTranslation: false,
              showRomanization: true,
              lyricScale: 1.0,
              isPageVisible: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('di er ju ge ci'), findsOneWidget);
    expect(find.text('第一句歌词'), findsNothing);
  });

  testWidgets('Tapping a lyric line triggers seekToAndPlay', (tester) async {
    final player = _FakePlayerController();
    player.lyrics = testLyrics;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 640,
            child: MobileLyricList(
              player: player,
              songHash: 'hash1',
              lyrics: testLyrics,
              activeIndex: 0,
              showTranslation: false,
              showRomanization: false,
              lyricScale: 1.0,
              isPageVisible: true,
            ),
          ),
        ),
      ),
    );

    // Tap on second line
    await tester.tap(find.text('Second line of lyric'));
    await tester.pump();

    expect(player.seekCalls, 1);
    expect(player.lastSeekPosition, const Duration(seconds: 5));
  });

  testWidgets('Scrolling lyric list shows seek pointer button', (tester) async {
    final player = _FakePlayerController();
    player.lyrics = testLyrics;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 640,
            child: MobileLyricList(
              player: player,
              songHash: 'hash1',
              lyrics: testLyrics,
              activeIndex: 0,
              showTranslation: false,
              showRomanization: false,
              lyricScale: 1.0,
              isPageVisible: true,
            ),
          ),
        ),
      ),
    );

    // Drag list
    await tester.drag(find.text('First line of lyric'), const Offset(0, -60));
    await tester.pump();

    final seekPointer = find.byKey(const ValueKey('mobile_lyric_seek_pointer_button'));
    expect(seekPointer, findsOneWidget);

    // Tapping seek pointer triggers seek
    await tester.tap(seekPointer);
    await tester.pump();

    expect(player.seekCalls, 1);
  });
}
