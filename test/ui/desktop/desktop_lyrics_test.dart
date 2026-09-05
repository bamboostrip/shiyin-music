import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/desktop_lyrics_service.dart';
import 'package:shiyin_music/services/windows_desktop_lyrics_bridge.dart';
import 'package:shiyin_music/ui/desktop/lyrics_overlay_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowsDesktopLyricsBridge dimensions', () {
    test('悬浮窗尺寸更新为宽 780、高 88', () {
      expect(WindowsDesktopLyricsBridge.overlayWidth, 780);
      expect(WindowsDesktopLyricsBridge.overlayHeight, 88);
    });
  });

  group('DesktopLyricsSettings', () {
    test('默认配置为透明悬浮与标准字号', () {
      const settings = DesktopLyricsSettings();
      expect(settings.opacity, 0.0);
      expect(settings.locked, isFalse);
      expect(settings.passthrough, isFalse);
      expect(settings.textColor, 0xFFFFFFFF);
      expect(settings.fontSize, 24.0);
    });

    test('序列化与反序列化完整保持字段', () {
      const original = DesktopLyricsSettings(
        opacity: 0.8,
        locked: true,
        passthrough: true,
        textColor: 0xFFE0E0E0,
        backgroundColor: 0xFF141823,
        fontSize: 22.0,
      );

      final map = original.toMap();
      final restored = DesktopLyricsSettings.fromMap(map);

      expect(restored.opacity, original.opacity);
      expect(restored.locked, original.locked);
      expect(restored.passthrough, original.passthrough);
      expect(restored.textColor, original.textColor);
      expect(restored.backgroundColor, original.backgroundColor);
      expect(restored.fontSize, original.fontSize);
    });

    test('兼容旧持久化字段：passthrough 仅解析保留，缺失字段取默认值', () {
      // 旧版本 JSON：locked + passthrough 同时存在。
      final legacy = DesktopLyricsSettings.fromMap(const {
        'opacity': 0.5,
        'locked': true,
        'passthrough': true,
        'fontSize': 20.0,
      });
      expect(legacy.locked, isTrue);
      expect(legacy.passthrough, isTrue);
      expect(legacy.opacity, 0.5);
      expect(legacy.fontSize, 20.0);

      // 字段缺失（更早版本）时不抛异常，逐项取默认值。
      final minimal = DesktopLyricsSettings.fromMap(const {'locked': true});
      expect(minimal.locked, isTrue);
      expect(minimal.passthrough, isFalse);
      expect(minimal.opacity, 0.0);
      expect(minimal.fontSize, 24.0);
    });

    test('相等性与 copyWith（设置页监听外部锁定变化的基础）', () {
      const locked = DesktopLyricsSettings(locked: true);
      expect(const DesktopLyricsSettings(locked: true), locked);
      expect(const DesktopLyricsSettings(locked: false, passthrough: true),
          isNot(locked));

      final unlocked = locked.copyWith(locked: false);
      expect(unlocked.locked, isFalse);
      expect(unlocked, const DesktopLyricsSettings());
      // passthrough 字段保留解析，但 UI 已无该开关；锁定语义吸收穿透。
      expect(locked.copyWith(locked: false).passthrough, isFalse);
    });
  });

  group('DesktopLyricsService PlaybackAction', () {
    const channel = MethodChannel('kgka_music_hl/desktop_lyrics');

    test('支持注册与触发 controlPlayback 播控指令', () async {
      final service = DesktopLyricsService();
      final receivedActions = <String>[];

      service.setPlaybackActionHandler((action) {
        receivedActions.add(action);
      });

      // 模拟平台通道下发播控事件
      final binding = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();

      await binding.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('controlPlayback', 'previous')),
        (ByteData? data) {},
      );
      await binding.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('controlPlayback', 'togglePlay')),
        (ByteData? data) {},
      );
      await binding.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('controlPlayback', 'next')),
        (ByteData? data) {},
      );

      expect(receivedActions, ['previous', 'togglePlay', 'next']);

      service.setPlaybackActionHandler(null);
    });
  });

  group('isLyricsOverlayWindowArgs', () {
    test('正确识别 multi_window 子窗口启动参数', () {
      expect(isLyricsOverlayWindowArgs(['multi_window', '1']), isTrue);
      expect(isLyricsOverlayWindowArgs(['multi_window', '1', '{}']), isTrue);
      expect(isLyricsOverlayWindowArgs(['multi_window']), isFalse);
      expect(isLyricsOverlayWindowArgs(['main']), isFalse);
      expect(isLyricsOverlayWindowArgs([]), isFalse);
    });
  });

  group('WindowsDesktopLyricsBridge 就绪门控', () {
    // 与 desktop_multi_window 0.2.1 源码（src/channels.dart）一致：
    // - mixin.one/flutter_multi_window：窗口控制通道（createWindow/setFrame/close）。
    // - mixin.one/flutter_multi_window_channel：窗口间消息通道
    //   （主->子 invokeMethod；子->主经 setMethodHandler 分发，
    //   入站信封为 {fromWindowId, arguments}）。
    const multiWindowChannel = MethodChannel('mixin.one/flutter_multi_window');
    const windowEventChannel =
        MethodChannel('mixin.one/flutter_multi_window_channel');
    const fakeWindowId = 42;

    /// 记录主窗 -> 子窗的全部消息（即被门控的推送路径）。
    final outgoing = <MethodCall>[];

    void setUpMultiWindowMocks(TestDefaultBinaryMessengerBinding binding) {
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(multiWindowChannel, (call) async {
        // createWindow 返回固定窗口ID，其余窗口控制调用一律成功。
        return call.method == 'createWindow' ? fakeWindowId : null;
      });
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(windowEventChannel, (call) async {
        outgoing.add(call);
        return null;
      });
    }

    void clearMultiWindowMocks(TestDefaultBinaryMessengerBinding binding) {
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(multiWindowChannel, null);
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(windowEventChannel, null);
      outgoing.clear();
    }

    /// 模拟子引擎经 windowEventChannel 向主窗上报消息
    /// （desktop_multi_window 包装层从信封取 fromWindowId/arguments）。
    Future<void> simulateChildMessage(
      TestDefaultBinaryMessengerBinding binding,
      String method, [
      dynamic arguments,
    ]) async {
      const codec = StandardMethodCodec();
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        windowEventChannel.name,
        codec.encodeMethodCall(MethodCall(method, <String, dynamic>{
          'fromWindowId': fakeWindowId,
          'arguments': arguments,
        })),
        (ByteData? data) {},
      );
    }

    List<MethodCall> pushesOf(String method) =>
        outgoing.where((c) => c.method == method).toList();

    dynamic pushPayload(MethodCall call) =>
        (call.arguments as Map)['arguments'] as Map;

    test('overlayReady 之前 updateLyrics 不 invoke 通道，就绪后补发缓存歌词与设置',
        () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      setUpMultiWindowMocks(binding);
      addTearDown(() => clearMultiWindowMocks(binding));

      final bridge = WindowsDesktopLyricsBridge();
      final shown = await bridge.show(title: '标题', artist: '歌手');
      expect(shown, isTrue);
      expect(bridge.isVisible, isTrue);

      // 冷启动窗口期（子引擎未上报 overlayReady）：推送只更新缓存，
      // 不产生任何通道调用，不再触发 MissingPluginException。
      await bridge.updateLyrics(current: '第一句', next: '第二句');
      await bridge.updatePlayState(isPlaying: true);
      await bridge.updateSettings(const DesktopLyricsSettings(fontSize: 28.0));
      expect(pushesOf('updateLyric'), isEmpty);
      expect(pushesOf('updateSettings'), isEmpty);

      // 子引擎完成初始化并注册 handler 后上报 overlayReady。
      await simulateChildMessage(binding, 'overlayReady');

      // 就绪后主窗补发缓存歌词与设置。
      final lyricPushes = pushesOf('updateLyric');
      expect(lyricPushes, hasLength(1));
      final lyricPayload = pushPayload(lyricPushes.single);
      expect(lyricPayload['current'], '第一句');
      expect(lyricPayload['next'], '第二句');
      expect(lyricPayload['isPlaying'], isTrue);

      final settingsPushes = pushesOf('updateSettings');
      expect(settingsPushes, hasLength(1));
      expect((pushPayload(settingsPushes.single)['fontSize'] as num).toDouble(),
          28.0);
    });

    test('windowClosed 复位门控，重建子窗需新一轮 overlayReady 握手', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      setUpMultiWindowMocks(binding);
      addTearDown(() => clearMultiWindowMocks(binding));

      final bridge = WindowsDesktopLyricsBridge();
      await bridge.show(title: '标题', artist: '歌手');

      // 首轮握手前：推送只更新缓存，不产生通道调用。
      await bridge.updateLyrics(current: 'A', next: 'B');
      expect(pushesOf('updateLyric'), isEmpty);

      // 首轮握手：补发当时缓存。
      await simulateChildMessage(binding, 'overlayReady');
      expect(pushesOf('updateLyric'), hasLength(1));
      expect(pushPayload(pushesOf('updateLyric').single)['current'], 'A');

      // 用户手动关闭子窗：就绪门控与可见性同步复位。
      await simulateChildMessage(binding, 'windowClosed');
      expect(bridge.isVisible, isFalse);

      // 重新展示（重建子窗）：新引擎握手前推送仍被门控（缓存已更新为 C）。
      final reshow = await bridge.show(title: '标题', artist: '歌手');
      expect(reshow, isTrue);
      await bridge.updateLyrics(current: 'C', next: 'D');
      expect(pushesOf('updateLyric'), hasLength(1));

      // 新一轮握手后补发最新缓存。
      await simulateChildMessage(binding, 'overlayReady');
      expect(pushesOf('updateLyric'), hasLength(2));
      final latest = pushesOf('updateLyric').last;
      expect(pushPayload(latest)['current'], 'C');
    });

    test('已展示时重复 show 复用旧窗，就绪状态不被误重置', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      setUpMultiWindowMocks(binding);
      addTearDown(() => clearMultiWindowMocks(binding));

      final bridge = WindowsDesktopLyricsBridge();
      await bridge.show(title: '标题', artist: '歌手');
      // 首轮握手：空缓存也照常补发一次（以此次数为基线）。
      await simulateChildMessage(binding, 'overlayReady');
      final baseline = pushesOf('updateLyric').length;
      expect(baseline, 1);

      await bridge.updateLyrics(current: '第一句', next: '第二句');
      expect(pushesOf('updateLyric').length, baseline + 1);

      // 重复 show：走复用分支并直接推送（若误重置门控，此处不会再推送）。
      final again = await bridge.show(title: '标题', artist: '歌手');
      expect(again, isTrue);
      expect(pushesOf('updateLyric').length, baseline + 2);
      expect(pushPayload(pushesOf('updateLyric').last)['current'], '第一句');
    });

    test('setLyricsLocked 转发回调；主窗处理后的 updateSettings 回推子窗',
        () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      setUpMultiWindowMocks(binding);
      addTearDown(() => clearMultiWindowMocks(binding));

      final reported = <bool>[];
      final bridge = WindowsDesktopLyricsBridge(onLockChanged: reported.add);
      await bridge.show(title: '标题', artist: '歌手');
      await simulateChildMessage(binding, 'overlayReady');
      outgoing.clear();

      // 子窗工具栏锁定按钮上报 setLyricsLocked=true → 主窗回调。
      await simulateChildMessage(binding, 'setLyricsLocked', true);
      expect(reported, [true]);

      // 模拟主窗侧（PlayerController）处理回调：落盘 + 回推新设置，
      // 子窗不本地直改锁定状态，统一经 updateSettings 重建。
      await bridge.updateSettings(const DesktopLyricsSettings(locked: true));
      final pushes = pushesOf('updateSettings');
      expect(pushes, hasLength(1));
      expect(pushPayload(pushes.single)['locked'], isTrue);

      // 子窗请求解锁同样转发。
      await simulateChildMessage(binding, 'setLyricsLocked', false);
      expect(reported, [true, false]);
    });
  });

  group('锁定态纯歌词子树（QQ 音乐式全穿透）', () {
    final contentKey = GlobalKey();

    Future<void> pumpContent(
      WidgetTester tester, {
      required DesktopLyricsSettings settings,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: KeyedSubtree(
            key: contentKey,
            child: DesktopLyricsOverlayContent(
              settings: settings,
              current: '第一句歌词',
              next: '第二句歌词',
              isPlaying: true,
              onControlPlayback: (_) {},
              onToggleLock: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('锁定：只渲染歌词文字，无工具栏与任何 hover 组件',
        (tester) async {
      await pumpContent(
        tester,
        settings: const DesktopLyricsSettings(locked: true),
      );

      // 歌词文字仍在（含下一句）。
      expect(find.text('第一句歌词'), findsOneWidget);
      expect(find.text('第二句歌词'), findsOneWidget);

      // 无任何依赖 hover 的窗内 UI：工具栏（Tooltip/图标）、MouseRegion。
      // （限定在悬浮窗内容子树内：MaterialApp 自带框架级 MouseRegion。）
      final content = find.byKey(contentKey);
      expect(
        find.descendant(of: content, matching: find.byType(Tooltip)),
        findsNothing,
      );
      expect(
        find.descendant(of: content, matching: find.byType(MouseRegion)),
        findsNothing,
      );
      // 工具栏全部图标（播放/锁定/关闭）在锁定子树中一律不存在。
      const toolbarIcons = [
        Icons.lock_open_rounded,
        Icons.lock_rounded,
        Icons.close_rounded,
        Icons.play_arrow_rounded,
        Icons.pause_rounded,
        Icons.skip_previous_rounded,
        Icons.skip_next_rounded,
      ];
      expect(
        find.descendant(
          of: content,
          matching: find.byWidgetPredicate(
            (w) => w is Icon && toolbarIcons.contains(w.icon),
          ),
        ),
        findsNothing,
      );
    });

    testWidgets('未锁定：保留工具栏与锁按钮（悬停 UI 只属于非锁定态）',
        (tester) async {
      await pumpContent(tester, settings: const DesktopLyricsSettings());

      expect(find.text('第一句歌词'), findsOneWidget);
      expect(find.byType(Tooltip), findsWidgets);
      expect(find.byIcon(Icons.lock_open_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });
  });

  group('applyDesktopLyricsPassthrough 锁定即穿透', () {
    const windowManagerChannel = MethodChannel('window_manager');

    test('locked ⇒ setIgnoreMouseEvents(true)；解锁恢复 false', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      final ignoreCalls = <bool>[];
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(windowManagerChannel, (call) async {
        if (call.method == 'setIgnoreMouseEvents') {
          final args = call.arguments as Map;
          ignoreCalls.add(args['ignore'] as bool);
        }
        return null;
      });
      addTearDown(() => binding.defaultBinaryMessenger
          .setMockMethodCallHandler(windowManagerChannel, null));

      // 锁定即全穿透：不再受旧 passthrough 字段影响。
      await applyDesktopLyricsPassthrough(
        const DesktopLyricsSettings(locked: true, passthrough: false),
      );
      await applyDesktopLyricsPassthrough(
        const DesktopLyricsSettings(locked: true, passthrough: true),
      );
      // 解锁恢复鼠标事件。
      await applyDesktopLyricsPassthrough(
        const DesktopLyricsSettings(locked: false),
      );

      expect(ignoreCalls, [true, true, false]);
    });
  });

  group('OverlayPassthroughScheduler（穿透延迟到窗口显示后）', () {
    test('显示前只登记不施加，markShown 后 flushPending 施加最后一笔', () async {
      final applied = <bool>[];
      final scheduler = OverlayPassthroughScheduler(
        onApply: (settings) async => applied.add(settings.locked),
      );

      // 窗口隐藏期间（插件创建子窗后默认 SW_HIDE）到达的设置：
      // 只登记，绝不触碰原生层（隐藏期加 WS_EX_LAYERED 会让内容面
      // 永久空白——锁定重开后歌词消失的根因）。
      await scheduler.apply(const DesktopLyricsSettings(locked: true));
      await scheduler.apply(const DesktopLyricsSettings(locked: false));
      await scheduler.apply(const DesktopLyricsSettings(locked: true));
      expect(applied, isEmpty);

      scheduler.markShown();
      await scheduler.flushPending();
      expect(applied, [true]);
    });

    test('markShown 之后的 apply 立即施加（工具栏解锁/重锁路径）', () async {
      final applied = <bool>[];
      final scheduler = OverlayPassthroughScheduler(
        onApply: (settings) async => applied.add(settings.locked),
      );
      scheduler.markShown();

      await scheduler.apply(const DesktopLyricsSettings(locked: true));
      await scheduler.apply(const DesktopLyricsSettings(locked: false));
      expect(applied, [true, false]);

      // 无遗留 pending。
      await scheduler.flushPending();
      expect(applied, [true, false]);
    });
  });

  group('歌词主体高度自适应（防溢出黄黑条纹）', () {
    // 悬浮窗固定 780x88：系统字体缩放（make text bigger）或设置页大字号
    // （上限 48sp）下两行总高可能超过窗高。修复前 Column 直接溢出，
    // 窗口底部常驻 RenderFlex 黄黑条纹。
    Future<void> pumpOverlay(
      WidgetTester tester, {
      required DesktopLyricsSettings settings,
      double textScale = 1.0,
    }) async {
      tester.view.physicalSize = const Size(
        WindowsDesktopLyricsBridge.overlayWidth,
        WindowsDesktopLyricsBridge.overlayHeight,
      );
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(
              WindowsDesktopLyricsBridge.overlayWidth,
              WindowsDesktopLyricsBridge.overlayHeight,
            ),
            textScaler: TextScaler.linear(textScale),
          ),
          child: MaterialApp(
            home: DesktopLyricsOverlayContent(
              settings: settings,
              current: '当前句歌词内容',
              next: '下一句歌词内容',
              isPlaying: true,
              onControlPlayback: (_) {},
              onToggleLock: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('锁定态 textScale=$scale 不溢出', (tester) async {
        await pumpOverlay(
          tester,
          settings: const DesktopLyricsSettings(locked: true),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('锁定态设置页最大字号 48sp 不溢出', (tester) async {
      await pumpOverlay(
        tester,
        settings: const DesktopLyricsSettings(locked: true, fontSize: 48),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('当前句歌词内容'), findsOneWidget);
    });

    testWidgets('未锁定态悬停卡片内同样不溢出（48sp + 1.5 倍缩放）',
        (tester) async {
      await pumpOverlay(
        tester,
        settings: const DesktopLyricsSettings(locked: false, fontSize: 48),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('锁定态歌词文字无双黄下划线（decoration 为 none 且具备 Material 祖先）',
        (tester) async {
      await pumpOverlay(
        tester,
        settings: const DesktopLyricsSettings(locked: true),
      );
      final textWidget = tester.widget<Text>(find.text('当前句歌词内容'));
      expect(textWidget.style?.decoration, TextDecoration.none);
      expect(find.byType(Material), findsWidgets);
    });
  });
}
