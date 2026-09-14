import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/player/lyric_bottom_bar.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  bool isPlaying = true;

  int playPauseCalls = 0;

  @override
  Future<void> togglePlay() async {
    playPauseCalls++;
    isPlaying = !isPlaying;
    notifyListeners();
  }

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
  });
}
