import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/player_page.dart';
import 'package:shiyin_music/ui/player/player_route.dart';

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? get currentSong => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushedRoutes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    pushedRoutes.add(route);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    debugDesktopFormFactorOverride = null;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  group('PlayerPageRoute', () {
    test('has expected non-opaque route properties', () {
      final route = PlayerPageRoute<void>(
        builder: (context) => const SizedBox(),
      );

      expect(route.opaque, isFalse);
      expect(route.barrierColor, Colors.black45);
      expect(route.barrierDismissible, isFalse);
      expect(route.transitionDuration, const Duration(milliseconds: 300));
      expect(
        route.reverseTransitionDuration,
        const Duration(milliseconds: 250),
      );
    });

    testWidgets(
      'slides up from bottom and keeps background route rendered',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                return Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          PlayerPageRoute<void>(
                            builder: (_) => const Scaffold(
                              backgroundColor: Colors.transparent,
                              body: Center(child: Text('Player Content')),
                            ),
                          ),
                        );
                      },
                      child: const Text('Background Page'),
                    ),
                  ),
                );
              },
            ),
          ),
        );

        expect(find.text('Background Page'), findsOneWidget);
        expect(find.text('Player Content'), findsNothing);

        // 点击按钮触发入场
        await tester.tap(find.text('Background Page'));
        await tester.pump();

        // 动画进行到一半（150ms / 300ms）
        await tester.pump(const Duration(milliseconds: 150));

        final slideFinder = find.ancestor(
          of: find.text('Player Content'),
          matching: find.byType(SlideTransition),
        );
        expect(slideFinder, findsOneWidget);

        final slideWidget = tester.widget<SlideTransition>(slideFinder);
        expect(slideWidget.position.value.dy, greaterThan(0.0));
        expect(slideWidget.position.value.dy, lessThan(1.0));

        // 动画完全结束
        await tester.pumpAndSettle();

        expect(find.text('Player Content'), findsOneWidget);
        // 底层页面未被销毁或 offstage，依然在树中且已挂载
        expect(find.text('Background Page'), findsOneWidget);
        final bgElement = tester.element(find.text('Background Page'));
        expect(bgElement.renderObject?.attached, isTrue);

        // 最终完全到达目标位置 Offset.zero
        final finishedSlide = tester.widget<SlideTransition>(slideFinder);
        expect(finishedSlide.position.value, Offset.zero);

        // 退出路由退场
        final nav = tester.state<NavigatorState>(find.byType(Navigator));
        nav.pop();
        await tester.pump();

        // 退场动画进行中（125ms / 250ms）
        await tester.pump(const Duration(milliseconds: 125));
        final reverseSlide = tester.widget<SlideTransition>(slideFinder);
        expect(reverseSlide.position.value.dy, greaterThan(0.0));

        // 退场完全结束
        await tester.pumpAndSettle();
        expect(find.text('Player Content'), findsNothing);
        expect(find.text('Background Page'), findsOneWidget);
      },
    );

    group('PlayerPageRoute.open', () {
      testWidgets('pushes PlayerPageRoute on mobile form factor', (
        tester,
      ) async {
        debugDesktopFormFactorOverride = false;
        final observer = _TestNavigatorObserver();
        final player = _FakePlayerController();
        final auth = _FakeAuthController();

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: Builder(
              builder: (context) {
                return Scaffold(
                  body: ElevatedButton(
                    onPressed: () {
                      PlayerPageRoute.open<void>(
                        context,
                        player: player,
                        auth: auth,
                      );
                    },
                    child: const Text('Open Player'),
                  ),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('Open Player'));
        await tester.pump();

        expect(observer.pushedRoutes.last, isA<PlayerPageRoute<void>>());
        expect((observer.pushedRoutes.last as ModalRoute).opaque, isFalse);

        await tester.pumpAndSettle();
        expect(find.byType(PlayerPage), findsOneWidget);
      });

      testWidgets('pushes MaterialPageRoute on desktop form factor', (
        tester,
      ) async {
        debugDesktopFormFactorOverride = true;
        final observer = _TestNavigatorObserver();
        final player = _FakePlayerController();
        final auth = _FakeAuthController();

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: Builder(
              builder: (context) {
                return Scaffold(
                  body: ElevatedButton(
                    onPressed: () {
                      PlayerPageRoute.open<void>(
                        context,
                        player: player,
                        auth: auth,
                      );
                    },
                    child: const Text('Open Player'),
                  ),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('Open Player'));
        await tester.pump();

        expect(observer.pushedRoutes.last, isA<MaterialPageRoute<void>>());
        expect(observer.pushedRoutes.last, isNot(isA<PlayerPageRoute<void>>()));

        await tester.pumpAndSettle();
        expect(find.byType(PlayerPage), findsOneWidget);
      });

      testWidgets(
        'pushes MaterialPageRoute on landscape when carMode is enabled',
        (tester) async {
          debugDesktopFormFactorOverride = false;
          await ThemeController.instance.setCarModeEnabled(true);
          final observer = _TestNavigatorObserver();
          final player = _FakePlayerController();
          final auth = _FakeAuthController();

          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [observer],
              home: MediaQuery(
                data: const MediaQueryData(size: Size(1024, 600)),
                child: Builder(
                  builder: (context) {
                    return Scaffold(
                      body: ElevatedButton(
                        onPressed: () {
                          PlayerPageRoute.open<void>(
                            context,
                            player: player,
                            auth: auth,
                          );
                        },
                        child: const Text('Open Player'),
                      ),
                    );
                  },
                ),
              ),
            ),
          );

          await tester.tap(find.text('Open Player'));
          await tester.pump();

          expect(observer.pushedRoutes.last, isA<MaterialPageRoute<void>>());
          expect(
            observer.pushedRoutes.last,
            isNot(isA<PlayerPageRoute<void>>()),
          );

          await tester.pumpAndSettle();
          expect(find.byType(PlayerPage), findsOneWidget);
        },
      );

      testWidgets(
        'pushes PlayerPageRoute on landscape when carMode is disabled',
        (tester) async {
          debugDesktopFormFactorOverride = false;
          await ThemeController.instance.setCarModeEnabled(false);
          final observer = _TestNavigatorObserver();
          final player = _FakePlayerController();
          final auth = _FakeAuthController();

          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [observer],
              home: MediaQuery(
                data: const MediaQueryData(size: Size(1024, 600)),
                child: Builder(
                  builder: (context) {
                    return Scaffold(
                      body: ElevatedButton(
                        onPressed: () {
                          PlayerPageRoute.open<void>(
                            context,
                            player: player,
                            auth: auth,
                          );
                        },
                        child: const Text('Open Player'),
                      ),
                    );
                  },
                ),
              ),
            ),
          );

          await tester.tap(find.text('Open Player'));
          await tester.pump();

          expect(observer.pushedRoutes.last, isA<PlayerPageRoute<void>>());
          expect((observer.pushedRoutes.last as ModalRoute).opaque, isFalse);

          await tester.pumpAndSettle();
          expect(find.byType(PlayerPage), findsOneWidget);
        },
      );

      testWidgets(
        'pushes PlayerPageRoute on portrait even when carMode is enabled',
        (tester) async {
          debugDesktopFormFactorOverride = false;
          await ThemeController.instance.setCarModeEnabled(true);
          final observer = _TestNavigatorObserver();
          final player = _FakePlayerController();
          final auth = _FakeAuthController();

          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [observer],
              home: MediaQuery(
                data: const MediaQueryData(size: Size(390, 844)),
                child: Builder(
                  builder: (context) {
                    return Scaffold(
                      body: ElevatedButton(
                        onPressed: () {
                          PlayerPageRoute.open<void>(
                            context,
                            player: player,
                            auth: auth,
                          );
                        },
                        child: const Text('Open Player'),
                      ),
                    );
                  },
                ),
              ),
            ),
          );

          await tester.tap(find.text('Open Player'));
          await tester.pump();

          expect(observer.pushedRoutes.last, isA<PlayerPageRoute<void>>());
          expect((observer.pushedRoutes.last as ModalRoute).opaque, isFalse);

          await tester.pumpAndSettle();
          expect(find.byType(PlayerPage), findsOneWidget);
        },
      );
    });
  });
}
