// 行级歌词包装：标准/灵动直接透传（灵动由整页 Apple 组件接管），
// 只有景深样式按行距加高斯模糊，且不做 ±3 行截断。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/player/lyric_line_motion.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

Finder _inside(WidgetTester tester, Type type) => find.descendant(
  of: find.byType(LyricLineMotion),
  matching: find.byType(type),
);

void main() {
  testWidgets('标准样式直接返回 child，不额外建图层', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const LyricLineMotion(
          style: LyricMotionStyle.standard,
          distance: 0,
          child: Text('标准样式'),
        ),
      ),
    );

    expect(_inside(tester, Transform), findsNothing);
    expect(_inside(tester, ImageFiltered), findsNothing);
    expect(find.text('标准样式'), findsOneWidget);
  });

  testWidgets('灵动样式不走行级图层（由整页 Apple 歌词组件接管）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const LyricLineMotion(
          style: LyricMotionStyle.lively,
          distance: 2,
          child: Text('灵动样式'),
        ),
      ),
    );

    expect(_inside(tester, ImageFiltered), findsNothing);
    expect(_inside(tester, Transform), findsNothing);
  });

  testWidgets('景深样式：当前行清晰，邻近行加模糊且不做缩放', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const LyricLineMotion(
          style: LyricMotionStyle.depth,
          distance: 0,
          child: Text('当前行'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_inside(tester, ImageFiltered), findsNothing, reason: '当前行必须清晰');

    await tester.pumpWidget(
      _wrap(
        const LyricLineMotion(
          style: LyricMotionStyle.depth,
          distance: 1,
          child: Text('邻近行'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_inside(tester, ImageFiltered), findsOneWidget);
    expect(_inside(tester, Transform), findsNothing, reason: '景深没有弹性放大');
  });

  testWidgets('景深样式：超出 3 行仍然模糊（只封顶 sigma，不截断行数）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const LyricLineMotion(
          style: LyricMotionStyle.depth,
          distance: 20,
          child: Text('远处的行'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_inside(tester, ImageFiltered), findsOneWidget);
    expect(_inside(tester, Transform), findsNothing);
  });

  test('景深模糊强度按行距递增并封顶 3.0', () {
    expect(LyricLineMotion.blurSigmaFor(0), 0);
    expect(LyricLineMotion.blurSigmaFor(1), closeTo(0.7, 0.0001));
    expect(LyricLineMotion.blurSigmaFor(4), closeTo(2.8, 0.0001));
    expect(LyricLineMotion.blurSigmaFor(5), closeTo(3.0, 0.0001));
    expect(
      LyricLineMotion.blurSigmaFor(20),
      closeTo(3.0, 0.0001),
      reason: '只封顶 sigma，不按行数截断',
    );
  });
}
