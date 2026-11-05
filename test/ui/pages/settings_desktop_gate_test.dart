import 'package:flutter/foundation.dart';
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

/// 设置页可见性门控（重构后主页面只做目录，详细开关在二级页）：
/// - 桌面端主页面显示「桌面」分组（登录自启/托盘/重置窗口）；
/// - 移动端专属三组（连接新音频设备自动播放 / 后台打断机制 / 增加听歌时长）
///   与常亮、歌词页切歌键都在「播放设置」二级页里按形态显隐；
/// - 车机模式下车机、PC 专属场景隐藏歌词页切歌键，车机显示分节出现在
///   「外观与个性化」二级页；
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

    testWidgets('主页面显示桌面分组，移动专属项在播放页不出现', (tester) async {
      await _pump(tester);

      // 主页面：目录化后只保留入口与短的平台分组。
      expect(find.text('播放设置'), findsOneWidget);
      expect(find.text('存储与下载'), findsOneWidget);
      expect(find.text('外观与个性化'), findsOneWidget);
      expect(find.text('桌面'), findsOneWidget);
      expect(find.text('关闭时最小化到托盘'), findsOneWidget);
      // 桌面端「登录时自动启动」与播放里的「启动时自动播放」区分开。
      expect(find.text('登录时自动启动'), findsOneWidget);
      expect(find.text('开机自启'), findsNothing);
      expect(find.text('下载位置'), findsOneWidget);
      expect(find.text('重置窗口'), findsOneWidget);

      // 桌面恒横屏、无车机概念：横屏/车机开关与车机显示都不在主页面。
      expect(find.text('横屏模式'), findsNothing);
      expect(find.text('车机模式'), findsNothing);
      expect(find.text('车机显示'), findsNothing);

      // 进入播放设置页：桌面端不出现移动专属开关。
      await _openPlaybackSettings(tester);
      expect(find.text('音质与音效'), findsOneWidget);
      expect(find.text('连接新音频设备自动播放'), findsNothing);
      expect(find.text('后台打断机制'), findsNothing);
      expect(find.text('增加听歌时长'), findsNothing);
      expect(find.text('播放页保持屏幕常亮'), findsNothing);
      expect(find.text('歌词页切歌键'), findsNothing);
      expect(find.text('响度均衡'), findsOneWidget);

      // 默认关。
      await tester.pageBack();
      await tester.pumpAndSettle();
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
    testWidgets('移动专属三组在播放页原样显示，主页面无「桌面」分组', (tester) async {
      debugDesktopFormFactorOverride = false;
      await _pump(tester);

      expect(find.text('桌面'), findsNothing);
      expect(find.text('登录时自动启动'), findsNothing);
      expect(find.text('关闭时最小化到托盘'), findsNothing);
      expect(find.text('重置窗口'), findsNothing);
      // 下载位置不再是桌面专属：Android 同样可改下载目录（issue #10）。
      expect(find.text('下载位置'), findsOneWidget);
      // 车机模式未开启时「车机显示」分节不出现。
      expect(find.text('车机显示'), findsNothing);

      await _openPlaybackSettings(tester);
      expect(find.text('连接新音频设备自动播放'), findsOneWidget);
      expect(find.text('后台打断机制'), findsOneWidget);
      expect(find.text('增加听歌时长'), findsOneWidget);
      expect(find.text('歌词页切歌键'), findsOneWidget);
    });

    testWidgets('歌词页切歌键瓦片：默认关，点击后写回 controller 并即时刷新', (tester) async {
      debugDesktopFormFactorOverride = false;
      final player = _FakePlayer();
      await _pump(tester, player: player);
      await _openPlaybackSettings(tester);

      expect(find.text('歌词页切歌键'), findsOneWidget);
      final switchFinder = _switchFinderForText(tester, '歌词页切歌键');
      expect(tester.widget<Switch>(switchFinder).value, isFalse);

      await tester.tap(find.text('歌词页切歌键'));
      await tester.pump();

      expect(player.lyricPageSkipWrites, [true]);
      expect(player.lyricPageSkipButtonsEnabled, isTrue);
      expect(tester.widget<Switch>(switchFinder).value, isTrue);
    });

    testWidgets('车机模式下车机、PC 专属场景隐藏歌词页切歌键', (tester) async {
      debugDesktopFormFactorOverride = false;
      await _pump(tester, theme: _FakeTheme(carModeEnabled: true));

      // 只有手机/平板形态需要该开关；车机横屏走分栏布局、没有歌词页底栏。
      await _openPlaybackSettings(tester);
      expect(find.text('歌词页切歌键'), findsNothing);
      // 同组其他手机开关仍在，证明页面正常构建而非整体缺失。
      expect(find.text('播放页保持屏幕常亮'), findsOneWidget);

      // 车机模式开启时「车机显示」分节出现在外观与个性化页。
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _openAppearanceSettings(tester);
      expect(find.text('车机显示'), findsOneWidget);
      expect(find.text('恢复默认车机显示'), findsOneWidget);
    });

    testWidgets('车机设备（即使手动关闭车机模式）同样隐藏歌词页切歌键', (tester) async {
      debugDesktopFormFactorOverride = false;
      await _pump(tester, theme: _FakeTheme(isAutomotiveDevice: true));

      await _openPlaybackSettings(tester);
      expect(find.text('歌词页切歌键'), findsNothing);
      expect(find.text('播放页保持屏幕常亮'), findsOneWidget);
    });

    testWidgets('切换车机模式后歌词页切歌键与车机显示即时显隐', (tester) async {
      debugDesktopFormFactorOverride = false;
      final theme = _FakeTheme();
      await _pump(tester, theme: theme);

      await _openPlaybackSettings(tester);
      expect(find.text('歌词页切歌键'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      theme.carModeEnabled = true;
      theme.notifyListeners();
      await tester.pump();

      // 车机显示分节随车机模式即时显隐（外观与个性化页）。
      await _openAppearanceSettings(tester);
      expect(find.text('车机显示'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // 再次进入播放页：入口按当前车机状态传入，切歌键隐藏。
      await _openPlaybackSettings(tester);
      expect(find.text('歌词页切歌键'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();

      theme.carModeEnabled = false;
      theme.notifyListeners();
      await tester.pump();

      await _openPlaybackSettings(tester);
      expect(find.text('歌词页切歌键'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _openAppearanceSettings(tester);
      expect(find.text('车机显示'), findsNothing);
    });

    testWidgets('手机视口也显示横屏/车机开关（残留值可改）', (tester) async {
      debugDesktopFormFactorOverride = false;
      // 手机视口：最短边 <600（此前提下旧逻辑会藏起开关）；
      // 高度拉满使懒加载 ListView 一次性构建全部条目（免滚动断言）。
      await _pump(tester, size: const Size(400, 20000));

      await _openAppearanceSettings(tester);
      expect(find.text('横屏模式'), findsOneWidget);
      expect(find.text('车机模式'), findsOneWidget);
    });

    testWidgets('移动端形态下即使运行在 Windows 上也不显示 Windows 限制提示', (tester) async {
      debugDesktopFormFactorOverride = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await _pump(tester);

        await _openPlaybackSettings(tester);
        expect(find.text('响度均衡'), findsOneWidget);
        expect(find.text('基于 EBU R128 LUFS 标准化，降低各首歌曲音量差异'), findsOneWidget);
        expect(find.textContaining('Windows 仅支持压低偏响歌曲'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Windows 宿主 + FORCE_MOBILE 预览移动端布局时，常亮开关依然展示', (tester) async {
      // 回归点：`--dart-define=FORCE_MOBILE=true` 只强制 isDesktopFormFactor
      // 为 false，宿主平台仍是 windows。可见性必须只跟形态走，与
      // 「后台打断机制」同口径。
      debugDesktopFormFactorOverride = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await _pump(tester);

        await _openPlaybackSettings(tester);
        expect(find.text('播放页保持屏幕常亮'), findsOneWidget);
        // 与同组「后台打断机制」「增加听歌时长」同进同出。
        expect(find.text('后台打断机制'), findsOneWidget);
        expect(find.text('增加听歌时长'), findsOneWidget);
        expect(find.text('歌词页切歌键'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('桌面形态响度提示', () {
    testWidgets('桌面形态在 Windows 平台上不显示平台限制提示（mpv 后端已支持放大）', (tester) async {
      debugDesktopFormFactorOverride = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await _pump(tester);

        await _openPlaybackSettings(tester);
        expect(find.text('响度均衡'), findsOneWidget);
        expect(find.text('基于 EBU R128 LUFS 标准化，降低各首歌曲音量差异'), findsOneWidget);
        expect(find.textContaining('仅支持压低'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

/// 从「登录时自动启动」文本向上找到所在瓦片行的 Switch（确定性定位，
/// 避免页面内多个 Switch 的歧义）。
Switch _autoStartSwitch(WidgetTester tester) =>
    tester.widget<Switch>(_autoStartSwitchFinder(tester));

Finder _autoStartSwitchFinder(WidgetTester tester) =>
    _switchFinderForText(tester, '登录时自动启动');

/// 从指定文案向上找到所在瓦片行的 [Switch]（确定性定位，
/// 避免页面内多个 Switch 的歧义）。
Finder _switchFinderForText(WidgetTester tester, String text) {
  final textElement = tester.element(find.text(text));
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
  fail('未找到「$text」所在瓦片的开关');
}

/// 打开「播放设置」二级页。
Future<void> _openPlaybackSettings(WidgetTester tester) async {
  await tester.tap(find.text('播放设置'));
  await tester.pumpAndSettle();
}

/// 打开「外观与个性化」二级页。
Future<void> _openAppearanceSettings(WidgetTester tester) async {
  await tester.tap(find.text('主题与显示'));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester, {
  _FakePlayer? player,
  _FakeTheme? theme,
  Size size = const Size(1080, 20000),
}) async {
  // 超高视口让懒加载 ListView 一次性构建全部条目（免滚动断言）。
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final vipClaim = _FakeVipClaim();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: Toast.navigatorKey,
      theme: ThemeData(pageTransitionsTheme: _noPageTransitions),
      home: Scaffold(
        body: SettingsPage(
          api: _FakeApi(),
          auth: _FakeAuth(vipClaim),
          player: player ?? _FakePlayer(),
          theme: theme ?? _FakeTheme(),
        ),
      ),
    ),
  );
  // 两帧：prefs/auto-start 异步读取完成后的 setState。
  await tester.pump();
  await tester.pump();
}

// --- 测试替身 ---

/// 超高视口（20000px）下页面转场会对整页做 SnapshotWidget，测试里禁用转场动画。
const _noPageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: _NoTransitionsBuilder(),
    TargetPlatform.iOS: _NoTransitionsBuilder(),
    TargetPlatform.windows: _NoTransitionsBuilder(),
    TargetPlatform.linux: _NoTransitionsBuilder(),
    TargetPlatform.macOS: _NoTransitionsBuilder(),
  },
);

class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

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
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

  // 歌词页切歌键开关（issue #3）：默认关 = QQ 原版底栏。
  @override
  bool lyricPageSkipButtonsEnabled = false;

  /// 切歌键瓦片点击写回的入参记录（断言 UI → controller 接线）。
  final List<bool> lyricPageSkipWrites = [];

  @override
  Future<void> setLyricPageSkipButtonsEnabled(bool enabled) async {
    lyricPageSkipWrites.add(enabled);
    lyricPageSkipButtonsEnabled = enabled;
    notifyListeners();
  }

  // 搜索点歌替换播放队列开关（issue #6-3）：默认关 = 插入当前队列。
  @override
  bool searchPlayReplaceQueue = false;

  @override
  Future<void> setSearchPlayReplaceQueue(bool enabled) async {
    searchPlayReplaceQueue = enabled;
    notifyListeners();
  }

  // 「显示已下架/无版权歌曲」：设置页只读该值，测试保持默认关闭。
  @override
  bool get showUnavailableSongs => false;

  /// 设置页「播放页保持屏幕常亮」开关会读写这两个成员。
  @override
  bool keepScreenOnEnabled = true;

  @override
  Future<void> setKeepScreenOnEnabled(bool enabled) async {
    keepScreenOnEnabled = enabled;
    notifyListeners();
  }

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
  bool get allowCellularPrecache => false;

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
  _FakeTheme({this.carModeEnabled = false, this.isAutomotiveDevice = false});

  // 外观模式/字数等 getter：页面与入口副标题读取。
  @override
  ThemeMode get themeMode => ThemeMode.system;

  @override
  String get themeModeLabel => '跟随系统';

  @override
  bool carModeEnabled;

  @override
  bool isAutomotiveDevice;

  @override
  double get fontScale => 1.0;

  @override
  Color get seedColor => const Color(0xFF5B6CF9);

  @override
  bool get backgroundEnabled => false;

  @override
  String? get backgroundImagePath => null;

  @override
  double get backgroundOpacity => 0.15;

  @override
  bool get hasCustomSeedColor => false;

  @override
  bool get landscapeEnabled => false;

  @override
  Future<void> setSeedColor(Color color) async {}

  @override
  Future<void> setBackgroundEnabled(bool enabled) async {}

  @override
  Future<void> setBackgroundOpacity(double opacity) async {}

  @override
  Future<bool> pickAndSetBackgroundImage() async => false;

  @override
  Future<bool> clearBackgroundImage() async => true;

  @override
  Future<void> setLandscapeEnabled(bool enabled, bool isTablet) async {}

  @override
  Future<void> setCarModeEnabled(bool enabled) async {}

  @override
  Future<void> setFontScale(double scale) async {}

  // 车机显示微调（分节仅在车机模式开启时构建，此处给中性默认值即可）。
  @override
  double get carDisplayScale => 1.0;

  @override
  double get carMarginTop => 0;

  @override
  double get carMarginBottom => 0;

  @override
  bool get hasCustomCarDisplay => false;

  @override
  Future<void> setCarDisplayScale(double scale) async {}

  @override
  Future<void> setCarMarginTop(double margin) async {}

  @override
  Future<void> setCarMarginBottom(double margin) async {}

  @override
  Future<void> resetCarDisplay() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
