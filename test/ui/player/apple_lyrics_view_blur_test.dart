import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:shiyin_music/widgets/apple_lyrics/models/lyric_line.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('手动滚动期间模糊保持可见，不再整片淡出', (tester) async {
    final lines = List<LyricLine>.generate(
      30,
      (i) => LyricLine(
        startTime: i * 5000,
        duration: 5000,
        text: '第 $i 行歌词',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 600,
            child: AppleLyricsView(
              lines: lines,
              currentTimeMs: 60000,
              isPlaying: true,
              forceDarkBackground: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final dynamic state = tester.state(find.byType(AppleLyricsView));
    expect(state.blurFadeForTest, 1.0);

    // 手动向上滚动：旧实现会把 _blurFade 淡到 0，这里应始终为 1。
    await tester.drag(find.byType(AppleLyricsView), const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      state.blurFadeForTest,
      closeTo(1.0, 0.001),
      reason: '拖动期间模糊不能消失',
    );

    // 松手后处于等待回弹态，模糊同样要保持可见。
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      state.blurFadeForTest,
      closeTo(1.0, 0.001),
      reason: '等待回弹期间模糊不能消失',
    );

    // 卸载，收掉 ticker/timer。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
