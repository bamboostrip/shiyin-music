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

  testWidgets('手动滚动时模糊降到可读的低值，回弹/点播后恢复', (tester) async {
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

    // 手动向上滚动：模糊应降到很低的保留值，而不是全模糊或完全消失。
    await tester.drag(find.byType(AppleLyricsView), const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 400));

    final browsingFade = state.blurFadeForTest as double;
    expect(
      browsingFade,
      lessThan(0.3),
      reason: '滚动浏览时不能保持全模糊，否则歌词看不清',
    );
    expect(
      browsingFade,
      greaterThan(0.05),
      reason: '也不能完全消失，否则又会突兀',
    );

    // 松手后等待回弹期间保持低模糊（用户正在阅读）。
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.blurFadeForTest, closeTo(browsingFade, 0.02));

    // 点歌词跳播会调用 resumeFollowNow：退出浏览态，模糊快速恢复。
    state.scrollControllerForTest.resumeFollowNow();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      state.blurFadeForTest,
      greaterThan(0.9),
      reason: '跳播后应立即恢复跟随与模糊',
    );

    // 卸载，收掉 ticker/timer。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
