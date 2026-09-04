import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart' hide formatDuration;
import 'package:shiyin_music/services/desktop_system_integration.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/vip_background_task.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/settings_page.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

/// 设置项可见性门控（Task 4 要求 5/6）：
/// - 桌面端隐藏移动专属三组：连接新音频设备自动播放 / 后台打断机制 /
///   增加听歌时长；
/// - 桌面端「桌面」分组含「开机自启」开关（移动端无「桌面」分组）；
/// - 移动端三组原样显示、「桌面」分组不出现；
/// - 开机自启切换经 [autoStartManager] 抽象调用 fake register/unregister，
///   失败时 UI 回滚到 OS 真实状态。
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  group('桌面形态', () {
    late _RecordingAutoStartManager autoStart;

    setUp(() {
      debugDesktopFormFactorOverride = true;
      autoStart = _RecordingAutoStartManager();
      autoStartManager = autoStart;
    });

    tearDown(() {
      autoStartManager = _LaunchAtStartupNoop();
    });

    testWidgets('隐藏移动专属三组，显示桌面分组与开机自启开关', (tester) async {
      await _pump(tester);

      expect(find.text('连接新音频设备自动播放'), findsNothing);
      expect(find.text('后台打断机制'), findsNothing);
      expect(find.text('增加听歌时长'), findsNothing);

      expect(find.text('桌面'), findsOneWidget);
      expect(find.text('关闭时最小化到托盘'), findsOneWidget);
      expect(find.text('开机自启'), findsOneWidget);
      expect(find.text('重置窗口'), findsOneWidget);

      // 默认关。
      expect(_autoStartSwitch(tester).value, isFalse);
      expect(autoStart.reads, 1);
      expect(autoStart.writes, isEmpty);
    });

    testWidgets('切换开关调用 fake register，并回读实际状态', (tester) async {
      await _pump(tester);
      final switchFinder = _autoStartSwitchFinder(tester);

      await tester.tap(switchFinder);
      await tester.pump();
      await tester.pump();

      expect(autoStart.writes, [true]);
      expect(_autoStartSwitch(tester).value, isTrue);

      // 再点回去：disable。
      await tester.tap(switchFinder);
      await tester.pump();
      await tester.pump();

      expect(autoStart.writes, [true, false]);
      expect(_autoStartSwitch(tester).value, isFalse);
    });

    testWidgets('写注册表失败时开关回滚到关闭并提示', (tester) async {
      autoStart.failOnWrite = true;
      await _pump(tester);

      await tester.tap(_autoStartSwitchFinder(tester));
      await tester.pump();
      await tester.pump();

      // OS 实际状态（fake 中保持 false）被回填到 UI。
      expect(autoStart.writes, [true]);
      expect(_autoStartSwitch(tester).value, isFalse);
      expect(find.text('设置开机自启失败'), findsOneWidget);

      // 等 Toast 自动消失，避免测试结束仍挂 Timer。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('回读结果与写入目标不一致时以 OS 为准', (tester) async {
      // 模拟 enable 静默失败（如组策略拦截注册表写入）。
      autoStart.silentWriteFailure = true;
      await _pump(tester);

      await tester.tap(_autoStartSwitchFinder(tester));
      await tester.pump();
      await tester.pump();

      expect(_autoStartSwitch(tester).value, isFalse);
      expect(find.text('设置开机自启失败'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });

  group('移动端形态', () {
    testWidgets('移动专属三组原样显示，无「桌面」分组与开机自启', (tester) async {
      debugDesktopFormFactorOverride = false;
      await _pump(tester);

      expect(find.text('连接新音频设备自动播放'), findsOneWidget);
      expect(find.text('后台打断机制'), findsOneWidget);
      expect(find.text('增加听歌时长'), findsOneWidget);

      expect(find.text('桌面'), findsNothing);
      expect(find.text('开机自启'), findsNothing);
      expect(find.text('关闭时最小化到托盘'), findsNothing);
      expect(find.text('重置窗口'), findsNothing);
    });
  });
}

/// 从「开机自启」文本向上找到所在瓦片行的 Switch（确定性定位，
/// 避免页面内多个 Switch 的歧义）。
Switch _autoStartSwitch(WidgetTester tester) =>
    tester.widget<Switch>(_autoStartSwitchFinder(tester));

Finder _autoStartSwitchFinder(WidgetTester tester) {
  final textElement = tester.element(find.text('开机自启'));
  Element? switchElement;
  // 沿祖先链由近及远查找第一个含 Switch 子节点的多子节点（瓦片行 Row）。
  textElement.visitAncestorElements((ancestor) {
    ancestor.visitChildren((child) {
      if (child.widget is Switch) {
        switchElement ??= child;
      }
    });
    return switchElement == null; // 找到后停止遍历
  });
  if (switchElement != null) {
    return find.byElementPredicate(
      (element) => identical(element, switchElement),
    );
  }
  fail('未找到「开机自启」开关');
}

Future<void> _pump(WidgetTester tester) async {
  // 超高视口让懒加载 ListView 一次性构建全部条目（免滚动断言）。
  tester.view.physicalSize = const Size(1080, 20000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final vipClaim = _FakeVipClaim();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: Toast.navigatorKey,
      home: Scaffold(
        body: SettingsPage(
          api: _FakeApi(),
          auth: _FakeAuth(vipClaim),
          player: _FakePlayer(),
          theme: _FakeTheme(),
        ),
      ),
    ),
  );
  // 两帧：prefs/auto-start 异步读取完成后的 setState。
  await tester.pump();
  await tester.pump();
}

// --- 测试替身 ---

class _RecordingAutoStartManager implements AutoStartManager {
  bool _enabled = false;
  bool failOnWrite = false;
  bool silentWriteFailure = false;
  int reads = 0;
  final List<bool> writes = [];

  @override
  Future<bool> isEnabled() async {
    reads++;
    return _enabled;
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    writes.add(enabled);
    if (failOnWrite) {
      throw Exception('注册表写入被拒绝');
    }
    if (!silentWriteFailure) {
      _enabled = enabled;
    }
  }
}

/// 测试结束还原全局 manager，避免污染真实注册表读取路径。
class _LaunchAtStartupNoop implements AutoStartManager {
  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> setEnabled(bool enabled) async {}
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
  @override
  AudioQuality get audioQuality => AudioQuality.standard;

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
  bool get isDesktopLyricsSupported => true;

  @override
  bool get desktopLyricsEnabled => false;

  @override
  bool get isBluetoothLyricsSupported => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTheme extends ChangeNotifier implements ThemeController {
  @override
  double get fontScale => 1.0;

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
