// 设置页「播放」分节里手环/AVRCP 歌词标题同步开关的可见性门控：
//   1. 车载蓝牙歌词关闭 → 开关隐藏（避免「看得到但无效」）；
//   2. 车载蓝牙歌词开启 → 开关显示，文案与实时值来自控制器；
//   3. 点击开关调用控制器 setter（落盘/下发由 controller 单测覆盖）。
//
// 用 Fake PlayerController 隔离播放器依赖：本节只消费只读 getter 与回调，
// 不创建 AudioPlayer（仓库单测禁止真实音频引擎）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/settings/playback_settings_section.dart';
import 'package:shiyin_music/ui/settings/settings_widgets.dart';

class _FakeAuthController extends Fake implements AuthController {}

class _FakeMusicApi extends Fake implements MusicApi {}

class _FakePlayerController extends Fake implements PlayerController {
  bool bluetoothLyricsEnabledValue = false;
  bool bluetoothLyricsTitleSyncEnabledValue = false;
  final List<bool> titleSyncToggles = <bool>[];

  @override
  bool get bluetoothLyricsEnabled => bluetoothLyricsEnabledValue;

  @override
  bool get bluetoothLyricsTitleSyncEnabled =>
      bluetoothLyricsTitleSyncEnabledValue;

  @override
  Future<void> setBluetoothLyricsTitleSyncEnabled(bool enabled) async {
    titleSyncToggles.add(enabled);
    bluetoothLyricsTitleSyncEnabledValue = enabled;
  }

  @override
  Future<void> setBluetoothLyricsEnabled(bool enabled) async {
    bluetoothLyricsEnabledValue = enabled;
  }

  // ---- 本节 build 读取的其余只读状态（默认值即可，避免触发 UnimplementedError）----
  @override
  bool get isBluetoothLyricsSupported => true;

  @override
  bool get isDesktopLyricsSupported => true;

  @override
  bool get isAudioEffectsSupported => true;

  @override
  String get audioEffectsLabel => '无';

  @override
  bool get loudnessEnabled => false;

  @override
  bool get smartQualityEnabled => false;

  @override
  bool get searchPlayReplaceQueue => false;

  @override
  bool get allowCellularPrecache => false;

  @override
  bool get autoPlayOnStartupEnabled => false;

  @override
  bool get autoPlayOnDeviceConnected => false;

  @override
  bool get desktopLyricsEnabled => false;

  @override
  bool get lyricPageSkipButtonsEnabled => false;

  @override
  AudioQuality get audioQuality => AudioQuality.standard;
}

Future<void> _pumpSection(WidgetTester tester, _FakePlayerController player) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PlaybackSettingsSection(
            api: _FakeMusicApi(),
            auth: _FakeAuthController(),
            player: player,
            onSelectDefaultAudioQuality: () {},
            showLyricPageSkipButtons: false,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('车载蓝牙歌词关闭时，手环/AVRCP 标题同步开关隐藏', (tester) async {
    final player = _FakePlayerController()
      ..bluetoothLyricsEnabledValue = false
      ..bluetoothLyricsTitleSyncEnabledValue = true;

    await _pumpSection(tester, player);

    expect(find.text('车载蓝牙歌词'), findsOneWidget);
    expect(
      find.text('手环 / AVRCP 歌词同步'),
      findsNothing,
      reason: '车载蓝牙歌词关闭时标题同步不可用，必须隐藏',
    );
  });

  testWidgets('车载蓝牙歌词开启时显示开关，默认关闭', (tester) async {
    final player = _FakePlayerController()..bluetoothLyricsEnabledValue = true;

    await _pumpSection(tester, player);

    expect(find.text('手环 / AVRCP 歌词同步'), findsOneWidget);
    expect(find.text('将实时歌词同步为媒体标题，供手环、手表与车机仪表盘显示'), findsOneWidget);
    final switchTile = tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(
          of: find.text('手环 / AVRCP 歌词同步'),
          matching: find.byType(SettingsSwitchTile),
        ),
        matching: find.byType(Switch),
      ),
    );
    expect(switchTile.value, isFalse, reason: '默认关闭：不覆盖锁屏/车机标题');
  });

  testWidgets('点击开关调用控制器 setter（落盘与下发由 controller 负责）', (tester) async {
    final player = _FakePlayerController()..bluetoothLyricsEnabledValue = true;

    await _pumpSection(tester, player);
    // 分节内容超出一屏，先滚到开关再点。
    await tester.ensureVisible(find.text('手环 / AVRCP 歌词同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手环 / AVRCP 歌词同步'));
    await tester.pump();

    expect(player.titleSyncToggles, [true]);
  });
}
