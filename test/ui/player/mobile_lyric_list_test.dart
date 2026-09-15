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
  final bool _isPlaying;
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

/// 测量某行文本相对列表视口中心的纵向位置（用于断言 38% 焦点线对齐）。
double _lineCenterDy(WidgetTester tester, Key listKey, String text) {
  final listBox = tester.renderObject<RenderBox>(find.byKey(listKey));
  final lineBox = tester.renderObject<RenderBox>(find.text(text));
  return lineBox.localToGlobal(
    lineBox.size.center(Offset.zero),
    ancestor: listBox,
  ).dy;
}

List<LyricLine> _generateLyrics(int count) => List.generate(
  count,
  (i) => LyricLine(time: Duration(seconds: i * 5), text: 'Lyric line number $i'),
);

const _listKey = ValueKey('mobile_lyric_list');

Widget _wrap(MobileLyricList child) => MaterialApp(
  home: Scaffold(
    body: SizedBox(width: 360, height: 640, child: child),
  ),
);

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

  testWidgets(
    'MobileLyricList renders lines and translations based on switches',
    (tester) async {
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
    },
  );

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

    final seekPointer = find.byKey(
      const ValueKey('mobile_lyric_seek_pointer_button'),
    );
    expect(seekPointer, findsOneWidget);

    // Tapping seek pointer triggers seek
    await tester.tap(seekPointer);
    await tester.pump();

    expect(player.seekCalls, 1);
  });

  testWidgets(
    'Dragging list preserves active lyric size/style and keeps focused line standard size with heightened color',
    (tester) async {
      final longLyrics = List.generate(
        15,
        (i) => LyricLine(
          time: Duration(seconds: i * 5),
          text: 'Line number $i of lyric song',
        ),
      );
      final player = _FakePlayerController();
      player.lyrics = longLyrics;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 640,
              child: MobileLyricList(
                player: player,
                songHash: 'hash1',
                lyrics: longLyrics,
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

      // Drag list up so a non-playing line moves into center
      await tester.drag(
        find.text('Line number 0 of lyric song'),
        const Offset(0, -180),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final styleWidgets = tester
          .widgetList<AnimatedDefaultTextStyle>(
            find.byType(AnimatedDefaultTextStyle),
          )
          .toList();

      final activeStyles = styleWidgets.where((w) => w.style.fontSize == 26.0);
      expect(activeStyles, isNotEmpty);
      expect(activeStyles.first.style.fontWeight, FontWeight.w900);

      final focusedStyles = styleWidgets.where(
        (w) => w.style.fontSize == 20.0 && (w.style.color?.a ?? 0) > 0.8,
      );
      expect(focusedStyles, isNotEmpty);

      // Normal non-focused, non-playing lines have size 20.0 and lower opacity (alpha 0.35)
      final normalStyles = styleWidgets.where(
        (w) => w.style.fontSize == 20.0 && (w.style.color?.a ?? 0) < 0.5,
      );
      expect(normalStyles, isNotEmpty);
    },
  );

  group('active line positioning', () {
    testWidgets(
      'mid-song entry centers active line on the 38% focus line',
      (tester) async {
        final lyrics = _generateLyrics(40);
        final player = _FakePlayerController();
        player.lyrics = lyrics;
        player.activeLyricIndex = 25;

        await tester.pumpWidget(
          _wrap(
            MobileLyricList(
              key: _listKey,
              player: player,
              songHash: 'hash1',
              lyrics: lyrics,
              activeIndex: 25,
              showTranslation: false,
              showRomanization: false,
              lyricScale: 1.0,
              isPageVisible: true,
            ),
          ),
        );
        await tester.pump();

        expect(
          _lineCenterDy(tester, _listKey, 'Lyric line number 25'),
          closeTo(640 * 0.38, 30),
        );
      },
    );

    testWidgets(
      'isPageVisible false -> true transition centers active line',
      (tester) async {
        final lyrics = _generateLyrics(40);
        final player = _FakePlayerController();
        player.lyrics = lyrics;
        player.activeLyricIndex = 25;

        MobileLyricList build(bool visible) => MobileLyricList(
          key: _listKey,
          player: player,
          songHash: 'hash1',
          lyrics: lyrics,
          activeIndex: 25,
          showTranslation: false,
          showRomanization: false,
          lyricScale: 1.0,
          isPageVisible: visible,
        );

        await tester.pumpWidget(_wrap(build(false)));
        await tester.pump();
        await tester.pumpWidget(_wrap(build(true)));
        await tester.pump();

        expect(
          _lineCenterDy(tester, _listKey, 'Lyric line number 25'),
          closeTo(640 * 0.38, 30),
        );
      },
    );

    testWidgets(
      'deep index in a long list still centers despite row-height estimate drift',
      (tester) async {
        // 150 行且翻译开关打开但行内无翻译数据：固定行高估算(68px)与
        // 真实行高(~43px)偏差随索引线性放大，定位必须靠收敛逻辑兜底。
        final lyrics = _generateLyrics(150);
        final player = _FakePlayerController();
        player.lyrics = lyrics;
        player.activeLyricIndex = 110;

        await tester.pumpWidget(
          _wrap(
            MobileLyricList(
              key: _listKey,
              player: player,
              songHash: 'hash1',
              lyrics: lyrics,
              activeIndex: 110,
              showTranslation: true,
              showRomanization: false,
              lyricScale: 1.0,
              isPageVisible: true,
            ),
          ),
        );
        await tester.pump();

        expect(
          _lineCenterDy(tester, _listKey, 'Lyric line number 110'),
          closeTo(640 * 0.38, 30),
        );
      },
    );

    testWidgets(
      'auto-resume after user scrolls far away and stays idle 3.5s',
      (tester) async {
        final lyrics = _generateLyrics(150);
        final player = _FakePlayerController();
        player.lyrics = lyrics;
        player.activeLyricIndex = 0;

        await tester.pumpWidget(
          _wrap(
            MobileLyricList(
              key: _listKey,
              player: player,
              songHash: 'hash1',
              lyrics: lyrics,
              activeIndex: 0,
              showTranslation: false,
              showRomanization: false,
              lyricScale: 1.0,
              isPageVisible: true,
            ),
          ),
        );
        await tester.pump();

        // 远离正在播放的第 0 行
        await tester.fling(
          find.text('Lyric line number 0'),
          const Offset(0, -3000),
          4000,
        );
        await tester.pumpAndSettle();

        // 歌曲继续播放，切到下一行
        player.updatePosition(const Duration(seconds: 5), 1);
        await tester.pump();

        // 停留超过 3.5s，等待自动恢复 + 恢复动画完成
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        await tester.pump();

        expect(
          _lineCenterDy(tester, _listKey, 'Lyric line number 1'),
          closeTo(640 * 0.38, 30),
        );
      },
    );
  });
}
