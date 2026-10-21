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

  @override
  bool surroundEnabled = false;

  @override
  double surroundStrength = 0.6;

  /// 环绕滑条按支持性条件渲染；fake 默认放行以维持既有断言。
  @override
  bool isSurroundSupported = true;

  int setEqualizerEnabledCalls = 0;
  final List<AudioEffectPreset> appliedPresets = [];
  final List<AudioEffectProfile> appliedProfiles = [];
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
  Future<void> setSurroundEnabled(bool enabled) async {
    surroundEnabled = enabled;
  }

  @override
  Future<void> setSurroundStrength(
    double strength, {
    bool persist = true,
  }) async {
    surroundStrength = strength;
  }

  @override
  Future<void> applyAudioEffectProfile(AudioEffectProfile profile) async {
    appliedProfiles.add(profile);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpPage(WidgetTester tester, PlayerController player) async {
  // 既有用例语义是竖屏单栏（默认 800x600 测试面是横屏，会切双栏），
  // 统一钉住竖屏尺寸；横屏双栏见 [_pumpPageLandscape]。
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: AudioEffectsPage(player: player)));
  await tester.pumpAndSettle();
}

Future<void> _pumpPageLandscape(
  WidgetTester tester,
  PlayerController player,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: AudioEffectsPage(player: player)));
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
    // 增强页有 Bass 与环绕两个滑块。
    expect(find.text('全景环绕'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));

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
    // 弹层两段卡片网格：顶部音效档案卡，下方带曲线预览的预设卡。
    expect(find.text('音效'), findsOneWidget);
    expect(find.text('全景环绕'), findsOneWidget);
    // 两段网格常超弹层高度，滚动到均衡器预设段（可见时零滚动直接命中）。
    await tester.scrollUntilVisible(
      find.text('流行'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('流行'));
    await tester.pumpAndSettle();
    expect(player.appliedPresets.map((p) => p.name), ['流行']);
    // 选择后 bottom sheet 关闭，回到均衡器页。
    expect(find.text('启用均衡器'), findsOneWidget);
  });

  testWidgets('预设弹层点音效档案卡透出 applyAudioEffectProfile', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('预设'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('全景环绕'));
    await tester.pumpAndSettle();
    expect(player.appliedProfiles.map((p) => p.name), ['全景环绕']);
    expect(player.appliedPresets, isEmpty);
    // 选择后 bottom sheet 关闭，回到均衡器页。
    expect(find.text('启用均衡器'), findsOneWidget);
  });

  testWidgets('预设弹层选中卡带对勾角标且 16 张卡各带曲线预览', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('预设'));
    await tester.pumpAndSettle();
    // 默认「平直」选中：仅它一张卡带角标，档案段全未选。
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('effect-selected-badge')), findsOneWidget);
    // 16 张预设卡各带一枚迷你折线画板。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter?.runtimeType.toString() == '_PresetCurvePainter',
      ),
      findsNWidgets(16),
    );
  });

  testWidgets('选中档案卡时角标落在音效段', (tester) async {
    final player = _FakePlayer()..equalizerPresetName = '超重低音';
    await _pumpPage(tester, player);

    await tester.tap(find.text('预设'));
    await tester.pumpAndSettle();
    // 角标唯一且档案名在弹层网格内可见（档案卡选中而非预设卡）。
    expect(find.byKey(const ValueKey('effect-selected-badge')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(GridView).first,
        matching: find.text('超重低音'),
      ),
      findsOneWidget,
    );
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

  testWidgets('横屏双栏：右栏 6 张档案快捷卡，点选即应用不关页', (tester) async {
    final player = _FakePlayer();
    await _pumpPageLandscape(tester, player);

    // 左栏面板照常渲染，右栏出现音效档案快捷区与 6 张档案卡。
    expect(find.text('启用均衡器'), findsOneWidget);
    expect(find.text('音效档案'), findsOneWidget);
    for (final name in [
      '全景环绕',
      '3D丽音',
      '超重低音',
      '纯净人声',
      '现场演唱会',
      '深夜舒缓',
    ]) {
      expect(find.text(name), findsOneWidget);
    }
    // 默认「平直」不在档案列表里：右栏全部未选中。
    expect(find.byKey(const ValueKey('effect-selected-badge')), findsNothing);

    await tester.tap(find.text('超重低音'));
    await tester.pumpAndSettle();
    expect(player.appliedProfiles.map((p) => p.name), ['超重低音']);
    // 快捷卡点选即应用且不关页。
    expect(find.text('自定义音效'), findsOneWidget);
  });

  testWidgets('横屏双栏：选中档案卡在右栏带对勾角标', (tester) async {
    final player = _FakePlayer()..equalizerPresetName = '纯净人声';
    await _pumpPageLandscape(tester, player);

    // 角标唯一（默认 tab 是均衡器，页面上唯一可选卡来源即右栏档案卡）。
    expect(find.byKey(const ValueKey('effect-selected-badge')), findsOneWidget);
    expect(find.text('纯净人声'), findsOneWidget);
  });

  testWidgets('竖屏保持单栏：无右栏音效档案快捷区', (tester) async {
    await _pumpPage(tester, _FakePlayer());

    expect(find.text('音效档案'), findsNothing);
    expect(find.text('全景环绕'), findsNothing);
    expect(find.text('启用均衡器'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(5));
  });

  testWidgets('showAudioEffectsSheet 内容区推入：音效页落在内层 Navigator', (tester) async {
    final player = _FakePlayer();
    // 复刻车机 AppShell 结构：左侧常驻面板 + 内层内容区 Navigator。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 200, child: Text('左侧常驻面板')),
              Expanded(
                child: Navigator(
                  onGenerateRoute: (settings) => MaterialPageRoute(
                    builder: (navContext) => Center(
                      child: ElevatedButton(
                        onPressed: () => showAudioEffectsSheet(
                          context: navContext,
                          player: player,
                          inContentArea: true,
                        ),
                        child: const Text('打开音效'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开音效'));
    await tester.pumpAndSettle();

    // 音效页已打开，且推的是内层 Navigator：左侧常驻面板仍在树上
    // （若推根 Navigator，home 整页会被不透明路由盖掉）。
    expect(find.text('自定义音效'), findsOneWidget);
    expect(find.text('左侧常驻面板'), findsOneWidget);
    expect(find.text('打开音效'), findsNothing);
  });
}
