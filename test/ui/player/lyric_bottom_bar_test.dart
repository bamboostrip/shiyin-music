import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/player/lyric_bottom_bar.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

  @override
  bool isPlaying = true;

  int playPauseCalls = 0;

  @override
  Future<void> togglePlay() async {
    playPauseCalls++;
    isPlaying = !isPlaying;
    notifyListeners();
  }

  int previousCalls = 0;
  int nextCalls = 0;

  @override
  Future<void> previous() async => previousCalls++;

  @override
  Future<void> next() async => nextCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('LyricTogglePill', () {
    testWidgets('renders on state and responds to tap', (tester) async {
      bool? toggled;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricTogglePill(
              label: '译',
              isOn: true,
              onToggle: () => toggled = true,
            ),
          ),
        ),
      );

      expect(find.text('译'), findsOneWidget);
      expect(find.text('on'), findsOneWidget);

      await tester.tap(find.byType(LyricTogglePill));
      expect(toggled, isTrue);
    });

    testWidgets('renders off state correctly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricTogglePill(label: '音', isOn: false, onToggle: () {}),
          ),
        ),
      );

      expect(find.text('音'), findsOneWidget);
      expect(find.text('off'), findsOneWidget);
    });
  });

  group('LyricBottomBar', () {
    testWidgets('renders comment, font, pills and play button', (tester) async {
      const song = Song(id: 's1', hash: 'h1', title: 'Song', artist: 'Artist');
      final player = _FakePlayerController();
      bool translationState = false;
      bool romanizationState = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricBottomBar(
              player: player,
              song: song,
              showTranslation: translationState,
              showRomanization: romanizationState,
              hasTranslation: true,
              hasRomanization: true,
              lyricScale: 1.0,
              onToggleTranslation: (val) => translationState = val,
              onToggleRomanization: (val) => romanizationState = val,
              onLyricScaleChanged: (scale) {},
            ),
          ),
        ),
      );

      // 验证 [词]
      expect(find.text('词'), findsOneWidget);
      // 验证 [译 off]
      expect(find.text('译'), findsOneWidget);
      // 验证 [音 off]
      expect(find.text('音'), findsOneWidget);

      // 点击 [译]
      await tester.tap(find.text('译'));
      expect(translationState, isTrue);

      // 点击播放/暂停
      final playBtn = find.byKey(
        const ValueKey('lyric_round_play_pause_button'),
      );
      expect(playBtn, findsOneWidget);
      await tester.tap(playBtn);
      expect(player.playPauseCalls, 1);
    });

    testWidgets('hides translation pill when hasTranslation is false', (
      tester,
    ) async {
      const song = Song(id: 's1', hash: 'h1', title: 'Song', artist: 'Artist');
      final player = _FakePlayerController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricBottomBar(
              player: player,
              song: song,
              showTranslation: false,
              showRomanization: false,
              hasTranslation: false,
              hasRomanization: false,
              lyricScale: 1.0,
              onToggleTranslation: (_) {},
              onToggleRomanization: (_) {},
              onLyricScaleChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('词'), findsOneWidget);
      expect(find.text('译'), findsNothing);
      expect(find.text('音'), findsNothing);
    });

    testWidgets('renders skip buttons and triggers previous/next', (
      tester,
    ) async {
      const song = Song(id: 's1', hash: 'h1', title: 'Song', artist: 'Artist');
      final player = _FakePlayerController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricBottomBar(
              player: player,
              song: song,
              showTranslation: false,
              showRomanization: false,
              hasTranslation: false,
              hasRomanization: false,
              lyricScale: 1.0,
              showSkipButtons: true,
              onToggleTranslation: (_) {},
              onToggleRomanization: (_) {},
              onLyricScaleChanged: (_) {},
            ),
          ),
        ),
      );

      final prevBtn = find.byKey(const ValueKey('lyric_previous_button'));
      final nextBtn = find.byKey(const ValueKey('lyric_next_button'));
      expect(prevBtn, findsOneWidget);
      expect(nextBtn, findsOneWidget);

      await tester.tap(prevBtn);
      await tester.tap(nextBtn);
      expect(player.previousCalls, 1);
      expect(player.nextCalls, 1);
    });

    testWidgets('hides skip buttons by default (QQ 原版底栏)', (tester) async {
      const song = Song(id: 's1', hash: 'h1', title: 'Song', artist: 'Artist');
      final player = _FakePlayerController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricBottomBar(
              player: player,
              song: song,
              showTranslation: true,
              showRomanization: true,
              hasTranslation: true,
              hasRomanization: true,
              lyricScale: 1.0,
              onToggleTranslation: (_) {},
              onToggleRomanization: (_) {},
              onLyricScaleChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('lyric_previous_button')), findsNothing);
      expect(find.byKey(const ValueKey('lyric_next_button')), findsNothing);
      // 原版药丸/播放键仍在
      expect(
        find.byKey(const ValueKey('lyric_round_play_pause_button')),
        findsOneWidget,
      );
      expect(find.text('词'), findsOneWidget);
    });

    // 最坏情况（开启切歌键 + 译/音双 pill）逐宽度扫描：从 320dp 主流窄屏
    // 一直覆盖到分屏/折叠屏/超大显示尺寸级别的极窄宽度，都不允许出现
    // RenderFlex overflow（修复前 <314dp 开始溢出、313dp 溢出 1px）。
    // 正常宽度还必须保持设计档位尺寸，不能被兜底缩放误伤。
    for (final width in <double>[
      280,
      300,
      313,
      314,
      320,
      340,
      360,
      379,
      380,
      412,
    ]) {
      testWidgets('no overflow at width=$width with both pills and skip on', (
        tester,
      ) async {
        const song = Song(
          id: 's1',
          hash: 'h1',
          title: 'Song',
          artist: 'Artist',
        );
        final player = _FakePlayerController();

        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LyricBottomBar(
                player: player,
                song: song,
                showTranslation: true,
                showRomanization: true,
                hasTranslation: true,
                hasRomanization: true,
                lyricScale: 1.0,
                showSkipButtons: true,
                onToggleTranslation: (_) {},
                onToggleRomanization: (_) {},
                onLyricScaleChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 渲染期若 Row 溢出，Flutter 会抛 RenderFlex overflow，用例直接失败。
        expect(
          tester.takeException(),
          isNull,
          reason: 'width=$width 开启切歌键后底栏不允许溢出',
        );

        final prevFinder = find.byKey(const ValueKey('lyric_previous_button'));
        final nextFinder = find.byKey(const ValueKey('lyric_next_button'));
        expect(prevFinder, findsOneWidget);
        expect(nextFinder, findsOneWidget);

        // 正常宽度（≥314dp）走设计档位，不触发兜底缩放：
        //   ≥380 → 40，340~379 → 36，<340 → 32。
        final expectedSize = width >= 380 ? 40.0 : (width >= 340 ? 36.0 : 32.0);
        final prevSize = tester.getSize(prevFinder);
        if (width >= 314) {
          expect(prevSize.width, expectedSize, reason: 'width=$width 档位尺寸');
          expect(prevSize.height, expectedSize);
        } else {
          // 极窄宽度：整组等比缩小而不是裁切。
          expect(prevSize.width, greaterThan(0));
          expect(prevSize.width, lessThanOrEqualTo(expectedSize));
        }

        // 「下一首」必须完整落在屏幕内（溢出时会被裁出右边缘）。
        expect(tester.getRect(nextFinder).right, lessThanOrEqualTo(width));
        expect(tester.getRect(prevFinder).left, greaterThanOrEqualTo(0));
      });
    }

    testWidgets('showSkipButtons=false 完整保留原版底栏间距契约', (tester) async {
      const song = Song(id: 's1', hash: 'h1', title: 'Song', artist: 'Artist');
      final player = _FakePlayerController();

      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricBottomBar(
              player: player,
              song: song,
              showTranslation: true,
              showRomanization: true,
              hasTranslation: true,
              hasRomanization: true,
              lyricScale: 1.0,
              onToggleTranslation: (_) {},
              onToggleRomanization: (_) {},
              onLyricScaleChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 关闭切歌键时必须与原版一致：水平 padding 16、药丸间距 14。
      final paddingFinder = find.descendant(
        of: find.byType(LyricBottomBar),
        matching: find.byWidgetPredicate((w) => w is Padding && w.child is Row),
      );
      expect(paddingFinder, findsOneWidget);
      expect(
        tester.widget<Padding>(paddingFinder).padding,
        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      );

      Rect pillRect(String label) => tester.getRect(
        find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      final word = pillRect('词');
      final trans = pillRect('译');
      final roman = pillRect('音');
      final play = tester.getRect(
        find.byKey(const ValueKey('lyric_round_play_pause_button')),
      );
      expect(trans.left - word.right, 14.0);
      expect(roman.left - trans.right, 14.0);
      expect(play.left - roman.right, 14.0);
      expect(find.byKey(const ValueKey('lyric_previous_button')), findsNothing);
      expect(find.byKey(const ValueKey('lyric_next_button')), findsNothing);
    });
  });
}