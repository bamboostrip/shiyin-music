import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/services/audio_effects_service.dart';
import 'package:shiyin_music/ui/widgets/audio_effects_sheet.dart';

class _FakePlayer extends ChangeNotifier implements PlayerController {
  _FakePlayer({this.isAudioEffectsSupported = true});

  @override
  bool isAudioEffectsSupported;

  @override
  EqualizerConfig equalizerConfig = const EqualizerConfig(
    minMillibels: -1500,
    maxMillibels: 1500,
    bands: [
      EqualizerBand(centerHz: 60, levelMillibels: 0),
      EqualizerBand(centerHz: 230, levelMillibels: 0),
      EqualizerBand(centerHz: 910, levelMillibels: 0),
      EqualizerBand(centerHz: 3600, levelMillibels: 0),
      EqualizerBand(centerHz: 14000, levelMillibels: 0),
    ],
  );

  @override
  List<int> equalizerLevels = [0, 0, 0, 0, 0];

  @override
  bool equalizerEnabled = false;

  @override
  String equalizerPresetName = '平直';

  @override
  bool bassBoostEnabled = false;

  @override
  double bassBoostStrength = 0.5;

  int setEqualizerEnabledCalls = 0;
  final List<AudioEffectPreset> appliedPresets = [];
  int resetEqualizerCalls = 0;

  @override
  Future<void> setEqualizerEnabled(bool enabled) async {
    setEqualizerEnabledCalls++;
    equalizerEnabled = enabled;
    notifyListeners();
  }

  @override
  Future<void> setEqualizerBandLevel(
    int index,
    int levelMillibels, {
    bool persist = true,
  }) async {}

  @override
  Future<void> resetEqualizer() async {
    resetEqualizerCalls++;
  }

  @override
  Future<void> applyEqualizerPreset(AudioEffectPreset preset) async {
    appliedPresets.add(preset);
  }

  @override
  Future<void> setBassBoostEnabled(bool enabled) async {}

  @override
  Future<void> setBassBoostStrength(
    double strength, {
    bool persist = true,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpPage(WidgetTester tester, PlayerController player) async {
  await tester.pumpWidget(
    MaterialApp(home: AudioEffectsPage(player: player)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('均衡器页渲染：分段切换、开关、频段滑块与预设重置按钮', (tester) async {
    await _pumpPage(tester, _FakePlayer());

    expect(find.text('自定义音效'), findsOneWidget);
    expect(find.text('均衡器'), findsWidgets);
    expect(find.text('增强'), findsOneWidget);
    expect(find.text('启用均衡器'), findsOneWidget);
    // 频段标签与分贝值。
    expect(find.text('60'), findsOneWidget);
    expect(find.text('3.6k'), findsOneWidget);
    expect(find.text('预设'), findsOneWidget);
    expect(find.text('重置'), findsOneWidget);
    // 5 个频段滑块。
    expect(find.byType(Slider), findsNWidgets(5));
  });

  testWidgets('切换到增强页显示低音增强，再切回均衡器', (tester) async {
    await _pumpPage(tester, _FakePlayer());

    await tester.tap(find.text('增强'));
    await tester.pumpAndSettle();
    expect(find.text('低音增强'), findsOneWidget);
    // 增强页只有一个 Bass 滑块。
    expect(find.byType(Slider), findsOneWidget);

    await tester.tap(find.text('均衡器'));
    await tester.pumpAndSettle();
    expect(find.text('启用均衡器'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(5));
  });

  testWidgets('拨动启用均衡器开关透出控制器', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(player.setEqualizerEnabledCalls, 1);
    expect(player.equalizerEnabled, isTrue);
  });

  testWidgets('点预设弹出预设表，选流行透出控制器并关闭', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('预设'));
    await tester.pumpAndSettle();
    expect(find.text('流行'), findsOneWidget);

    await tester.tap(find.text('流行'));
    await tester.pumpAndSettle();
    expect(player.appliedPresets.map((p) => p.name), ['流行']);
    // 选择后 bottom sheet 关闭，回到均衡器页。
    expect(find.text('启用均衡器'), findsOneWidget);
  });

  testWidgets('重置按钮透出控制器', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();
    expect(player.resetEqualizerCalls, 1);
  });

  testWidgets('不支持的平台显示占位说明', (tester) async {
    await _pumpPage(tester, _FakePlayer(isAudioEffectsSupported: false));

    expect(find.text('当前平台暂不支持音效调节'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
  });
}
