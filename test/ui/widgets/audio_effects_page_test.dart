import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/services/audio_effects_service.dart';
import 'package:shiyin_music/ui/widgets/audio_effects_sheet.dart';

class _FakePlayer extends ChangeNotifier implements PlayerController {
  @override
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

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
  int disableAllEffectsCalls = 0;

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
  Future<void> disableAllAudioEffects() async {
    disableAllEffectsCalls++;
    equalizerEnabled = false;
    bassBoostEnabled = false;
    surroundEnabled = false;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpPage(WidgetTester tester, PlayerController player) async {
  // 统一钉住竖屏尺寸（默认 800x600 测试面是横屏，列数断言会漂移）；
  // 横屏见 [_pumpPageLandscape]。
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

/// 滚动主界面到 [text] 可见（卡片网格 shrinkWrap 全量构建，滚动只为
/// 让目标进入可点区域）。
Future<void> _scrollTo(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('音效主界面：卡片网格直选，推子与开关已下沉深层页', (tester) async {
    await _pumpPage(tester, _FakePlayer());

    expect(find.text('自定义音效'), findsOneWidget);
    // tab（音效｜增强）+ 音效段标题同名。
    expect(find.text('音效'), findsNWidgets(2));
    expect(find.text('均衡器预设'), findsOneWidget);
    expect(find.text('增强'), findsOneWidget);
    // 关闭卡 + 档案卡在首屏。
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('停用全部音效'), findsOneWidget);
    expect(find.text('全景环绕'), findsOneWidget);
    // 主界面不再有推子/开关/弹层按钮（全部下沉）。
    expect(find.byType(Slider), findsNothing);
    expect(find.text('启用均衡器'), findsNothing);
    expect(find.text('预设'), findsNothing);
    expect(find.text('重置'), findsNothing);
    // 16 预设卡 + 1 自定义入口卡 = 17 枚迷你曲线画板
    // （shrinkWrap 网格全量构建，数量确定）。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter?.runtimeType.toString() == '_PresetCurvePainter',
      ),
      findsNWidgets(17),
    );
  });

  testWidgets('点档案卡透出 applyAudioEffectProfile 且不关页', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('超重低音'));
    await tester.pumpAndSettle();
    expect(player.appliedProfiles.map((p) => p.name), ['超重低音']);
    expect(player.appliedPresets, isEmpty);
    expect(find.text('自定义音效'), findsOneWidget);
  });

  testWidgets('滚动到预设段点预设卡透出 applyEqualizerPreset', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await _scrollTo(tester, '流行');
    await tester.tap(find.text('流行'));
    await tester.pumpAndSettle();
    expect(player.appliedPresets.map((p) => p.name), ['流行']);
    expect(player.appliedProfiles, isEmpty);
  });

  testWidgets('点关闭卡透出 disableAllAudioEffects', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(player.disableAllEffectsCalls, 1);
    expect(player.appliedProfiles, isEmpty);
    expect(player.appliedPresets, isEmpty);
  });

  testWidgets('选中态：EQ 开且预设名命中时该预设卡带唯一角标', (tester) async {
    final player = _FakePlayer()
      ..equalizerEnabled = true; // presetName 默认「平直」
    await _pumpPage(tester, player);

    // 页面上唯一可能选中的来源即「平直」预设卡（档案名无一命中）。
    expect(find.byKey(const ValueKey('effect-selected-badge')), findsOneWidget);
  });

  testWidgets('选中态：三件全关时关闭卡带唯一角标', (tester) async {
    final player = _FakePlayer(); // EQ/低音/环绕默认全关
    await _pumpPage(tester, player);

    // 名字命中类选中均要求 equalizerEnabled，唯一选中来源只能是关闭卡。
    expect(find.byKey(const ValueKey('effect-selected-badge')), findsOneWidget);
    expect(find.text('停用全部音效'), findsOneWidget);
  });

  testWidgets('选中态：手动调过线（自定义）时入口卡带唯一角标', (tester) async {
    final player = _FakePlayer()
      ..equalizerEnabled = true
      ..equalizerPresetName = '自定义';
    await _pumpPage(tester, player);

    expect(find.byKey(const ValueKey('effect-selected-badge')), findsOneWidget);
  });

  testWidgets('自定义入口卡推入编辑页：开关/推子/重置齐全，可返回', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await _scrollTo(tester, '自定义');
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    expect(find.text('自定义均衡器'), findsOneWidget);
    expect(find.text('启用均衡器'), findsOneWidget);
    // fake 配置 5 段 → 5 根推子；频段标签抽查首尾。
    expect(find.text('60'), findsOneWidget);
    expect(find.text('14k'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(5));
    expect(find.text('重置'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('自定义均衡器'), findsNothing);
    expect(find.text('自定义音效'), findsOneWidget);
  });

  testWidgets('编辑页重置按钮透出控制器', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await _scrollTo(tester, '自定义');
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();
    expect(player.resetEqualizerCalls, 1);
  });

  testWidgets('编辑页拨动启用开关透出控制器', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await _scrollTo(tester, '自定义');
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(player.setEqualizerEnabledCalls, 1);
    expect(player.equalizerEnabled, isTrue);
  });

  testWidgets('切换到增强页显示低音增强与环绕，再切回音效卡片页', (tester) async {
    final player = _FakePlayer();
    await _pumpPage(tester, player);

    await tester.tap(find.text('增强'));
    await tester.pumpAndSettle();
    expect(find.text('低音增强'), findsOneWidget);
    expect(find.text('全景环绕'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));

    await tester.tap(find.text('音效').first);
    await tester.pumpAndSettle();
    // 回到卡片主界面：无滑块，关闭卡仍在。
    expect(find.byType(Slider), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('不支持的平台显示占位说明', (tester) async {
    await _pumpPage(tester, _FakePlayer(isAudioEffectsSupported: false));

    expect(find.text('当前平台暂不支持音效调节'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('关闭'), findsNothing);
  });

  testWidgets('横屏整幅卡片网格：右栏快捷区已删，档案卡点选即应用', (tester) async {
    final player = _FakePlayer();
    await _pumpPageLandscape(tester, player);

    // 旧「音效档案」右栏标题不复存在。
    expect(find.text('音效档案'), findsNothing);
    // 卡片网格整幅铺开，档案卡直接点选。
    await tester.tap(find.text('超重低音'));
    await tester.pumpAndSettle();
    expect(player.appliedProfiles.map((p) => p.name), ['超重低音']);
    expect(find.text('自定义音效'), findsOneWidget);
  });

  testWidgets('showAudioEffectsSheet 内容区推入：音效页落在内层 Navigator', (tester) async {
    final player = _FakePlayer();
    // 复刻车机 AppShell 结构：左侧常驻面板 + 内层内容区 Navigator。
    // 推入走最近 Navigator（无显式开关）：入口挂在内容区 Navigator 下即
    // 自然落内容区，常驻面板存活。
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

    // 深层编辑页同样只占内容区：从卡片网格推入后常驻面板仍在。
    await _scrollTo(tester, '自定义');
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.text('自定义均衡器'), findsOneWidget);
    expect(find.text('左侧常驻面板'), findsOneWidget);
  });
}
