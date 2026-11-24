// 歌词行动效包装（issue #26）：标准样式零额外图层；灵动样式只给
// 当前行做弹性缩放、给邻近行做限量模糊（超出 maxBlurDistance 不再开图层）。
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
          active: true,
          distance: 0,
          child: Text('标准样式'),
        ),
      ),
    );

    expect(_inside(tester, Transform), findsNothing);
    expect(_inside(tester, ImageFiltered), findsNothing);
    expect(find.text('标准样式'), findsOneWidget);
  });

  testWidgets('灵动样式：当前行弹性放大且保持清晰', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const LyricLineMotion(
          style: LyricMotionStyle.lively,
          active: true,
          distance: 0,
          child: Text('当前行'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final transform = tester.widget<Transform>(_inside(tester, Transform));
    expect(
      transform.transform.getMaxScaleOnAxis(),
      closeTo(1 + LyricLineMotion.activeScaleDelta, 0.001),
    );
    expect(_inside(tester, ImageFiltered), findsNothing, reason: '当前行必须清晰');
  });

  testWidgets('灵动样式：邻近的非当前行加轻微模糊，不做缩放', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const LyricLineMotion(
          style: LyricMotionStyle.lively,
          active: false,
          distance: 1,
          child: Text('邻近行'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_inside(tester, ImageFiltered), findsOneWidget);
    expect(_inside(tester, Transform), findsNothing);
    expect(
      LyricLineMotion.blurSigmaFor(LyricMotionStyle.lively, 1),
      greaterThan(0),
    );
  });

  testWidgets('灵动样式：超出模糊距离的行不再开图层（低端机保护）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const LyricLineMotion(
          style: LyricMotionStyle.lively,
          active: false,
          distance: LyricLineMotion.maxBlurDistance + 1,
          child: Text('远处的行'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_inside(tester, ImageFiltered), findsNothing);
    expect(_inside(tester, Transform), findsNothing);
  });

  group('上游景深样式', () {
    test('模糊强度按上游参数逐行递增并封顶 3.0', () {
      expect(LyricLineMotion.blurSigmaFor(LyricMotionStyle.upstream, 0), 0);
      expect(
        LyricLineMotion.blurSigmaFor(LyricMotionStyle.upstream, 1),
        closeTo(0.7, 0.0001),
      );
      expect(
        LyricLineMotion.blurSigmaFor(LyricMotionStyle.upstream, 4),
        closeTo(2.8, 0.0001),
      );
      expect(
        LyricLineMotion.blurSigmaFor(LyricMotionStyle.upstream, 5),
        closeTo(3.0, 0.0001),
      );
      expect(
        LyricLineMotion.blurSigmaFor(LyricMotionStyle.upstream, 20),
        closeTo(3.0, 0.0001),
        reason: '上游只封顶 sigma，不按行数截断',
      );
    });

    testWidgets('当前行不做弹性放大，远处行仍模糊（不做 ±3 截断）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const LyricLineMotion(
            style: LyricMotionStyle.upstream,
            active: true,
            distance: 0,
            child: Text('上游当前行'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_inside(tester, Transform), findsNothing, reason: '上游没有弹性缩放');
      expect(_inside(tester, ImageFiltered), findsNothing, reason: '当前行必须清晰');

      await tester.pumpWidget(
        _wrap(
          const LyricLineMotion(
            style: LyricMotionStyle.upstream,
            active: false,
            distance: 5,
            child: Text('远处行'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _inside(tester, ImageFiltered),
        findsOneWidget,
        reason: '上游景深对 ±3 行之外的行仍保留模糊',
      );
      expect(_inside(tester, Transform), findsNothing);
    });
  });

  testWidgets('灵动样式：当前行失活后收回缩放并渐出模糊', (tester) async {
    Widget build({required bool active}) => _wrap(
      LyricLineMotion(
        style: LyricMotionStyle.lively,
        active: active,
        distance: active ? 0 : 1,
        child: const Text('换行'),
      ),
    );

    await tester.pumpWidget(build(active: true));
    await tester.pumpAndSettle();
    expect(_inside(tester, Transform), findsOneWidget);

    await tester.pumpWidget(build(active: false));
    await tester.pumpAndSettle();

    expect(_inside(tester, Transform), findsNothing, reason: '失活后缩放必须回到 1');
    expect(_inside(tester, ImageFiltered), findsOneWidget, reason: '失活后按行距模糊');
  });

  testWidgets('灵动样式：当前行激活过程中在放大（动画在跑，不是瞬间到位）', (tester) async {
    Widget build({required bool active}) => _wrap(
      LyricLineMotion(
        style: LyricMotionStyle.lively,
        active: active,
        distance: 0,
        child: const Text('弹性放大'),
      ),
    );

    await tester.pumpWidget(build(active: false));
    await tester.pumpAndSettle();

    await tester.pumpWidget(build(active: true));
    // 420ms 的 easeOutBack：300ms 处应已越过终点（过冲 = 回弹）。
    await tester.pump(const Duration(milliseconds: 300));
    final midScale = tester
        .widget<Transform>(_inside(tester, Transform))
        .transform
        .getMaxScaleOnAxis();
    expect(
      midScale,
      greaterThan(1 + LyricLineMotion.activeScaleDelta + 0.001),
      reason: 'easeOutBack 的过冲必须真实发生，否则只是普通线性放大',
    );

    await tester.pumpAndSettle();
    final settledScale = tester
        .widget<Transform>(_inside(tester, Transform))
        .transform
        .getMaxScaleOnAxis();
    expect(
      settledScale,
      closeTo(1 + LyricLineMotion.activeScaleDelta, 0.001),
    );
  });

  testWidgets('灵动样式：模糊跨越距离上限时渐变收尾，不会瞬间变清晰', (tester) async {
    Widget build(int distance) => _wrap(
      LyricLineMotion(
        style: LyricMotionStyle.lively,
        active: false,
        distance: distance,
        child: const Text('边界行'),
      ),
    );

    await tester.pumpWidget(build(LyricLineMotion.maxBlurDistance));
    await tester.pumpAndSettle();
    expect(_inside(tester, ImageFiltered), findsOneWidget);

    await tester.pumpWidget(build(LyricLineMotion.maxBlurDistance + 1));
    // 目标 sigma 变 0 的第一帧仍在过渡中：图层还应存在，而不是当场消失。
    expect(
      _inside(tester, ImageFiltered),
      findsOneWidget,
      reason: '跨过上限应渐变，不能瞬间跳变',
    );

    await tester.pumpAndSettle();
    expect(_inside(tester, ImageFiltered), findsNothing);
  });
}
