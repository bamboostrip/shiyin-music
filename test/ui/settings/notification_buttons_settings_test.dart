// 设置页「通知栏按钮」（issue #34）的 widget 测试：
//   1. 瓦片回显当前左右槽位；
//   2. 弹窗里选完点「确定」才落盘，并同步进程内值（通知按钮据此立即重发）；
//   3. 选另一侧正占用的按钮时自动对调，两侧都落盘；
//   4. 点「取消」不改任何东西；
//   5. 入口只在 Android 非车机形态显示（避免「看得到但无效」）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/notification_button_slots.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/settings/notification_buttons_settings.dart';
import 'package:shiyin_music/ui/settings/playback_settings_section.dart';

/// 本节 build 会读的只读状态全部给默认值（仓库单测禁止真实音频引擎）。
class _FakePlayerController extends Fake implements PlayerController {
  @override
  AudioQuality get audioQuality => AudioQuality.standard;

  @override
  bool get smartQualityEnabled => false;

  @override
  bool get isAudioEffectsSupported => false;

  @override
  bool get loudnessEnabled => false;

  @override
  bool get searchPlayReplaceQueue => false;

  @override
  bool get autoPlayOnStartupEnabled => false;

  @override
  bool get autoPlayOnDeviceConnected => false;

  @override
  bool get keepScreenOnEnabled => false;

  @override
  bool get audioInterruptionEnabled => false;

  @override
  bool get autoResumeAfterInterruption => false;

  @override
  bool get autoPauseOnDeviceDisconnect => false;

  @override
  bool get allowCellularPrecache => false;

  @override
  bool get addListeningTimeEnabled => false;

  @override
  bool get isDesktopLyricsSupported => false;

  @override
  bool get isBluetoothLyricsSupported => false;

  @override
  bool get showUnavailableSongs => false;
}

class _FakeAuthController extends Fake implements AuthController {}

class _FakeMusicApi extends Fake implements MusicApi {}

Finder _radio(String label, {required bool left}) => left
    ? find.widgetWithText(RadioListTile<NotificationSlotAction>, label).first
    : find.widgetWithText(RadioListTile<NotificationSlotAction>, label).last;

/// 弹窗里某一侧当前选中的按钮。选中态挂在 [RadioGroup] 上（包在组里的
/// RadioListTile 自身的 groupValue 恒为 null），左侧组先构建。
NotificationSlotAction _selectedIn(WidgetTester tester, {required bool left}) {
  final groups = tester
      .widgetList<RadioGroup<NotificationSlotAction>>(
        find.byType(RadioGroup<NotificationSlotAction>),
      )
      .toList();
  return (left ? groups.first : groups.last).groupValue!;
}

Future<void> _pumpTile(WidgetTester tester) => tester.pumpWidget(
  const MaterialApp(home: Scaffold(body: NotificationButtonsSettings())),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationButtonSlots.current.value = NotificationButtonSlots.defaults;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  group('NotificationButtonsSettings 瓦片与弹窗', () {
    testWidgets('瓦片回显当前左右槽位（默认：收藏 · 桌面歌词）', (tester) async {
      await _pumpTile(tester);
      await tester.pumpAndSettle();

      expect(find.text('通知栏按钮'), findsOneWidget);
      expect(find.text('左侧：收藏 · 右侧：桌面歌词'), findsOneWidget);
    });

    testWidgets('选左侧为「播放模式」并确定：落盘、进程内值更新、瓦片回显', (tester) async {
      await _pumpTile(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('通知栏按钮'));
      await tester.pumpAndSettle();
      // 只在弹窗里改，没点确定之前什么都不落盘。
      await tester.tap(_radio('播放模式', left: true));
      await tester.pumpAndSettle();
      expect(
        NotificationButtonSlots.current.value,
        NotificationButtonSlots.defaults,
      );

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(NotificationButtonSlots.leftKey), 'playback_mode');
      expect(
        prefs.getString(NotificationButtonSlots.rightKey),
        'desktop_lyrics',
      );
      expect(
        NotificationButtonSlots.current.value,
        const NotificationButtonSlots(
          left: NotificationSlotAction.playbackMode,
          right: NotificationSlotAction.desktopLyrics,
        ),
      );
      expect(find.text('左侧：播放模式 · 右侧：桌面歌词'), findsOneWidget);
    });

    testWidgets('右侧选了左侧正占用的「收藏」：自动对调，两侧都落盘', (tester) async {
      await _pumpTile(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('通知栏按钮'));
      await tester.pumpAndSettle();
      expect(_selectedIn(tester, left: true), NotificationSlotAction.like);
      await tester.tap(_radio('收藏', left: false));
      await tester.pumpAndSettle();
      // 弹窗里预览即所见：左侧已经变成原来的右侧按钮，右侧变成本次选的。
      expect(
        _selectedIn(tester, left: true),
        NotificationSlotAction.desktopLyrics,
      );
      expect(_selectedIn(tester, left: false), NotificationSlotAction.like);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(NotificationButtonSlots.leftKey),
        'desktop_lyrics',
      );
      expect(prefs.getString(NotificationButtonSlots.rightKey), 'like');
      expect(find.text('左侧：桌面歌词 · 右侧：收藏'), findsOneWidget);
    });

    testWidgets('点「取消」不落盘也不改瓦片', (tester) async {
      await _pumpTile(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('通知栏按钮'));
      await tester.pumpAndSettle();
      await tester.tap(_radio('不显示', left: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(NotificationButtonSlots.leftKey), isNull);
      expect(prefs.getString(NotificationButtonSlots.rightKey), isNull);
      expect(
        NotificationButtonSlots.current.value,
        NotificationButtonSlots.defaults,
      );
      expect(find.text('左侧：收藏 · 右侧：桌面歌词'), findsOneWidget);
    });
  });

  group('PlaybackSettingsSection 里的入口可见性', () {
    /// 按平台覆盖调试变量跑 [body]。必须在测试体返回前还原：框架在 tearDown
    /// （含 addTearDown）之前就会校验 foundation 调试变量已复位。
    Future<void> overrideForm({
      required bool desktop,
      required TargetPlatform platform,
      required Future<void> Function() body,
    }) async {
      debugDesktopFormFactorOverride = desktop;
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body();
      } finally {
        debugDesktopFormFactorOverride = null;
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<void> pumpSection(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaybackSettingsSection(
              api: _FakeMusicApi(),
              auth: _FakeAuthController(),
              player: _FakePlayerController(),
              onSelectDefaultAudioQuality: () {},
              showLyricPageSkipButtons: false,
            ),
          ),
        ),
      ),
    );

    testWidgets('手机形态的 Android 上显示入口', (tester) async {
      ThemeController();
      await overrideForm(
        desktop: false,
        platform: TargetPlatform.android,
        body: () async {
          await pumpSection(tester);
          await tester.pumpAndSettle();

          expect(find.text('通知栏按钮'), findsOneWidget);
        },
      );
    });

    testWidgets('桌面形态不显示（桌面没有 Android 媒体通知）', (tester) async {
      ThemeController();
      await overrideForm(
        desktop: true,
        platform: TargetPlatform.android,
        body: () async {
          await pumpSection(tester);
          await tester.pumpAndSettle();

          expect(find.text('通知栏按钮'), findsNothing);
        },
      );
    });

    testWidgets('车机模式不显示（车机不注入自定义按钮）', (tester) async {
      final theme = ThemeController();
      await theme.setCarModeEnabled(true);
      await overrideForm(
        desktop: false,
        platform: TargetPlatform.android,
        body: () async {
          await pumpSection(tester);
          await tester.pumpAndSettle();

          expect(find.text('通知栏按钮'), findsNothing);
        },
      );
    });

    testWidgets('iOS 不显示', (tester) async {
      ThemeController();
      await overrideForm(
        desktop: false,
        platform: TargetPlatform.iOS,
        body: () async {
          await pumpSection(tester);
          await tester.pumpAndSettle();

          expect(find.text('通知栏按钮'), findsNothing);
        },
      );
    });
  });
}
