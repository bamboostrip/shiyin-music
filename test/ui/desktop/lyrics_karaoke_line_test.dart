import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/desktop/lyrics_karaoke_line.dart';

void main() {
  group('calculateMarqueeOffset unit tests', () {
    test('returns 0.0 when textWidth <= availableWidth', () {
      expect(
        calculateMarqueeOffset(
          textWidth: 300,
          availableWidth: 500,
          progress: 0.5,
        ),
        0.0,
      );
      expect(
        calculateMarqueeOffset(
          textWidth: 500,
          availableWidth: 500,
          progress: 1.0,
        ),
        0.0,
      );
      expect(
        LyricsKaraokeLine.calculateMarqueeOffset(
          textWidth: 100,
          availableWidth: 400,
          progress: 0.0,
        ),
        0.0,
      );
    });

    test('calculates correct scroll offset when textWidth > availableWidth', () {
      // textWidth = 1000, availableWidth = 700
      // maxScroll = 1000 - 700 + 32 = 332.0
      const textWidth = 1000.0;
      const availableWidth = 700.0;
      const expectedMaxScroll = 332.0;

      expect(
        calculateMarqueeOffset(
          textWidth: textWidth,
          availableWidth: availableWidth,
          progress: 0.0,
        ),
        0.0,
      );

      expect(
        calculateMarqueeOffset(
          textWidth: textWidth,
          availableWidth: availableWidth,
          progress: 0.5,
        ),
        -expectedMaxScroll * 0.5,
      );

      expect(
        calculateMarqueeOffset(
          textWidth: textWidth,
          availableWidth: availableWidth,
          progress: 1.0,
        ),
        -expectedMaxScroll,
      );
    });

    test('clamps progress below 0.0 and above 1.0', () {
      const textWidth = 1000.0;
      const availableWidth = 700.0;
      const expectedMaxScroll = 332.0;

      expect(
        calculateMarqueeOffset(
          textWidth: textWidth,
          availableWidth: availableWidth,
          progress: -0.5,
        ),
        0.0,
      );

      expect(
        calculateMarqueeOffset(
          textWidth: textWidth,
          availableWidth: availableWidth,
          progress: 1.5,
        ),
        -expectedMaxScroll,
      );
    });
  });

  group('ProgressClipper unit tests', () {
    test('clips correctly at 0.0, 0.5, and 1.0 progress with vertical glow extension', () {
      const clipper0 = ProgressClipper(progress: 0.0, textWidth: 200.0);
      expect(clipper0.getClip(const Size(200, 40)), const Rect.fromLTWH(0, -20.0, 0.0, 80.0));
      expect(clipper0.getClip(const Size(200, 40)).width, 0.0);

      const clipperHalf = ProgressClipper(progress: 0.5, textWidth: 200.0);
      expect(clipperHalf.getClip(const Size(200, 40)), const Rect.fromLTWH(0, -20.0, 100.0, 80.0));
      expect(clipperHalf.getClip(const Size(200, 40)).width, 100.0);

      const clipperFull = ProgressClipper(progress: 1.0, textWidth: 200.0);
      expect(clipperFull.getClip(const Size(200, 40)), const Rect.fromLTWH(0, -20.0, 200.0, 80.0));
      expect(clipperFull.getClip(const Size(200, 40)).width, 200.0);
    });

    test('shouldReclip responds to changes in progress and textWidth', () {
      const clipper1 = ProgressClipper(progress: 0.3, textWidth: 100.0);
      const clipperSame = ProgressClipper(progress: 0.3, textWidth: 100.0);
      const clipperDiffProg = ProgressClipper(progress: 0.4, textWidth: 100.0);
      const clipperDiffWidth = ProgressClipper(progress: 0.3, textWidth: 120.0);

      expect(clipperSame.shouldReclip(clipper1), isFalse);
      expect(clipperDiffProg.shouldReclip(clipper1), isTrue);
      expect(clipperDiffWidth.shouldReclip(clipper1), isTrue);
    });
  });

  group('LyricsKaraokeLine widget tests', () {
    testWidgets('renders text with decoration none without yellow double underlines', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: 'Hello World',
            fontSize: 24,
            playedColor: Colors.amber,
            unplayedColor: Colors.white,
            progress: 0.0,
            availableWidth: 500,
          ),
        ),
      );

      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      // 每层 = 描边 + 填充 两个 Text，双层共 4 个
      expect(texts.length, 4);
      for (final t in texts) {
        expect(t.style?.decoration, TextDecoration.none);
      }
    });

    testWidgets('renders both unplayed base layer and played highlight layer', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: '双层歌词测试',
            fontSize: 28,
            playedColor: Color(0xFF00FFCC),
            unplayedColor: Color(0xFFFFFFFF),
            progress: 0.4,
            availableWidth: 600,
          ),
        ),
      );

      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      // 每层 = 描边 + 填充 两个 Text：[未播放描边, 未播放填充, 已播放描边, 已播放填充]
      expect(texts.length, 4);

      final baseStroke = texts[0];
      final baseFill = texts[1];
      final highlightStroke = texts[2];
      final highlightFill = texts[3];

      // Base unplayed text
      expect(baseFill.data, '双层歌词测试');
      expect(baseFill.style?.color, const Color(0xFFFFFFFF));
      // 描边层：stroke 绘制 + 同色系深色 + 附带 1 层轻投影
      expect(baseStroke.style?.foreground?.style, PaintingStyle.stroke);
      expect(baseStroke.style?.foreground?.strokeWidth, closeTo(28 * 0.075, 0.01));
      expect((baseStroke.style!.foreground!.color.a * 255).round(), 255);
      expect(baseStroke.style?.shadows, isNotNull);
      expect(baseStroke.style!.shadows!.length, 1);

      // Highlight played text
      expect(highlightFill.data, '双层歌词测试');
      expect(highlightFill.style?.color, const Color(0xFF00FFCC));
      expect(highlightStroke.style?.foreground?.style, PaintingStyle.stroke);
      expect(highlightFill.style?.shadows, isNull);

      // ClipRect wraps highlight text with ProgressClipper
      final clipFinder = find.descendant(
        of: find.byType(Stack),
        matching: find.byType(ClipRect),
      );
      expect(clipFinder, findsOneWidget);
      final clipRect = tester.widget<ClipRect>(clipFinder);
      expect(clipRect.clipper, isA<ProgressClipper>());
    });

    testWidgets('at progress 0.0 highlight layer width is 0', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: 'Progress Zero Test',
            fontSize: 24,
            playedColor: Colors.green,
            unplayedColor: Colors.white,
            progress: 0.0,
            availableWidth: 500,
          ),
        ),
      );

      final clipFinder = find.descendant(
        of: find.byType(Stack),
        matching: find.byType(ClipRect),
      );
      final clipRect = tester.widget<ClipRect>(clipFinder);
      final clipper = clipRect.clipper as ProgressClipper;
      expect(clipper.getClip(const Size(300, 30)).width, 0.0);
    });

    testWidgets('at progress 1.0 highlight layer width is 100% of textWidth', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: 'Progress One Test',
            fontSize: 24,
            playedColor: Colors.green,
            unplayedColor: Colors.white,
            progress: 1.0,
            availableWidth: 500,
          ),
        ),
      );

      final clipFinder = find.descendant(
        of: find.byType(Stack),
        matching: find.byType(ClipRect),
      );
      final clipRect = tester.widget<ClipRect>(clipFinder);
      final clipper = clipRect.clipper as ProgressClipper;
      expect(clipper.getClip(const Size(300, 30)).width, clipper.textWidth);
      expect(clipper.textWidth, greaterThan(0.0));
    });

    testWidgets('aligns text according to alignment when not overflow', (tester) async {
      for (final align in [TextAlign.center, TextAlign.left, TextAlign.right]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: LyricsKaraokeLine(
              text: 'Short',
              fontSize: 20,
              playedColor: Colors.amber,
              unplayedColor: Colors.white,
              progress: 0.5,
              availableWidth: 600,
              alignment: align,
            ),
          ),
        );

        final alignFinder = find.byType(Align);
        expect(alignFinder, findsOneWidget);
        final alignWidget = tester.widget<Align>(alignFinder);

        if (align == TextAlign.left) {
          expect(alignWidget.alignment, Alignment.centerLeft);
        } else if (align == TextAlign.right) {
          expect(alignWidget.alignment, Alignment.centerRight);
        } else {
          expect(alignWidget.alignment, Alignment.center);
        }
      }
    });

    testWidgets('smooth marquee translate when textWidth > availableWidth', (tester) async {
      const longText = '这是一段非常非常非常非常非常长的桌面歌词，肯定会超出容器的可用宽度';
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: longText,
            fontSize: 28,
            playedColor: Colors.amber,
            unplayedColor: Colors.white,
            progress: 0.5,
            availableWidth: 200, // Small available width to force overflow
          ),
        ),
      );

      final transformFinder = find.byType(Transform);
      expect(transformFinder, findsOneWidget);
      final transform = tester.widget<Transform>(transformFinder);
      final matrix = transform.transform;
      final translationX = matrix.getTranslation().x;
      // Scroll offset should be negative
      expect(translationX, lessThan(0.0));
    });

    testWidgets('handles empty string gracefully', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: '',
            fontSize: 24,
            playedColor: Colors.amber,
            unplayedColor: Colors.white,
            progress: 0.5,
            availableWidth: 400,
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final texts = tester.widgetList<Text>(find.byType(Text));
      // 每层 = 描边 + 填充 两个 Text，双层共 4 个
      expect(texts.length, 4);
    });

    testWidgets('handles very long strings without crashing', (tester) async {
      final veryLongText = '超长歌词' * 100;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: veryLongText,
            fontSize: 32,
            playedColor: Colors.amber,
            unplayedColor: Colors.white,
            progress: 0.8,
            availableWidth: 300,
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('applies textOpacity to colors and shadows', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: 'Opacity Test',
            fontSize: 24,
            playedColor: Color(0xFFFFCC00),
            unplayedColor: Color(0xFFFFFFFF),
            progress: 0.5,
            availableWidth: 500,
            textOpacity: 0.5,
          ),
        ),
      );

      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      final baseStroke = texts[0];
      final baseFill = texts[1];
      final highlightFill = texts[3];

      // Base unplayed text opacity（textOpacity 与颜色 alpha 相乘）
      expect(baseFill.style?.color?.a, closeTo(0.5, 0.01));
      // Highlight played text opacity
      expect(highlightFill.style?.color?.a, closeTo(0.5, 0.01));
      // 描边层 alpha 同样跟随 textOpacity
      expect(baseStroke.style?.foreground?.color.a, closeTo(0.5, 0.01));
      // 投影浓度随 textOpacity 缩放
      final shadow = baseStroke.style!.shadows!.single;
      expect(shadow.color.a, closeTo(0.30 * 0.5, 0.01));
    });

    testWidgets('updates smoothly when progress changes and re-measures on text/fontSize changes', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: 'Karaoke Text',
            fontSize: 24,
            playedColor: Colors.blue,
            unplayedColor: Colors.white,
            progress: 0.2,
            availableWidth: 500,
          ),
        ),
      );

      var clipFinder = find.descendant(
        of: find.byType(Stack),
        matching: find.byType(ClipRect),
      );
      var clipRect = tester.widget<ClipRect>(clipFinder);
      var clipper = clipRect.clipper as ProgressClipper;
      final initialWidth = clipper.textWidth;
      expect(clipper.progress, 0.2);

      // Update progress only
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: 'Karaoke Text',
            fontSize: 24,
            playedColor: Colors.blue,
            unplayedColor: Colors.white,
            progress: 0.8,
            availableWidth: 500,
          ),
        ),
      );

      clipFinder = find.descendant(
        of: find.byType(Stack),
        matching: find.byType(ClipRect),
      );
      clipRect = tester.widget<ClipRect>(clipFinder);
      clipper = clipRect.clipper as ProgressClipper;
      expect(clipper.progress, 0.8);
      // Measured textWidth remains unchanged
      expect(clipper.textWidth, initialWidth);

      // Update fontSize to trigger re-measurement in didUpdateWidget
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LyricsKaraokeLine(
            text: 'Karaoke Text',
            fontSize: 48,
            playedColor: Colors.blue,
            unplayedColor: Colors.white,
            progress: 0.8,
            availableWidth: 500,
          ),
        ),
      );

      clipFinder = find.descendant(
        of: find.byType(Stack),
        matching: find.byType(ClipRect),
      );
      clipRect = tester.widget<ClipRect>(clipFinder);
      clipper = clipRect.clipper as ProgressClipper;
      // textWidth should now be approximately double
      expect(clipper.textWidth, greaterThan(initialWidth * 1.5));
    });
  });
}
