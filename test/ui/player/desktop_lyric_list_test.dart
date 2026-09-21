import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/song.dart';
import 'package:shiyin_music/ui/player/desktop_lyric_list.dart';
import 'package:shiyin_music/ui/player/lyric_display_mode.dart';
import 'package:shiyin_music/ui/player/lyric_karaoke_text.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  _FakePlayerController({
    Duration initialPosition = Duration.zero,
    bool initialIsPlaying = false,
  }) : _position = initialPosition,
       _isPlaying = initialIsPlaying;

  Duration _position;
  final bool _isPlaying;

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
    _position = targetPosition;
    _posNotifier.value = targetPosition;
    notifyListeners();
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

LyricLine _line(
  int index, {
  List<LyricWord> words = const [],
}) => LyricLine(
  time: Duration(seconds: index * 5),
  text: 'Lyric line number $index',
  words: words,
);

const _listKey = ValueKey('desktop_lyric_list');

Widget _wrap(DesktopLyricList child) => MaterialApp(
  home: Scaffold(
    body: SizedBox(width: 640, height: 640, child: child),
  ),
);

DesktopLyricList _buildList({
  required PlayerController player,
  required List<LyricLine> lyrics,
  required int activeIndex,
}) {
  return DesktopLyricList(
    key: _listKey,
    player: player,
    songHash: 'hash1',
    lyrics: lyrics,
    activeIndex: activeIndex,
    displayMode: LyricDisplayMode.lyricsOnly,
    lyricScale: 1.0,
  );
}

double _lineCenterDy(WidgetTester tester, String text) {
  final listBox = tester.renderObject<RenderBox>(find.byKey(_listKey));
  final lineBox = tester.renderObject<RenderBox>(find.text(text));
  return lineBox.localToGlobal(
    lineBox.size.center(Offset.zero),
    ancestor: listBox,
  ).dy;
}

void main() {
  testWidgets('playing line with word timings renders karaoke LyricText', (
    tester,
  ) async {
    final lyrics = [
      _line(0),
      _line(1, words: const [
        LyricWord(time: Duration(seconds: 5), duration: Duration(milliseconds: 800), text: 'Lyric'),
        LyricWord(time: Duration(seconds: 6), duration: Duration(milliseconds: 800), text: ' line '),
        LyricWord(time: Duration(seconds: 7), duration: Duration(milliseconds: 800), text: 'number'),
        LyricWord(time: Duration(seconds: 8), duration: Duration(milliseconds: 800), text: ' 1'),
      ]),
      _line(2),
    ];
    final player = _FakePlayerController();
    player.lyrics = lyrics;
    player.activeLyricIndex = 1;

    await tester.pumpWidget(_wrap(_buildList(player: player, lyrics: lyrics, activeIndex: 1)));
    await tester.pump();

    expect(find.byType(LyricText), findsOneWidget);
    expect(
      tester.widget<LyricText>(find.byType(LyricText)).line.text,
      'Lyric line number 1',
    );
  });

  testWidgets('playing line without word timings stays plain text', (tester) async {
    final lyrics = [_line(0), _line(1), _line(2)];
    final player = _FakePlayerController();
    player.lyrics = lyrics;
    player.activeLyricIndex = 1;

    await tester.pumpWidget(_wrap(_buildList(player: player, lyrics: lyrics, activeIndex: 1)));
    await tester.pump();

    expect(find.byType(LyricText), findsNothing);
    expect(find.text('Lyric line number 1'), findsOneWidget);
  });

  testWidgets('deep index in a long list centers despite estimate drift', (
    tester,
  ) async {
    final lyrics = List.generate(150, _line);
    final player = _FakePlayerController();
    player.lyrics = lyrics;
    player.activeLyricIndex = 110;

    await tester.pumpWidget(_wrap(_buildList(player: player, lyrics: lyrics, activeIndex: 110)));
    await tester.pump();

    expect(
      _lineCenterDy(tester, 'Lyric line number 110'),
      closeTo(640 * 0.38, 30),
    );
  });

  testWidgets('scrolling: focused row keeps standard size, playing row stays big white', (
    tester,
  ) async {
    final lyrics = List.generate(40, _line);
    final player = _FakePlayerController();
    player.lyrics = lyrics;
    player.activeLyricIndex = 0;

    await tester.pumpWidget(_wrap(_buildList(player: player, lyrics: lyrics, activeIndex: 0)));
    await tester.pump();

    // deterministic scroll: user browsing (holding); playing row 0 stays visible,
    // the crosshair focus lands on row 3 (row pitch ~49px, focus line at 38%)
    await tester.drag(find.text('Lyric line number 0'), const Offset(0, -150));
    await tester.pumpAndSettle();

    // 收集所有行样式（主题层也可能有 AnimatedDefaultTextStyle，故按集合断言）
    final styles = tester
        .widgetList<AnimatedDefaultTextStyle>(find.byType(AnimatedDefaultTextStyle))
        .map((w) => w.style)
        .toList();

    // playing row keeps pure white + 30px even while user browses
    final playingStyles = styles.where((s) => s.fontSize == 30.0).toList();
    expect(playingStyles, hasLength(1));
    expect(playingStyles.single.color, equals(Colors.white));

    // the focused (crosshair) row: standard 24px, only brightened to 85% white
    final focusedStyles = styles
        .where((s) => s.color == Colors.white.withValues(alpha: .85))
        .toList();
    expect(focusedStyles, hasLength(1));
    expect(focusedStyles.single.fontSize, equals(24.0));

    // all other rows stay dimmed at 32% white (theme-level styles share the
    // collection but never match 24px + 32% white)
    final normalStyles = styles
        .where(
          (s) =>
              s.fontSize == 24.0 &&
              s.color == Colors.white.withValues(alpha: .32),
        )
        .toList();
    expect(normalStyles.length, greaterThanOrEqualTo(5));
  });

  testWidgets('auto-resume after idle brings active line back to focus line', (
    tester,
  ) async {
    final lyrics = List.generate(150, _line);
    final player = _FakePlayerController();
    player.lyrics = lyrics;
    player.activeLyricIndex = 0;

    await tester.pumpWidget(_wrap(_buildList(player: player, lyrics: lyrics, activeIndex: 0)));
    await tester.pump();

    // fling far away from active line 0
    await tester.fling(find.text('Lyric line number 0'), const Offset(0, -3000), 4000);
    await tester.pumpAndSettle();

    // song keeps playing, line advances
    player.updatePosition(const Duration(seconds: 5), 1);
    await tester.pump();

    // idle past the 3.5s resume delay, then let the resume animation finish
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(
      _lineCenterDy(tester, 'Lyric line number 1'),
      closeTo(640 * 0.38, 30),
    );
  });
}
