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
  });
}
