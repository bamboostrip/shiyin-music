import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart' hide formatDuration;
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/vip_background_task.dart';
import 'package:shiyin_music/ui/settings/playback_settings_section.dart';

/// 「同步播放记录」开关（听歌时光机二期）：
/// - 默认关（读 Task 3 的 `player.cloudHistoryUploadEnabled`）；
/// - 点击开关调用 `player.setCloudHistoryUploadEnabled(true)`；
/// - 全平台可见，桌面形态下也在「听歌时光机」瓦片之后。
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Fake player 覆写了 setter 只记录调用，不会触 prefs；
    // 保险起见仍注入 mock，避免真实 SharedPreferences 通道。
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('「同步播放记录」默认关，点击开关调用 setter(true)', (tester) async {
    // 超高视口：分区内瓦片较多，600px 默认视口会纵向溢出
    // （真实页面里分区躺在可滚动 ListView 内，无此问题）。
    tester.view.physicalSize = const Size(1080, 20000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fakeApi = _FakeApi();
    final fakeAuth = _FakeAuth(_FakeVipClaim());
    final fakePlayer = _FakePlayer();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlaybackSettingsSection(
          api: fakeApi, auth: fakeAuth, player: fakePlayer,
          onSelectDefaultAudioQuality: () {},
        ),
      ),
    ));

    expect(find.text('同步播放记录'), findsOneWidget);
    // 说明：Switch 与标题 Text 是同行兄弟节点而非其后代，简报原稿的
    // find.descendant(of: text, matching: Switch) 定位不到，改用
    // settings_desktop_gate_test.dart 的沿祖先链找同行 Switch 的写法。
    final switchFinder = _switchOfTile(tester, '同步播放记录');
    expect(tester.widget<Switch>(switchFinder).value, isFalse);

    await tester.tap(switchFinder);
    await tester.pump();

    expect(fakePlayer.setterCalls, contains(true));
  });
}

/// 从瓦片标题文本沿祖先链找到同一行内的 Switch（确定性定位，
/// 避免分区内多个 Switch 的歧义）。
Finder _switchOfTile(WidgetTester tester, String title) {
  final textElement = tester.element(find.text(title));
  Element? switchElement;
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
  fail('未找到「$title」开关');
}

// --- 测试替身（参照 settings_desktop_gate_test.dart 构造）---

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
  /// setter 覆写只记录调用，不落盘、不改 getter（避免触 prefs）。
  final List<bool> setterCalls = [];

  @override
  bool get cloudHistoryUploadEnabled => false;

  @override
  Future<void> setCloudHistoryUploadEnabled(bool enabled) async {
    setterCalls.add(enabled);
  }

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

class _FakeApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
