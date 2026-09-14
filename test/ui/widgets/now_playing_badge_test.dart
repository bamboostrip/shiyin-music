import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/now_playing_badge.dart';

void main() {
  group('NowPlayingBadge Widget Tests', () {
    testWidgets('renders with 3 bars by default', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NowPlayingBadge(
              active: true,
              playing: true,
              color: Colors.white,
            ),
          ),
        ),
      );

      final badge = tester.widget<NowPlayingBadge>(find.byType(NowPlayingBadge));
      expect(badge.barCount, 3);
      final customPaintFinder = find.descendant(
        of: find.byType(NowPlayingBadge),
        matching: find.byType(CustomPaint),
      );
      expect(customPaintFinder, findsOneWidget);
      final painter =
          tester.widget<CustomPaint>(customPaintFinder).painter as NowPlayingPainter;
      expect(painter.barCount, 3);
    });

    testWidgets('renders with 4 bars when specified', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NowPlayingBadge(
              active: true,
              playing: true,
              color: Colors.white,
              barCount: 4,
            ),
          ),
        ),
      );

      final badge = tester.widget<NowPlayingBadge>(find.byType(NowPlayingBadge));
      expect(badge.barCount, 4);
      final customPaintFinder = find.descendant(
        of: find.byType(NowPlayingBadge),
        matching: find.byType(CustomPaint),
      );
      expect(customPaintFinder, findsOneWidget);
      final painter =
          tester.widget<CustomPaint>(customPaintFinder).painter as NowPlayingPainter;
      expect(painter.barCount, 4);
    });

    testWidgets('renders empty SizedBox when active is false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NowPlayingBadge(
              active: false,
              playing: true,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(NowPlayingBadge),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
      final box = tester.getSize(find.byType(NowPlayingBadge));
      expect(box, const Size(24, 24));
    });

    testWidgets('animation starts when playing=true and pauses when playing=false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NowPlayingBadge(
              active: true,
              playing: true,
              color: Colors.white,
              barCount: 4,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      // Switch to playing: false
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NowPlayingBadge(
              active: true,
              playing: false,
              color: Colors.white,
              barCount: 4,
            ),
          ),
        ),
      );
      await tester.pump();
      final customPaintFinder = find.descendant(
        of: find.byType(NowPlayingBadge),
        matching: find.byType(CustomPaint),
      );
      final painter =
          tester.widget<CustomPaint>(customPaintFinder).painter as NowPlayingPainter;
      expect(painter.progress, 0.42);

      // Switch back to playing: true
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NowPlayingBadge(
              active: true,
              playing: true,
              color: Colors.white,
              barCount: 4,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(NowPlayingBadge), findsOneWidget);
    });

    testWidgets('paints 4 bars correctly on canvas', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: NowPlayingBadge(
                active: true,
                playing: true,
                color: Colors.white,
                size: 20,
                barCount: 4,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final customPaintFinder = find.descendant(
        of: find.byType(NowPlayingBadge),
        matching: find.byType(CustomPaint),
      );
      expect(customPaintFinder, findsOneWidget);
      final customPaint = tester.widget<CustomPaint>(customPaintFinder);
      expect(customPaint.painter, isNotNull);

      // Verify painting executes without error on a recording canvas
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      customPaint.painter!.paint(canvas, const Size(20, 20));
      final picture = recorder.endRecording();
      picture.dispose();
    });
  });

  group('NowPlayingPainter Unit Tests', () {
    test('shouldRepaint returns true when properties change and false when identical', () {
      const painter = NowPlayingPainter(
        progress: 0.5,
        color: Colors.white,
        barCount: 3,
      );

      expect(
        painter.shouldRepaint(
          const NowPlayingPainter(progress: 0.5, color: Colors.white, barCount: 3),
        ),
        isFalse,
      );

      expect(
        painter.shouldRepaint(
          const NowPlayingPainter(progress: 0.6, color: Colors.white, barCount: 3),
        ),
        isTrue,
      );

      expect(
        painter.shouldRepaint(
          const NowPlayingPainter(progress: 0.5, color: Colors.red, barCount: 3),
        ),
        isTrue,
      );

      expect(
        painter.shouldRepaint(
          const NowPlayingPainter(progress: 0.5, color: Colors.white, barCount: 4),
        ),
        isTrue,
      );
    });

    test('paints both 3-bar and 4-bar configurations cleanly', () {
      for (final count in [3, 4]) {
        final painter = NowPlayingPainter(
          progress: 0.7,
          color: Colors.blue,
          barCount: count,
        );

        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        painter.paint(canvas, const Size(32, 32));
        final picture = recorder.endRecording();
        picture.dispose();
      }
    });
  });
}
