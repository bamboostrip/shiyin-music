import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/keyboard_shortcuts.dart';
import 'package:shiyin_music/ui/pages/app_shell.dart';

/// `PlayerController` 的最小替身：只关心快捷键真正调到的那几个方法。
class _FakePlayer extends ChangeNotifier implements PlayerController {
  int toggleCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  final List<Duration> seeks = [];
  @override
  double volume = 0.5;

  @override
  Duration get position => const Duration(seconds: 30);

  @override
  Duration get duration => const Duration(minutes: 3);

  @override
  Future<void> togglePlay() async => toggleCalls++;

  @override
  Future<void> next() async => nextCalls++;

  @override
  Future<void> previous() async => previousCalls++;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setVolume(double value) async => volume = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ShortcutController.instance.debugReset();
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);
  });

  Future<_FakePlayer> pumpScope(WidgetTester tester) async {
    final player = _FakePlayer();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShortcutScope(
          player: player,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return player;
  }

  // 页面看起来改好了、实际按键没生效，是这类「设置页 + 作用域」最容易漏的坑：
  // 这里直接驱动真实的 `Shortcuts` 表，验证 controller → 作用域这条线。
  group('AppShortcutScope 与 ShortcutController 接线', () {
    testWidgets('默认空格触发播放/暂停', (tester) async {
      final player = await pumpScope(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.toggleCalls, 1);
    });

    testWidgets('改键后立即生效：空格失效、Ctrl+K 生效', (tester) async {
      final player = await pumpScope(tester);

      await ShortcutController.instance.setBinding(
        AppShortcutAction.playPause,
        const KeyBinding(LogicalKeyboardKey.keyK, control: true),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.toggleCalls, 0, reason: '空格已不属于播放/暂停');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(player.toggleCalls, 1);
    });

    testWidgets('键被抢走后原动作彻底不响应（不会悄悄沿用默认键）', (tester) async {
      final player = await pumpScope(tester);

      // 把空格改给「快进 5 秒」：播放/暂停应变成未设置。
      await ShortcutController.instance.setBinding(
        AppShortcutAction.seekForward,
        const KeyBinding(LogicalKeyboardKey.space),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(player.toggleCalls, 0, reason: '播放/暂停不该还能被空格触发');
      expect(player.seeks, isNotEmpty, reason: '空格此时应执行快进');
    });

    testWidgets('暂停/切歌/音量仍按各自键位工作（改键不影响其它动作）', (tester) async {
      final player = await pumpScope(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(player.volume, closeTo(0.55, 0.001));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(player.nextCalls, 1);
    });
  });
}
