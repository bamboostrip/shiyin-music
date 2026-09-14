import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/marquee_text.dart';

void main() {
  group('MarqueeText Widget', () {
    testWidgets(
      'When text width <= constraint maxWidth, renders static Text.rich without animation',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: MarqueeText(
                  textSpan: TextSpan(text: 'Short'),
                  pauseDuration: Duration(seconds: 1),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final marquee = find.byType(MarqueeText);
        final innerClipRect = find.descendant(
          of: marquee,
          matching: find.byType(ClipRect),
        );
        final innerTransform = find.descendant(
          of: marquee,
          matching: find.byType(Transform),
        );

        // Renders static Text without ClipRect or animated Transform
        expect(find.byType(Text), findsOneWidget);
        expect(innerClipRect, findsNothing);
        expect(innerTransform, findsNothing);

        // Advancing time should not trigger any animation or add ClipRect/Transform
        await tester.pump(const Duration(seconds: 2));
        expect(innerClipRect, findsNothing);
        expect(innerTransform, findsNothing);
      },
    );

    testWidgets(
      'When text width > constraint maxWidth, renders with clipping and scrolling behavior',
      (tester) async {
        const longText =
            'This is a very long text span that will definitely overflow the maxWidth constraint';
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 100,
                child: MarqueeText(
                  textSpan: TextSpan(text: longText),
                  velocity: 50.0,
                  pauseDuration: Duration(seconds: 2),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final marquee = find.byType(MarqueeText);
        final innerClipRect = find.descendant(
          of: marquee,
          matching: find.byType(ClipRect),
        );
        final innerTransform = find.descendant(
          of: marquee,
          matching: find.byType(Transform),
        );

        // Renders ClipRect and Transform for scrolling
        expect(innerClipRect, findsOneWidget);
        expect(innerTransform, findsOneWidget);

        // Initially (t = 0), offset is 0
        Transform transform = tester.widget<Transform>(innerTransform);
        expect(transform.transform.getTranslation().x, 0.0);

        // During initial pause (t = 1s < 2s), offset remains 0
        await tester.pump(const Duration(seconds: 1));
        transform = tester.widget<Transform>(innerTransform);
        expect(transform.transform.getTranslation().x, 0.0);

        // After pause ends, begins scrolling left (negative x translation)。
        // 暂停由 Timer 承载：跨过暂停边界的 pump 先启动滚动（首帧 elapsed 为
        // 0），需再泵一帧才能读到非零位移。
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 100));
        transform = tester.widget<Transform>(innerTransform);
        expect(transform.transform.getTranslation().x, lessThan(0.0));
      },
    );

    testWidgets('Performs ping-pong scrolling cycle with pauses at ends', (tester) async {
      const longText =
          'This is a very long text span that will definitely overflow the maxWidth constraint';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 100,
              child: MarqueeText(
                textSpan: TextSpan(text: longText),
                velocity: 100.0,
                pauseDuration: Duration(seconds: 2),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final marquee = find.byType(MarqueeText);
      final innerTransform = find.descendant(
        of: marquee,
        matching: find.byType(Transform),
      );

      // At start: offset = 0
      var transform = tester.widget<Transform>(innerTransform);
      expect(transform.transform.getTranslation().x, 0.0);

      // Still in start pause at 1s
      await tester.pump(const Duration(seconds: 1));
      transform = tester.widget<Transform>(innerTransform);
      expect(transform.transform.getTranslation().x, 0.0);

      // Advance into scroll: offset becomes negative（Timer 驱动的暂停结束后
      // 首帧 elapsed 为 0，需再泵一帧读取位移）。
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 100));
      transform = tester.widget<Transform>(innerTransform);
      final midOffset = transform.transform.getTranslation().x;
      expect(midOffset, lessThan(0.0));

      // Advance sufficiently to reach the end and enter end pause
      await tester.pump(const Duration(seconds: 15));
      transform = tester.widget<Transform>(innerTransform);
      final minOffset = transform.transform.getTranslation().x;
      expect(minOffset, lessThan(midOffset));

      // Advance back towards start
      await tester.pump(const Duration(seconds: 10));
      transform = tester.widget<Transform>(innerTransform);
      // Should have scrolled back towards 0 or completed a cycle
      expect(transform.transform.getTranslation().x, greaterThanOrEqualTo(minOffset));
    });

    testWidgets('Accepts rich InlineSpan hierarchy', (tester) async {
      const span = TextSpan(
        children: [
          TextSpan(
            text: 'Title Song',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          TextSpan(
            text: ' - Artist Name',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              child: MarqueeText(
                textSpan: span,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final textWidget = tester.widget<Text>(find.byType(Text));
      expect(textWidget.textSpan, equals(span));
    });

    testWidgets(
      'Stops animation when text changes from overflowing to fitting',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 80,
                child: MarqueeText(
                  textSpan: TextSpan(
                    text:
                        'Very long text that will overflow 80 width constraint',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final marquee = find.byType(MarqueeText);
        final innerClipRect = find.descendant(
          of: marquee,
          matching: find.byType(ClipRect),
        );

        expect(innerClipRect, findsOneWidget);

        // Update with short text
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 80,
                child: MarqueeText(
                  textSpan: TextSpan(text: 'OK'),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Should transition to static rendering
        expect(innerClipRect, findsNothing);
        expect(find.byType(Text), findsOneWidget);
      },
    );

    testWidgets('MarqueeText.text factory constructor works', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: MarqueeText.text('Simple String'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Simple String'), findsOneWidget);
    });

    testWidgets(
      '父级无关重建（新的 TextSpan 实例、文本不变）不打断滚动进度',
      (tester) async {
        Widget build() => const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 80,
              child: MarqueeText(
                // 每次调用 build() 都会 new 一个 TextSpan，模拟播放栏
                // 因音量调节等无关状态重建。
                textSpan: TextSpan(
                  text: 'Very long text that will overflow the 80px constraint',
                ),
                pauseDuration: Duration.zero,
              ),
            ),
          ),
        );
      await tester.pumpWidget(build());
      // 滚入前进段（默认 30px/s）：先推进一小段时间让零时长暂停 Timer
      // 触发并启动滚动，1.2s 后偏移约 -36px。
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 1200));

        Offset translateOffset() {
          final transform = find
              .descendant(
                of: find.byType(MarqueeText),
                matching: find.byType(Transform),
              )
              .evaluate()
              .single
              .widget as Transform;
          final t = transform.transform.getTranslation();
          return Offset(t.x, t.y);
        }

        final before = translateOffset();
        expect(before.dx, lessThan(-30), reason: '应已滚动到中途而非停在起点');

        // 无关重建：滚动应从当前位置继续，而不是 reset 到 0。
        await tester.pumpWidget(build());
        await tester.pump(const Duration(milliseconds: 16));
        final after = translateOffset();
        expect(
          after.dx,
          closeTo(before.dx - 30.0 * 0.016, 0.5),
          reason: '重建后滚动进度应连续，不得回跳到起点',
        );
      },
    );

    testWidgets(
      '无界高度父级（Column min）+ 溢出文本时布局不崩溃',
      (tester) async {
        // 复现桌面播放栏左区：Column(mainAxisSize.min) 给子项无界高度，
        // 溢出文本走 OverflowBox。旧实现 fit:max 会把 size 设成
        // Size(availableWidth, Infinity)，debug 下直接断言失败。
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 172,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarqueeText(
                        textSpan: TextSpan(
                          text: '很长的歌曲标题 - 歌手名',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final size = tester.getSize(find.byType(MarqueeText));
        expect(size.width, 172.0);
        expect(size.height.isFinite, isTrue);
        expect(size.height, greaterThan(0));
      },
    );

    testWidgets(
      'Renders static text without error when width is unbounded',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UnconstrainedBox(
                child: MarqueeText.text('Unbounded text'),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Unbounded text'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(MarqueeText),
            matching: find.byType(ClipRect),
          ),
          findsNothing,
        );
      },
    );

    testWidgets('Handles zero pause duration seamlessly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 80,
              child: MarqueeText.text(
                'Very long text that immediately scrolls with zero pause duration',
                velocity: 100.0,
                pauseDuration: Duration.zero,
              ),
            ),
          ),
        ),
      );
      // 零时长暂停 Timer 需一次时间推进才会触发并启动滚动。
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));

      final marquee = find.byType(MarqueeText);
      final innerTransform = find.descendant(
        of: marquee,
        matching: find.byType(Transform),
      );
      final transform = tester.widget<Transform>(innerTransform);
      expect(transform.transform.getTranslation().x, lessThan(0.0));
    });

    testWidgets('Disposes ticker cleanly when removed from tree', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 80,
              child: MarqueeText.text(
                'Very long text that is actively animating',
                velocity: 50.0,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      // Remove from tree
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(MarqueeText), findsNothing);
    });
  });
}
