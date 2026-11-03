// 设置页「播放」分节里「显示已下架/无版权歌曲」开关：
//   1. 默认关闭，文案说明「不显示、仅提示数量」；
//   2. 打开后文案说明「置灰显示、点击不会播放」；
//   3. 点击开关调用控制器 setter（落盘/通知由 controller 单测覆盖）。
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
  bool showUnavailableSongsValue = false;
  final List<bool> showUnavailableSongsToggles = <bool>[];

  @override
  bool get showUnavailableSongs => showUnavailableSongsValue;

  @override
  Future<void> setShowUnavailableSongs(bool enabled) async {
    showUnavailableSongsToggles.add(enabled);
    showUnavailableSongsValue = enabled;
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
  bool get bluetoothLyricsEnabled => false;

  @override
  bool get bluetoothLyricsTitleSyncEnabled => false;

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
  testWidgets('默认为关：不显示已下架歌曲，仅提示数量', (tester) async {
    final player = _FakePlayerController();

    await _pumpSection(tester, player);

    expect(find.text('显示已下架/无版权歌曲'), findsOneWidget);
    expect(find.text('不显示这些歌曲，仅在列表上方提示数量'), findsOneWidget);
    final switchTile = tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(
          of: find.text('显示已下架/无版权歌曲'),
          matching: find.byType(SettingsSwitchTile),
        ),
        matching: find.byType(Switch),
      ),
    );
    expect(switchTile.value, isFalse, reason: '默认隐藏，保持当前行为');
  });

  testWidgets('开启后文案说明置灰显示且不可播放', (tester) async {
    final player = _FakePlayerController()..showUnavailableSongsValue = true;

    await _pumpSection(tester, player);

    expect(find.text('在歌单与专辑中置灰显示，点击不会播放'), findsOneWidget);
    final switchTile = tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(
          of: find.text('显示已下架/无版权歌曲'),
          matching: find.byType(SettingsSwitchTile),
        ),
        matching: find.byType(Switch),
      ),
    );
    expect(switchTile.value, isTrue);
  });

  testWidgets('点击开关调用控制器 setter（落盘与通知由 controller 负责）', (tester) async {
    final player = _FakePlayerController();

    await _pumpSection(tester, player);
    // 分节内容超出一屏，先滚到开关再点。
    await tester.ensureVisible(find.text('显示已下架/无版权歌曲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示已下架/无版权歌曲'));
    await tester.pump();

    expect(player.showUnavailableSongsToggles, [true]);
  });
}
