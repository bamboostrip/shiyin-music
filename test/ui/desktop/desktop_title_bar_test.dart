import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/desktop/desktop_title_bar.dart';

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? currentSong;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  testWidgets('renders logo and title 时音', (tester) async {
    final player = _FakePlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopTitleBar(player: player),
        ),
      ),
    );

    expect(find.text('时音'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName == 'lib/assets/logo.png',
      ),
      findsOneWidget,
    );
  });

  testWidgets('displays current song title and artist when currentSong is not null',
      (tester) async {
    final player = _FakePlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopTitleBar(player: player),
        ),
      ),
    );

    expect(find.text('夜曲 - 周杰伦'), findsNothing);

    player.currentSong = const Song(
      id: '1',
      title: '夜曲',
      artist: '周杰伦',
      hash: 'hash-1',
    );
    player.notifyListeners();
    await tester.pump();

    expect(find.text('夜曲 - 周杰伦'), findsOneWidget);
  });

  testWidgets('renders minimize, maximize/restore, and close buttons',
      (tester) async {
    final player = _FakePlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopTitleBar(player: player),
        ),
      ),
    );

    expect(find.byIcon(Icons.remove_rounded), findsOneWidget);
    expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('clicking window buttons calls windowManager', (tester) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        calls.add(call.method);
        if (call.method == 'isMaximized') return false;
        return null;
      },
    );

    final player = _FakePlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopTitleBar(player: player),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.remove_rounded));
    await tester.pump();
    expect(calls, contains('minimize'));

    await tester.tap(find.byIcon(Icons.crop_square_rounded));
    await tester.pump();
    expect(calls, contains('maximize'));

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(calls, contains('close'));
  });

  testWidgets('double clicking middle area toggles maximize/unmaximize',
      (tester) async {
    final calls = <String>[];
    bool isMax = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        calls.add(call.method);
        if (call.method == 'isMaximized') return isMax;
        if (call.method == 'maximize') {
          isMax = true;
          return null;
        }
        if (call.method == 'unmaximize') {
          isMax = false;
          return null;
        }
        return null;
      },
    );

    final player = _FakePlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopTitleBar(player: player),
        ),
      ),
    );

    // Double tap the middle area
    final middle = find.byKey(const ValueKey('desktop_title_bar_middle'));
    expect(middle, findsOneWidget);

    await tester.tap(middle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(middle);
    await tester.pumpAndSettle();

    expect(calls, contains('maximize'));
  });
}
