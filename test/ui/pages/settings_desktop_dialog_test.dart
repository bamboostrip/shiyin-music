import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart' hide formatDuration;
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/vip_background_task.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/settings_page.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  group('桌面形态 (isDesktopFormFactor = true)', () {
    setUp(() {
      debugDesktopFormFactorOverride = true;
    });

    testWidgets('默认音质弹窗使用居中 Dialog，非移动端 BottomSheet', (tester) async {
      final player = _FakePlayer();
      await _pump(tester, player: player);

      await tester.tap(find.text('默认音质'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('默认音质'), findsWidgets);
      expect(find.text('无损音质'), findsOneWidget);

      // 点击无损音质
      await tester.tap(find.text('无损音质'));
      await tester.pumpAndSettle();

      expect(player.setAudioQualityCalls, [AudioQuality.lossless]);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('字体大小弹窗使用居中 Dialog，非移动端 BottomSheet', (tester) async {
      final theme = _FakeTheme();
      await _pump(tester, theme: theme);

      await tester.tap(find.text('字体大小'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('特大'), findsOneWidget);

      // 点击特大
      await tester.tap(find.text('特大'));
      await tester.pumpAndSettle();

      expect(theme.fontScaleCalls, [1.2]);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('缓存管理弹窗使用居中 Dialog，包含关闭按钮与管理项', (tester) async {
      await _pump(tester);

      await tester.tap(find.text('缓存管理'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('数据缓存'), findsOneWidget);
      expect(find.text('播放缓存'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      // 点击右上角关闭按钮
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
    });
  });

  group('移动端形态 (isDesktopFormFactor = false)', () {
    setUp(() {
      debugDesktopFormFactorOverride = false;
    });

    testWidgets('默认音质弹窗保持 BottomSheet', (tester) async {
      final player = _FakePlayer();
      await _pump(tester, player: player);

      await tester.tap(find.text('默认音质'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('字体大小弹窗保持 BottomSheet', (tester) async {
      final theme = _FakeTheme();
      await _pump(tester, theme: theme);

      await tester.tap(find.text('字体大小'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('缓存管理弹窗保持 BottomSheet', (tester) async {
      await _pump(tester);

      await tester.tap(find.text('缓存管理'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    });
  });
}

Future<void> _pump(
  WidgetTester tester, {
  _FakePlayer? player,
  _FakeTheme? theme,
}) async {
  tester.view.physicalSize = const Size(1080, 20000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final vipClaim = _FakeVipClaim();
  final p = player ?? _FakePlayer();
  final t = theme ?? _FakeTheme();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: Toast.navigatorKey,
      home: Scaffold(
        body: SettingsPage(
          api: _FakeApi(),
          auth: _FakeAuth(vipClaim),
          player: p,
          theme: t,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

class _FakeVipClaim extends ChangeNotifier implements VipBackgroundTask {
  @override
  String statusText() => '未开启';
  @override
  bool get autoEnabled => false;
  @override
  bool get isClaiming => false;
  @override
  String get lastMessage => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuth extends ChangeNotifier implements AuthController {
  _FakeAuth(this.vipClaim);
  @override
  final VipBackgroundTask vipClaim;
  @override
  bool get isLoading => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayer extends ChangeNotifier implements PlayerController {
  final List<AudioQuality> setAudioQualityCalls = [];

  @override
  AudioQuality get audioQuality => AudioQuality.standard;

  @override
  Future<void> setAudioQuality(
    AudioQuality quality, {
    bool reloadCurrent = false,
  }) async {
    setAudioQualityCalls.add(quality);
    notifyListeners();
  }

  @override
  bool get smartQualityEnabled => true;
  @override
  bool get autoPlayOnStartupEnabled => false;
  @override
  bool get autoPlayOnDeviceConnected => false;
  @override
  bool get loudnessEnabled => false;
  @override
  bool get isAudioEffectsSupported => false;
  @override
  bool get audioInterruptionEnabled => false;
  @override
  bool get autoResumeAfterInterruption => false;
  @override
  bool get addListeningTimeEnabled => false;
  @override
  bool get allowCellularPrecache => false;
  @override
  bool get isDesktopLyricsSupported => true;
  @override
  bool get desktopLyricsEnabled => false;
  @override
  bool get isBluetoothLyricsSupported => false;
  @override
  bool get isLoudnessAnalysisSupported => false;
  @override
  int get loudnessCacheCount => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTheme extends ChangeNotifier implements ThemeController {
  final List<double> fontScaleCalls = [];
  double _fontScale = 1.0;

  @override
  double get fontScale => _fontScale;

  @override
  Future<void> setFontScale(double scale) async {
    fontScaleCalls.add(scale);
    _fontScale = scale;
    notifyListeners();
  }

  @override
  Color get seedColor => const Color(0xFF5B6CF9);
  @override
  bool get backgroundEnabled => false;
  @override
  bool get landscapeEnabled => false;
  @override
  bool get carModeEnabled => false;
  @override
  bool get isAutomotiveDevice => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
