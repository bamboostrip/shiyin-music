import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/services/desktop_lyrics_service.dart';
import 'package:shiyin_music/services/windows_desktop_lyrics_bridge.dart';
import 'package:shiyin_music/ui/desktop/lyrics_karaoke_line.dart';
import 'package:shiyin_music/ui/desktop/lyrics_overlay_window.dart';

/// 快捷菜单测试假具：窗口 780x400 画布、窗口原点 (0,0)，
/// hover 由光标轮询 mock 驱动（未锁定态命中测试不再走 MouseRegion）。
class _QuickSettingsHarness {
  _QuickSettingsHarness({required this.moveCursor});
  final void Function(Offset pos) moveCursor;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowsDesktopLyricsBridge dimensions', () {
    test('悬浮窗尺寸为宽 780、常驻高 336（菜单带 212 + 卡片带 124）', () {
      expect(WindowsDesktopLyricsBridge.overlayWidth, 780);
      // 历史 88 高度下 30px 按钮（y2~36）与双行歌词（约 y20~74）恒重叠
      // 约 16px，故卡片带顶部辟出工具栏专属带（36 + 88 = 124）。
      expect(WindowsDesktopLyricsBridge.lyricsTopInset, 36);
      expect(WindowsDesktopLyricsBridge.overlayLyricsHeight, 88);
      expect(WindowsDesktopLyricsBridge.overlayHeight, 124);
      // 常驻菜单带 + 卡片带 = 窗口常驻总高度：菜单收展纯 Flutter 动画，
      // 窗口不再 resize（消除 DWM 拉伸中间帧导致的"点设置闪一下"）。
      // 菜单带 212：新增「歌词进度」行后比历史 172 高一档。
      expect(WindowsDesktopLyricsBridge.overlayMenuPanelHeight, 212);
      expect(WindowsDesktopLyricsBridge.overlayWindowHeight, 336);
    });
  });

  group('DesktopLyricsSettings', () {
    test('默认配置为透明悬浮、标准字号与默认布局/色彩', () {
      const settings = DesktopLyricsSettings();
      expect(settings.opacity, 0.0);
      expect(settings.locked, isFalse);
      expect(settings.passthrough, isFalse);
      expect(settings.textColor, 0xFF00BFFF);
      expect(settings.unplayedTextColor, 0xFF00BFFF);
      expect(settings.playedTextColor, 0xFFFFD700);
      expect(settings.fontSize, 24.0);
      // 桌面默认双行两端对齐（split）：正在唱的上行居左、下一句下行居右。
      expect(settings.singleLine, isFalse);
      // 默认左右分离：单行下与居中渲染一致，双行下即 QQ 音乐经典对角交错。
      expect(settings.alignment, DesktopLyricsAlignment.split);
      expect(settings.textOpacity, 1.0);
      expect(settings.backgroundColor, 0xFF1A1A2E);
    });

    test('序列化与反序列化完整保持所有新旧字段', () {
      const original = DesktopLyricsSettings(
        opacity: 0.8,
        locked: true,
        passthrough: true,
        backgroundColor: 0xFF141823,
        fontSize: 22.0,
        singleLine: false,
        alignment: 'left',
        textOpacity: 0.85,
        playedTextColor: 0xFFFF0000,
        unplayedTextColor: 0xFF00FF00,
      );

      final map = original.toMap();
      expect(map['singleLine'], isFalse);
      expect(map['alignment'], 'left');
      expect(map['textOpacity'], 0.85);
      expect(map['playedTextColor'], 0xFFFF0000);
      expect(map['unplayedTextColor'], 0xFF00FF00);
      expect(map['textColor'], 0xFF00FF00);

      final restored = DesktopLyricsSettings.fromMap(map);

      expect(restored.opacity, original.opacity);
      expect(restored.locked, original.locked);
      expect(restored.passthrough, original.passthrough);
      expect(restored.backgroundColor, original.backgroundColor);
      expect(restored.fontSize, original.fontSize);
      expect(restored.singleLine, original.singleLine);
      expect(restored.alignment, original.alignment);
      expect(restored.textOpacity, original.textOpacity);
      expect(restored.playedTextColor, original.playedTextColor);
      expect(restored.unplayedTextColor, original.unplayedTextColor);
      expect(restored.textColor, original.unplayedTextColor);
      expect(restored, original);
    });

    test(
      '兼容旧持久化字段：passthrough 保留，缺失字段取默认值，unplayedTextColor 回退到 textColor',
      () {
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
        expect(legacy.singleLine, isFalse);
        expect(legacy.alignment, DesktopLyricsAlignment.split);
        expect(legacy.textOpacity, 1.0);
        expect(legacy.playedTextColor, 0xFFFFD700);
        expect(legacy.unplayedTextColor, 0xFF00BFFF);

        // 旧配置仅含 textColor：unplayedTextColor 自动回退并同步 textColor
        final legacyTextColor = DesktopLyricsSettings.fromMap(const {
          'textColor': 0xFF123456,
        });
        expect(legacyTextColor.unplayedTextColor, 0xFF123456);
        expect(legacyTextColor.textColor, 0xFF123456);

        // 同时包含 unplayedTextColor 与 textColor 时，unplayedTextColor 优先
        final dualColorMap = DesktopLyricsSettings.fromMap(const {
          'textColor': 0xFF111111,
          'unplayedTextColor': 0xFF222222,
        });
        expect(dualColorMap.unplayedTextColor, 0xFF222222);
        expect(dualColorMap.textColor, 0xFF222222);

        // 字段全缺失时不抛异常，逐项取默认值。
        final minimal = DesktopLyricsSettings.fromMap(const {'locked': true});
        expect(minimal.locked, isTrue);
        expect(minimal.passthrough, isFalse);
        expect(minimal.opacity, 0.0);
        expect(minimal.fontSize, 24.0);
        expect(minimal.singleLine, isFalse);
        expect(minimal.alignment, DesktopLyricsAlignment.split);
        expect(minimal.textOpacity, 1.0);
        expect(minimal.playedTextColor, 0xFFFFD700);
        expect(minimal.unplayedTextColor, 0xFF00BFFF);
      },
    );

    test('相等性与 copyWith 完整覆盖所有新旧字段', () {
      const base = DesktopLyricsSettings();

      // copyWith 各个新字段
      expect(base.copyWith(singleLine: true).singleLine, isTrue);
      expect(base.copyWith(alignment: 'right').alignment, 'right');
      expect(base.copyWith(textOpacity: 0.5).textOpacity, 0.5);
      expect(
        base.copyWith(playedTextColor: 0xFF123456).playedTextColor,
        0xFF123456,
      );
      expect(
        base.copyWith(unplayedTextColor: 0xFF654321).unplayedTextColor,
        0xFF654321,
      );
      expect(base.copyWith(textColor: 0xFF778899).textColor, 0xFF778899);
      expect(
        base.copyWith(textColor: 0xFF778899).unplayedTextColor,
        0xFF778899,
      );

      // 相等性对比
      final modifiedSingleLine = base.copyWith(singleLine: true);
      expect(modifiedSingleLine, isNot(base));
      expect(modifiedSingleLine.hashCode, isNot(base.hashCode));

      final modifiedAlignment = base.copyWith(alignment: 'left');
      expect(modifiedAlignment, isNot(base));
      expect(modifiedAlignment.hashCode, isNot(base.hashCode));

      final modifiedTextOpacity = base.copyWith(textOpacity: 0.8);
      expect(modifiedTextOpacity, isNot(base));
      expect(modifiedTextOpacity.hashCode, isNot(base.hashCode));

      final modifiedPlayedColor = base.copyWith(playedTextColor: 0xFF111111);
      expect(modifiedPlayedColor, isNot(base));
      expect(modifiedPlayedColor.hashCode, isNot(base.hashCode));

      final modifiedUnplayedColor = base.copyWith(
        unplayedTextColor: 0xFF222222,
      );
      expect(modifiedUnplayedColor, isNot(base));
      expect(modifiedUnplayedColor.hashCode, isNot(base.hashCode));

      const locked = DesktopLyricsSettings(locked: true);
      expect(const DesktopLyricsSettings(locked: true), locked);
      expect(
        const DesktopLyricsSettings(locked: false, passthrough: true),
        isNot(locked),
      );

      final unlocked = locked.copyWith(locked: false);
      expect(unlocked.locked, isFalse);
      expect(unlocked, const DesktopLyricsSettings());
      // passthrough 字段保留解析，但 UI 已无该开关；锁定语义吸收穿透。
      expect(locked.copyWith(locked: false).passthrough, isFalse);
    });
  });

  group('DesktopLyricsColorScheme 歌词配色方案', () {
    test('内置方案非空、命名唯一，且歌词色与高亮色两两不同', () {
      expect(DesktopLyricsColorScheme.presets, isNotEmpty);

      final names = DesktopLyricsColorScheme.presets.map((s) => s.name);
      expect(names.toSet().length, DesktopLyricsColorScheme.presets.length);

      for (final scheme in DesktopLyricsColorScheme.presets) {
        // 两色相同会让卡拉OK进度完全不可见——方案必须保证对比。
        expect(
          scheme.unplayedTextColor,
          isNot(scheme.playedTextColor),
          reason: '方案「${scheme.name}」歌词色与高亮色相同',
        );
      }
    });

    test('首个方案即出厂默认配色，命中默认设置', () {
      final first = DesktopLyricsColorScheme.presets.first;
      const defaults = DesktopLyricsSettings();
      expect(first.unplayedTextColor, defaults.unplayedTextColor);
      expect(first.playedTextColor, defaults.playedTextColor);
      expect(DesktopLyricsColorScheme.matchFor(defaults)?.name, first.name);
    });

    test('matchFor：命中方案返回方案，自定义颜色返回 null', () {
      final gilded = DesktopLyricsColorScheme.presets[1];
      final applied = const DesktopLyricsSettings().copyWith(
        unplayedTextColor: gilded.unplayedTextColor,
        playedTextColor: gilded.playedTextColor,
      );
      expect(DesktopLyricsColorScheme.matchFor(applied)?.name, '鎏金');

      // 只换其中一色（设置页细调过）即不再命中任何方案。
      final halfCustom = applied.copyWith(playedTextColor: 0xFF123456);
      expect(DesktopLyricsColorScheme.matchFor(halfCustom), isNull);
      final allCustom = const DesktopLyricsSettings().copyWith(
        unplayedTextColor: 0xFF111111,
        playedTextColor: 0xFF222222,
      );
      expect(DesktopLyricsColorScheme.matchFor(allCustom), isNull);
    });
  });

  group('DesktopLyricsService PlaybackAction', () {
    const channel = MethodChannel('shiyin_music/desktop_lyrics');

    test('支持注册与触发 controlPlayback 播控指令', () async {
      final service = DesktopLyricsService();
      final receivedActions = <String>[];

      service.setPlaybackActionHandler((action) {
        receivedActions.add(action);
      });

      // 模拟平台通道下发播控事件
      final binding =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();

      await binding.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('controlPlayback', 'previous')),
        (ByteData? data) {},
      );
      await binding.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          const MethodCall('controlPlayback', 'togglePlay'),
        ),
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

    test('支持注册与注销 setSettingsChangedHandler 与 setOpenSettingsHandler', () {
      final service = DesktopLyricsService();
      DesktopLyricsSettings? changedSettings;
      var openSettingsCalled = false;

      service.setSettingsChangedHandler((s) => changedSettings = s);
      service.setOpenSettingsHandler(() => openSettingsCalled = true);

      service.setSettingsChangedHandler(null);
      service.setOpenSettingsHandler(null);
      expect(changedSettings, isNull);
      expect(openSettingsCalled, isFalse);
    });
  });

  group('DesktopLyricsService hide', () {
    const channel = MethodChannel('shiyin_music/desktop_lyrics');

    test('hide 会透传 transient 标记（切前台临时隐藏 vs 显式关闭）', () async {
      // 伪装 Android 走 MethodChannel 分支（宿主是桌面系统时会走子窗桥接）。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final service = DesktopLyricsService();
      await service.hide();
      await service.hide(transient: true);

      expect(calls.map((c) => c.method).toList(), ['hide', 'hide']);
      expect(calls[0].arguments, {'transient': false});
      expect(calls[1].arguments, {'transient': true});
    });
  });

  group('DesktopLyricsService show', () {
    const channel = MethodChannel('shiyin_music/desktop_lyrics');

    /// 伪装 Android 走 MethodChannel 分支并记录通道调用。
    List<MethodCall> mockChannel() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
      });
      return calls;
    }

    test('show 请求自带最近一次歌词内容（回桌面重建窗口即刻有字）', () async {
      final calls = mockChannel();
      final service = DesktopLyricsService();

      // 悬浮窗可见期间正常推送，主窗侧缓存随之更新。
      await service.updateLyrics(current: '第一句', next: '第二句', activeOnBottom: false);
      // App 切前台：悬浮窗被隐藏，此期间只更新主窗侧缓存（不发平台调用）。
      service.cacheLyrics(current: '第三句', next: '第四句', activeOnBottom: true);
      await service.show(title: '歌名', artist: '歌手');

      expect(calls.map((c) => c.method).toList(), ['updateLyrics', 'show']);
      // 缓存期间不得产生平台调用：前台推送 updateLyrics 会把悬浮窗弹到应用上。
      expect(calls.first.arguments['current'], '第一句');
      expect(calls.last.arguments, {
        'title': '歌名',
        'artist': '歌手',
        'current': '第三句',
        'next': '第四句',
        'activeOnBottom': true,
        'lyricPayload': true,
      });
    });

    test('无歌词时 show 仍标记 lyricPayload，避免原生回退到上一首的缓存', () async {
      final calls = mockChannel();
      final service = DesktopLyricsService();

      await service.updateLyrics(current: '上一首', next: '', activeOnBottom: false);
      service.cacheLyrics(current: '', next: '', activeOnBottom: false);
      await service.show(title: '纯音乐', artist: '');

      final showCall = calls.last;
      expect(showCall.arguments['current'], '');
      expect(showCall.arguments['next'], '');
      expect(showCall.arguments['lyricPayload'], true);
    });

    test('cacheNativeLyrics 只下发 cacheLyrics（原生只缓存、不建窗）', () async {
      final calls = mockChannel();
      final service = DesktopLyricsService();

      await service.cacheNativeLyrics(
        current: '第三句',
        next: '第四句',
        activeOnBottom: true,
      );
      // 缓存也要写进主窗侧镜像：随后 show 重建窗口带的就是这一句。
      await service.show(title: '歌名', artist: '歌手');

      expect(calls.map((c) => c.method).toList(), ['cacheLyrics', 'show']);
      expect(calls.first.arguments, {
        'current': '第三句',
        'next': '第四句',
        'activeOnBottom': true,
      });
      expect(calls.last.arguments['current'], '第三句');
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
    const windowEventChannel = MethodChannel(
      'mixin.one/flutter_multi_window_channel',
    );
    const fakeWindowId = 42;

    /// 记录主窗 -> 子窗的全部消息（即被门控的推送路径）。
    final outgoing = <MethodCall>[];

    void setUpMultiWindowMocks(TestDefaultBinaryMessengerBinding binding) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        multiWindowChannel,
        (call) async {
          // createWindow 返回固定窗口ID，其余窗口控制调用一律成功。
          return call.method == 'createWindow' ? fakeWindowId : null;
        },
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowEventChannel,
        (call) async {
          outgoing.add(call);
          return null;
        },
      );
    }

    void clearMultiWindowMocks(TestDefaultBinaryMessengerBinding binding) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        multiWindowChannel,
        null,
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowEventChannel,
        null,
      );
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
        codec.encodeMethodCall(
          MethodCall(method, <String, dynamic>{
            'fromWindowId': fakeWindowId,
            'arguments': arguments,
          }),
        ),
        (ByteData? data) {},
      );
    }

    List<MethodCall> pushesOf(String method) =>
        outgoing.where((c) => c.method == method).toList();

    dynamic pushPayload(MethodCall call) =>
        (call.arguments as Map)['arguments'] as Map;

    test('overlayReady 之前 updateLyrics 不 invoke 通道，就绪后补发缓存歌词与设置', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      setUpMultiWindowMocks(binding);
      addTearDown(() => clearMultiWindowMocks(binding));

      final bridge = WindowsDesktopLyricsBridge();
      final shown = await bridge.show(title: '标题', artist: '歌手');
      expect(shown, isTrue);
      expect(bridge.isVisible, isTrue);

      // 冷启动窗口期（子引擎未上报 overlayReady）：推送只更新缓存，
      // 不产生任何通道调用，不再触发 MissingPluginException。
      await bridge.updateLyrics(
        current: '第一句',
        next: '第二句',
        activeOnBottom: true,
      );
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
      // 双行交替高亮标志随歌词一起下发（子窗据此决定哪一行带动画进度）。
      expect(lyricPayload['activeOnBottom'], isTrue);

      final settingsPushes = pushesOf('updateSettings');
      expect(settingsPushes, hasLength(1));
      expect(
        (pushPayload(settingsPushes.single)['fontSize'] as num).toDouble(),
        28.0,
      );
    });

    test('windowClosed 复位门控，重建子窗需新一轮 overlayReady 握手', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      setUpMultiWindowMocks(binding);
      addTearDown(() => clearMultiWindowMocks(binding));

      final bridge = WindowsDesktopLyricsBridge();
      await bridge.show(title: '标题', artist: '歌手');

      // 首轮握手前：推送只更新缓存，不产生通道调用。
      await bridge.updateLyrics(current: 'A', next: 'B', activeOnBottom: false);
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
      await bridge.updateLyrics(current: 'C', next: 'D', activeOnBottom: false);
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

      await bridge.updateLyrics(
        current: '第一句',
        next: '第二句',
        activeOnBottom: true,
      );
      expect(pushesOf('updateLyric').length, baseline + 1);

      // 重复 show：走复用分支并直接推送（若误重置门控，此处不会再推送）。
      final again = await bridge.show(title: '标题', artist: '歌手');
      expect(again, isTrue);
      expect(pushesOf('updateLyric').length, baseline + 2);
      expect(pushPayload(pushesOf('updateLyric').last)['current'], '第一句');
    });

    test('updatePlayState 走专用消息，不重发会清进度的 updateLyric', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      setUpMultiWindowMocks(binding);
      addTearDown(() => clearMultiWindowMocks(binding));

      final bridge = WindowsDesktopLyricsBridge();
      await bridge.show(title: '标题', artist: '歌手');
      await bridge.updateLyrics(
        current: '第一句',
        next: '第二句',
        activeOnBottom: false,
      );
      await simulateChildMessage(binding, 'overlayReady');
      outgoing.clear();

      // 播放态变化必须走专用 updatePlayState 消息：复用 updateLyric 的话，
      // 子窗的"换句重置进度"会顺带清掉当前句已唱的逐字高亮。
      await bridge.updatePlayState(isPlaying: false);
      expect(pushesOf('updatePlayState'), hasLength(1));
      expect(
        pushPayload(pushesOf('updatePlayState').single)['isPlaying'],
        isFalse,
      );
      expect(pushesOf('updateLyric'), isEmpty);

      // 换句仍走 updateLyric 全量推送（isPlaying 随歌词一起下发）。
      await bridge.updateLyrics(
        current: '第三句',
        next: '第四句',
        activeOnBottom: true,
      );
      expect(pushesOf('updateLyric'), hasLength(1));
      expect(pushPayload(pushesOf('updateLyric').single)['current'], '第三句');
      expect(pushPayload(pushesOf('updateLyric').single)['isPlaying'], isFalse);
    });

    test('setLyricsLocked 转发回调；主窗处理后的 updateSettings 回推子窗', () async {
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

    test(
      'updateKaraokeProgress 就绪时推送 updateProgress，未就绪时缓存并由 overlayReady 补发',
      () async {
        final binding = TestDefaultBinaryMessengerBinding.instance;
        setUpMultiWindowMocks(binding);
        addTearDown(() => clearMultiWindowMocks(binding));

        final bridge = WindowsDesktopLyricsBridge();
        await bridge.show(title: '标题', artist: '歌手');

        // 未就绪时调用 updateKaraokeProgress：只更新缓存，不推送
        await bridge.updateKaraokeProgress(
          progress: 0.35,
          lineDuration: const Duration(seconds: 4),
          isPlaying: true,
        );
        expect(pushesOf('updateProgress'), isEmpty);

        // overlayReady 握手后补发缓存进度
        await simulateChildMessage(binding, 'overlayReady');
        final progressPushes = pushesOf('updateProgress');
        expect(progressPushes, hasLength(1));
        final payload = pushPayload(progressPushes.single);
        expect(payload['progress'], 0.35);
        expect(payload['isPlaying'], isTrue);

        // 就绪后再次调用：立即推送
        await bridge.updateKaraokeProgress(
          progress: 0.75,
          lineDuration: const Duration(seconds: 4),
          isPlaying: false,
        );
        expect(pushesOf('updateProgress'), hasLength(2));
        final nextPayload = pushPayload(pushesOf('updateProgress').last);
        expect(nextPayload['progress'], 0.75);
        expect(nextPayload['isPlaying'], isFalse);
      },
    );

    test('子窗发送 updateOverlaySettings 触发 onSettingsChanged 回调且正确反序列化', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      setUpMultiWindowMocks(binding);
      addTearDown(() => clearMultiWindowMocks(binding));

      final settingsList = <DesktopLyricsSettings>[];
      final bridge = WindowsDesktopLyricsBridge(
        onSettingsChanged: settingsList.add,
      );
      await bridge.show(title: '标题', artist: '歌手');
      await simulateChildMessage(binding, 'overlayReady');

      await simulateChildMessage(
        binding,
        'updateOverlaySettings',
        <String, dynamic>{
          'fontSize': 32.0,
          'opacity': 0.6,
          'singleLine': false,
          'alignment': 'left',
          'playedTextColor': 0xFFFF0000,
          'unplayedTextColor': 0xFF00FF00,
        },
      );

      expect(settingsList, hasLength(1));
      final received = settingsList.single;
      expect(received.fontSize, 32.0);
      expect(received.opacity, 0.6);
      expect(received.singleLine, isFalse);
      expect(received.alignment, 'left');
      expect(received.playedTextColor, 0xFFFF0000);
      expect(received.unplayedTextColor, 0xFF00FF00);
    });

    test('子窗发送 openLyricsSettings 触发 onOpenSettings 回调', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      setUpMultiWindowMocks(binding);
      addTearDown(() => clearMultiWindowMocks(binding));

      var openSettingsTriggered = false;
      final bridge = WindowsDesktopLyricsBridge(
        onOpenSettings: () {
          openSettingsTriggered = true;
        },
      );
      await bridge.show(title: '标题', artist: '歌手');
      await simulateChildMessage(binding, 'overlayReady');

      await simulateChildMessage(binding, 'openLyricsSettings');
      expect(openSettingsTriggered, isTrue);
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
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pump();
    }

    testWidgets('锁定：只渲染歌词文字与悬浮解锁胶囊，无播控工具栏', (tester) async {
      await pumpContent(
        tester,
        settings: const DesktopLyricsSettings(locked: true, singleLine: false),
      );

      // 歌词文字仍在（含下一句）。
      expect(find.text('第一句歌词'), findsWidgets);
      expect(find.text('第二句歌词'), findsWidgets);

      // 无工具栏 Tooltip。
      final content = find.byKey(contentKey);
      expect(
        find.descendant(of: content, matching: find.byType(Tooltip)),
        findsNothing,
      );
      // 悬浮播控栏全部图标在锁定子树中一律不存在。
      const playbackToolbarIcons = [
        Icons.lock_open_rounded,
        Icons.close_rounded,
        Icons.play_arrow_rounded,
        Icons.pause_rounded,
        Icons.skip_previous_rounded,
        Icons.skip_next_rounded,
        Icons.settings_rounded,
      ];
      expect(
        find.descendant(
          of: content,
          matching: find.byWidgetPredicate(
            (w) => w is Icon && playbackToolbarIcons.contains(w.icon),
          ),
        ),
        findsNothing,
      );
      // 包含解锁胶囊（Icons.lock_rounded + 解锁文字），初始透明度为 0.0
      expect(find.text('解锁'), findsOneWidget);
      final opacityWidget = tester.widget<AnimatedOpacity>(
        find.descendant(of: content, matching: find.byType(AnimatedOpacity)),
      );
      expect(opacityWidget.opacity, 0.0);
    });

    testWidgets('未锁定：保留工具栏与锁按钮（悬停 UI 只属于非锁定态）', (tester) async {
      await pumpContent(tester, settings: const DesktopLyricsSettings());

      expect(find.text('第一句歌词'), findsWidgets);
      expect(find.byType(Tooltip), findsWidgets);
      expect(find.byIcon(Icons.lock_open_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });
  });

  group('applyDesktopLyricsPassthrough 锁定即穿透', () {
    const windowManagerChannel = MethodChannel('window_manager');

    test('locked ⇒ setIgnoreMouseEvents(true)；解锁不整体开启（交由区域轮询）', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      final ignoreCalls = <bool>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowManagerChannel,
        (call) async {
          if (call.method == 'setIgnoreMouseEvents') {
            final args = call.arguments as Map;
            ignoreCalls.add(args['ignore'] as bool);
          }
          return null;
        },
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowManagerChannel,
          null,
        ),
      );

      // 锁定即全穿透：不再受旧 passthrough 字段影响。
      await applyDesktopLyricsPassthrough(
        const DesktopLyricsSettings(locked: true, passthrough: false),
      );
      await applyDesktopLyricsPassthrough(
        const DesktopLyricsSettings(locked: true, passthrough: true),
      );
      // 解锁：不再整体开启接收 —— 窗口常驻展开高度后上方菜单带平时必须
      // 穿透（不挡下层应用点击），命中区域由未锁定态的光标轮询管理。
      await applyDesktopLyricsPassthrough(
        const DesktopLyricsSettings(locked: false),
      );

      expect(ignoreCalls, [true, true]);
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
      double progress = 0.0,
    }) async {
      tester.view.physicalSize = const Size(
        WindowsDesktopLyricsBridge.overlayWidth,
        WindowsDesktopLyricsBridge.overlayWindowHeight,
      );
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(
              WindowsDesktopLyricsBridge.overlayWidth,
              WindowsDesktopLyricsBridge.overlayWindowHeight,
            ),
            textScaler: TextScaler.linear(textScale),
          ),
          child: MaterialApp(
            home: DesktopLyricsOverlayContent(
              settings: settings,
              current: '当前句歌词内容',
              next: '下一句歌词内容',
              isPlaying: true,
              progress: progress,
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
      expect(find.text('当前句歌词内容'), findsWidgets);
    });

    testWidgets('未锁定态悬停卡片内同样不溢出（48sp + 1.5 倍缩放）', (tester) async {
      await pumpOverlay(
        tester,
        settings: const DesktopLyricsSettings(locked: false, fontSize: 48),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('锁定态歌词文字无双黄下划线（decoration 为 none 且具备 Material 祖先）', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        settings: const DesktopLyricsSettings(locked: true),
      );
      final textWidget = tester.widget<Text>(find.text('当前句歌词内容').first);
      expect(textWidget.style?.decoration, TextDecoration.none);
      expect(find.byType(Material), findsWidgets);
    });
  });

  group('桌面歌词排版（单行居中与 QQ 音乐双行交错）', () {
    Future<void> pumpCustomOverlay(
      WidgetTester tester, {
      required DesktopLyricsSettings settings,
      required String current,
      required String next,
      double progress = 0.0,
      bool activeOnBottom = false,
    }) async {
      tester.view.physicalSize = const Size(
        WindowsDesktopLyricsBridge.overlayWidth,
        WindowsDesktopLyricsBridge.overlayWindowHeight,
      );
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: DesktopLyricsOverlayContent(
            settings: settings,
            current: current,
            next: next,
            isPlaying: true,
            progress: progress,
            activeOnBottom: activeOnBottom,
            onControlPlayback: (_) {},
            onToggleLock: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pump();
    }

    /// 歌词主体所在的 Column（限定在卡片带内：菜单常驻菜单带后，
    /// 树里还有菜单自己的 Column，不能直接按类型找）。
    final lyricsColumnFinder = find.descendant(
      of: find.byWidgetPredicate(
        (w) =>
            w is Positioned &&
            w.height == WindowsDesktopLyricsBridge.overlayHeight &&
            w.bottom == 0.0,
      ),
      matching: find.byType(Column),
    );

    testWidgets('单行模式 (singleLine: true)：仅渲染当前句，不渲染下一句', (tester) async {
      await pumpCustomOverlay(
        tester,
        settings: const DesktopLyricsSettings(singleLine: true),
        current: '当前句歌词内容',
        next: '下一句歌词内容',
      );
      expect(find.text('当前句歌词内容'), findsWidgets);
      expect(find.text('下一句歌词内容'), findsNothing);

      final karaokeLines = tester
          .widgetList<LyricsKaraokeLine>(find.byType(LyricsKaraokeLine))
          .toList();
      expect(karaokeLines.length, 1);
      expect(karaokeLines.first.text, '当前句歌词内容');
      expect(karaokeLines.first.fontWeight, FontWeight.bold);
    });

    testWidgets('双行交错模式 (singleLine: false)：当前句居左交错，下一句居右交错', (tester) async {
      await pumpCustomOverlay(
        tester,
        settings: const DesktopLyricsSettings(singleLine: false),
        current: '当前句歌词内容',
        next: '下一句歌词内容',
      );
      expect(find.text('当前句歌词内容'), findsWidgets);
      expect(find.text('下一句歌词内容'), findsWidgets);

      final karaokeLines = tester
          .widgetList<LyricsKaraokeLine>(find.byType(LyricsKaraokeLine))
          .toList();
      expect(karaokeLines.length, 2);

      final currentLine = karaokeLines[0];
      final nextLine = karaokeLines[1];

      expect(currentLine.text, '当前句歌词内容');
      expect(currentLine.alignment, TextAlign.left);
      expect(currentLine.fontWeight, FontWeight.bold);

      expect(nextLine.text, '下一句歌词内容');
      expect(nextLine.alignment, TextAlign.right);
      expect(nextLine.progress, 0.0);

      final column = tester.widget<Column>(lyricsColumnFinder);
      final line1Align = column.children[0] as Align;
      final line2Align = column.children[2] as Align;
      expect(line1Align.alignment, Alignment.centerLeft);
      expect(line2Align.alignment, Alignment.centerRight);
    });

    testWidgets('双行交错模式 (singleLine: false)：上下两行统一字号与 bold 字重', (tester) async {
      const fontSize = 24.0;
      await pumpCustomOverlay(
        tester,
        settings: const DesktopLyricsSettings(
          singleLine: false,
          fontSize: fontSize,
        ),
        current: '当前句歌词内容',
        next: '下一句歌词内容',
      );

      final karaokeLines = tester
          .widgetList<LyricsKaraokeLine>(find.byType(LyricsKaraokeLine))
          .toList();
      expect(karaokeLines.length, 2);
      final currentLine = karaokeLines[0];
      final nextLine = karaokeLines[1];

      // 上下两行字体大小统一且字重均为 bold
      expect(currentLine.fontWeight, FontWeight.bold);
      expect(nextLine.fontWeight, FontWeight.bold);
      expect(currentLine.fontSize, nextLine.fontSize);
      expect(currentLine.fontSize, closeTo(fontSize * 0.82, 0.001));
      // 基础（未播放）色 RGB 一致，"下一句"轻度弱化（0.85）但保持可读，
      // 不再叠 textOpacity 折扣（背景全透明的悬浮窗上双重压暗会看不清）。
      expect(currentLine.unplayedColor.r, nextLine.unplayedColor.r);
      expect(currentLine.unplayedColor.g, nextLine.unplayedColor.g);
      expect(currentLine.unplayedColor.b, nextLine.unplayedColor.b);
      expect(currentLine.unplayedColor.a, closeTo(1.0, 0.001));
      expect(nextLine.unplayedColor.a, closeTo(0.85, 0.001));
      expect(currentLine.textOpacity, 1.0);
      expect(nextLine.textOpacity, 1.0);
    });

    testWidgets('双行交替高亮：当前句在下行时，上行让位给下一句（文字不搬家）', (tester) async {
      await pumpCustomOverlay(
        tester,
        settings: const DesktopLyricsSettings(singleLine: false),
        current: '当前句歌词内容',
        next: '下一句歌词内容',
        progress: 0.5,
        activeOnBottom: true,
      );

      final karaokeLines = tester
          .widgetList<LyricsKaraokeLine>(find.byType(LyricsKaraokeLine))
          .toList();
      expect(karaokeLines.length, 2);

      // 上行 = 下一句（未播放、轻度弱化、无进度），下行 = 当前句（带动画进度）
      final topLine = karaokeLines[0];
      final bottomLine = karaokeLines[1];
      expect(topLine.text, '下一句歌词内容');
      expect(topLine.progress, 0.0);
      expect(topLine.unplayedColor.a, closeTo(0.85, 0.001));
      expect(bottomLine.text, '当前句歌词内容');
      expect(bottomLine.progress, 0.5);
      expect(bottomLine.unplayedColor.a, closeTo(1.0, 0.001));

      // 交错锚点不随高亮位置变化：上行恒居左、下行恒居右
      final column = tester.widget<Column>(lyricsColumnFinder);
      expect((column.children[0] as Align).alignment, Alignment.centerLeft);
      expect((column.children[2] as Align).alignment, Alignment.centerRight);

      // 高亮交替而文字位置不变：两次换句后"当前句"仍在下行同一位置
      await pumpCustomOverlay(
        tester,
        settings: const DesktopLyricsSettings(singleLine: false),
        current: '当前句歌词内容',
        next: '下一句歌词内容',
        progress: 0.9,
        activeOnBottom: true,
      );
      final afterScroll = tester
          .widgetList<LyricsKaraokeLine>(find.byType(LyricsKaraokeLine))
          .toList();
      expect(afterScroll.length, 2);
      expect(afterScroll[1].text, '当前句歌词内容');
      expect(afterScroll[1].progress, 0.9);
    });

    testWidgets('双行对齐：居中/左/右时两行同侧锚点；split 时上下分居两侧', (tester) async {
      Future<void> expectDualAnchors({
        required String alignment,
        required Alignment expectedTop,
        required Alignment expectedBottom,
        required TextAlign expectedTopText,
        required TextAlign expectedBottomText,
      }) async {
        await pumpCustomOverlay(
          tester,
          settings: DesktopLyricsSettings(
            singleLine: false,
            alignment: alignment,
          ),
          current: '当前句歌词内容',
          next: '下一句歌词内容',
        );
        final lines = tester
            .widgetList<LyricsKaraokeLine>(find.byType(LyricsKaraokeLine))
            .toList();
        expect(lines.length, 2);
        expect(lines[0].alignment, expectedTopText);
        expect(lines[1].alignment, expectedBottomText);
        final column = tester.widget<Column>(lyricsColumnFinder);
        expect((column.children[0] as Align).alignment, expectedTop);
        expect((column.children[2] as Align).alignment, expectedBottom);
      }

      await expectDualAnchors(
        alignment: DesktopLyricsAlignment.split,
        expectedTop: Alignment.centerLeft,
        expectedBottom: Alignment.centerRight,
        expectedTopText: TextAlign.left,
        expectedBottomText: TextAlign.right,
      );
      await expectDualAnchors(
        alignment: DesktopLyricsAlignment.center,
        expectedTop: Alignment.center,
        expectedBottom: Alignment.center,
        expectedTopText: TextAlign.center,
        expectedBottomText: TextAlign.center,
      );
      await expectDualAnchors(
        alignment: DesktopLyricsAlignment.left,
        expectedTop: Alignment.centerLeft,
        expectedBottom: Alignment.centerLeft,
        expectedTopText: TextAlign.left,
        expectedBottomText: TextAlign.left,
      );
      await expectDualAnchors(
        alignment: DesktopLyricsAlignment.right,
        expectedTop: Alignment.centerRight,
        expectedBottom: Alignment.centerRight,
        expectedTopText: TextAlign.right,
        expectedBottomText: TextAlign.right,
      );
    });

    testWidgets('歌词带顶部预留工具栏专属带：padding.top == lyricsTopInset，按钮区与歌词不重叠', (
      tester,
    ) async {
      await pumpCustomOverlay(
        tester,
        settings: const DesktopLyricsSettings(singleLine: false),
        current: '当前句歌词内容',
        next: '下一句歌词内容',
      );

      // 歌词主体最外层的 Padding 必须预留顶部工具栏带高度
      final bodyPaddingFinder = find.byWidgetPredicate(
        (w) =>
            w is Padding &&
            w.padding ==
                const EdgeInsets.only(
                  top: WindowsDesktopLyricsBridge.lyricsTopInset,
                  bottom: 2.0,
                  left: 24.0,
                  right: 24.0,
                ),
      );
      expect(bodyPaddingFinder, findsOneWidget);

      // 工具栏按钮（30px 高、top 2）底边 32 < 歌词带顶边 36 → 不重叠
      const toolbarButtonSize = 30.0;
      const toolbarTop = 2.0;
      expect(
        toolbarTop + toolbarButtonSize <=
            WindowsDesktopLyricsBridge.lyricsTopInset,
        isTrue,
      );
    });

    testWidgets('修改 progress 更新 DesktopLyricsOverlayContent 变色进度', (
      tester,
    ) async {
      await pumpCustomOverlay(
        tester,
        settings: const DesktopLyricsSettings(singleLine: true),
        current: '变色测试',
        next: '',
        progress: 0.25,
      );

      var karaokeLine = tester.widget<LyricsKaraokeLine>(
        find.byType(LyricsKaraokeLine),
      );
      expect(karaokeLine.progress, 0.25);

      await pumpCustomOverlay(
        tester,
        settings: const DesktopLyricsSettings(singleLine: true),
        current: '变色测试',
        next: '',
        progress: 0.75,
      );

      karaokeLine = tester.widget<LyricsKaraokeLine>(
        find.byType(LyricsKaraokeLine),
      );
      expect(karaokeLine.progress, 0.75);
    });

    testWidgets('单行模式下 settings.alignment 生效', (tester) async {
      for (final alignStr in ['left', 'right', 'center']) {
        final expected = alignStr == 'left'
            ? TextAlign.left
            : (alignStr == 'right' ? TextAlign.right : TextAlign.center);
        await pumpCustomOverlay(
          tester,
          settings: DesktopLyricsSettings(
            singleLine: true,
            alignment: alignStr,
          ),
          current: '对齐测试',
          next: '',
        );
        final line = tester.widget<LyricsKaraokeLine>(
          find.byType(LyricsKaraokeLine),
        );
        expect(line.alignment, expected);
      }
    });

    testWidgets('当前歌词为空时渲染“暂无歌词”', (tester) async {
      await pumpCustomOverlay(
        tester,
        settings: const DesktopLyricsSettings(singleLine: true),
        current: '',
        next: '',
      );

      expect(find.text('暂无歌词'), findsWidgets);
    });

    testWidgets('双行模式下 48sp 与 2.0 textScale 同样不溢出', (tester) async {
      tester.view.physicalSize = const Size(
        WindowsDesktopLyricsBridge.overlayWidth,
        WindowsDesktopLyricsBridge.overlayWindowHeight,
      );
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(
              WindowsDesktopLyricsBridge.overlayWidth,
              WindowsDesktopLyricsBridge.overlayWindowHeight,
            ),
            textScaler: TextScaler.linear(2.0),
          ),
          child: MaterialApp(
            home: DesktopLyricsOverlayContent(
              settings: const DesktopLyricsSettings(
                singleLine: false,
                fontSize: 48,
              ),
              current: '超大字号当前句歌词内容',
              next: '超大字号下一句歌词内容',
              isPlaying: true,
              progress: 0.5,
              onControlPlayback: (_) {},
              onToggleLock: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('悬浮工具栏快捷调节菜单（字号、配色、单双行）', () {
    Future<_QuickSettingsHarness> pumpQuickSettings(
      WidgetTester tester, {
      required Widget child,
      Future<dynamic>? Function(MethodCall call)? windowManagerHandler,
    }) async {
      tester.view.physicalSize = const Size(
        WindowsDesktopLyricsBridge.overlayWidth,
        400,
      );
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      var cursor = const Offset(390, 240);
      const windowManagerChannel = MethodChannel('window_manager');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowManagerChannel, (call) async {
            if (windowManagerHandler != null) {
              final result = await windowManagerHandler(call);
              if (result != null) return result;
            }
            if (call.method == 'getCursorScreenPoint') {
              // vendored window_manager 返回 dx/dy/scale（scale=1 → 逻辑坐标原样）。
              return {'dx': cursor.dx, 'dy': cursor.dy, 'scale': 1.0};
            }
            if (call.method == 'getBounds' || call.method == 'getPosition') {
              return {
                'x': 0.0,
                'y': 0.0,
                'width': WindowsDesktopLyricsBridge.overlayWidth,
                'height': 400.0,
              };
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(windowManagerChannel, null),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: Align(alignment: Alignment.topLeft, child: child),
          ),
        ),
      );
      // 首个轮询拍（80ms）让光标命中生效、工具栏淡入完成。
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();

      return _QuickSettingsHarness(moveCursor: (pos) => cursor = pos);
    }

    /// 菜单可见性 = 菜单带内「字体大小」文本所在 AnimatedOpacity 的值
    /// （菜单常驻菜单带、收起时以 opacity 0 隐藏）。
    double menuOpacity(WidgetTester tester) {
      final finder = find
          .ancestor(
            of: find.text('字体大小'),
            matching: find.byType(AnimatedOpacity),
          )
          .first;
      return tester.widget<AnimatedOpacity>(finder).opacity;
    }

    testWidgets('工具栏包含设置按钮 (Icons.settings_rounded)', (tester) async {
      await pumpQuickSettings(
        tester,
        child: DesktopLyricsOverlayContent(
          settings: const DesktopLyricsSettings(locked: false),
          current: '测试歌词',
          next: '',
          isPlaying: true,
          onControlPlayback: (_) {},
          onToggleLock: (_) {},
          onClose: () {},
        ),
      );
      expect(find.byIcon(Icons.settings_rounded), findsOneWidget);
    });

    testWidgets('工具栏在卡片顶专属带内右下锚定，按钮尺寸扩大为 30x30 且图标尺寸为 20', (tester) async {
      await pumpQuickSettings(
        tester,
        child: DesktopLyricsOverlayContent(
          settings: const DesktopLyricsSettings(locked: false),
          current: '测试歌词',
          next: '',
          isPlaying: true,
          onControlPlayback: (_) {},
          onToggleLock: (_) {},
          onClose: () {},
        ),
      );

      // 工具栏专属带贴卡片顶（窗口底上 88 = 专属带底边），高 36。
      final positionedToolbar = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byIcon(Icons.settings_rounded),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(
        positionedToolbar.bottom,
        WindowsDesktopLyricsBridge.overlayLyricsHeight,
      );
      expect(
        positionedToolbar.height,
        WindowsDesktopLyricsBridge.lyricsTopInset,
      );

      // 工具栏在 IgnorePointer 内直接是 Align，不再有外层 DecoratedBox 半透黑色胶囊背景
      final toolbarRow = find
          .ancestor(
            of: find.byIcon(Icons.settings_rounded),
            matching: find.byType(Row),
          )
          .first;
      final ignorePointer = find
          .ancestor(of: toolbarRow, matching: find.byType(IgnorePointer))
          .first;
      final ignorePointerWidget = tester.widget<IgnorePointer>(ignorePointer);
      expect(ignorePointerWidget.child, isA<Align>());
      expect(
        find.descendant(
          of: ignorePointer,
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).borderRadius ==
                    BorderRadius.circular(10),
          ),
        ),
        findsNothing,
      );

      // 按钮尺寸扩大为 30x30
      final buttonContainers = tester.widgetList<AnimatedContainer>(
        find.descendant(
          of: toolbarRow,
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect(buttonContainers.isNotEmpty, isTrue);
      for (final container in buttonContainers) {
        expect(container.constraints?.maxWidth, 30.0);
        expect(container.constraints?.maxHeight, 30.0);
      }

      // 工具栏播控与设置按钮默认图标统一为 20
      final icons = tester.widgetList<Icon>(
        find.descendant(of: toolbarRow, matching: find.byType(Icon)),
      );
      for (final icon in icons) {
        expect(icon.size, 20.0);
      }
    });

    testWidgets('点击设置按钮展开快捷调节菜单，再次点击或点击菜单带空白收起', (tester) async {
      await pumpQuickSettings(
        tester,
        child: DesktopLyricsOverlayContent(
          settings: const DesktopLyricsSettings(locked: false),
          current: '测试歌词',
          next: '',
          isPlaying: true,
          onControlPlayback: (_) {},
          onToggleLock: (_) {},
          onClose: () {},
        ),
      );

      // 初始未展开：菜单常驻菜单带但隐藏（opacity 0）。
      expect(menuOpacity(tester), 0.0);

      // 点击设置按钮展开
      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      expect(menuOpacity(tester), 1.0);
      expect(find.text('更多设置'), findsOneWidget);

      // 点击菜单带空白（窗口左上角属于菜单带）收起菜单
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(menuOpacity(tester), 0.0);
    });

    testWidgets('点击 [+] 或 [-] 触发字号调节回调并钳制在 [16, 40]', (tester) async {
      DesktopLyricsSettings? updatedSettings;

      await pumpQuickSettings(
        tester,
        child: StatefulBuilder(
          builder: (context, setState) {
            return DesktopLyricsOverlayContent(
              settings:
                  updatedSettings ??
                  const DesktopLyricsSettings(locked: false, fontSize: 24.0),
              current: '测试歌词',
              next: '',
              isPlaying: true,
              onControlPlayback: (_) {},
              onToggleLock: (_) {},
              onClose: () {},
              onUpdateSettings: (s) => setState(() => updatedSettings = s),
            );
          },
        ),
      );

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      // 当前字号 24
      expect(find.text('24'), findsOneWidget);

      // 点击 [+] -> 26
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(updatedSettings?.fontSize, 26.0);
      expect(find.text('26'), findsOneWidget);

      // 点击 [-] -> 24
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pumpAndSettle();
      expect(updatedSettings?.fontSize, 24.0);
      expect(find.text('24'), findsOneWidget);
    });

    testWidgets('点击歌词配色方案同步切换歌词色与高亮色', (tester) async {
      DesktopLyricsSettings? updatedSettings;

      await pumpQuickSettings(
        tester,
        child: StatefulBuilder(
          builder: (context, setState) {
            return DesktopLyricsOverlayContent(
              settings:
                  updatedSettings ?? const DesktopLyricsSettings(locked: false),
              current: '测试歌词',
              next: '',
              isPlaying: true,
              onControlPlayback: (_) {},
              onToggleLock: (_) {},
              onClose: () {},
              onUpdateSettings: (s) => setState(() => updatedSettings = s),
            );
          },
        ),
      );

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      // 默认配色命中「经典」方案（天蓝未播放 + 金黄已播放）。
      expect(
        DesktopLyricsColorScheme.matchFor(
          updatedSettings ?? const DesktopLyricsSettings(),
        )?.name,
        '经典',
      );

      // 点击「鎏金」方案：歌词色与高亮色同步变化（白词 + 金黄高亮）。
      final gilded = DesktopLyricsColorScheme.presets[1];
      expect(gilded.name, '鎏金');
      await tester.tap(find.byKey(ValueKey('scheme_${gilded.name}')));
      await tester.pumpAndSettle();

      expect(updatedSettings?.unplayedTextColor, gilded.unplayedTextColor);
      expect(updatedSettings?.textColor, gilded.unplayedTextColor);
      expect(updatedSettings?.playedTextColor, gilded.playedTextColor);

      // 再点「月白」：蓝灰词 + 纯白高亮。
      final mono = DesktopLyricsColorScheme.presets[5];
      expect(mono.name, '月白');
      await tester.tap(find.byKey(ValueKey('scheme_${mono.name}')));
      await tester.pumpAndSettle();

      expect(updatedSettings?.unplayedTextColor, mono.unplayedTextColor);
      expect(updatedSettings?.playedTextColor, mono.playedTextColor);
    });

    testWidgets('点击切换单/双行触发单双行切换回调', (tester) async {
      DesktopLyricsSettings? updatedSettings;

      await pumpQuickSettings(
        tester,
        child: StatefulBuilder(
          builder: (context, setState) {
            return DesktopLyricsOverlayContent(
              settings:
                  updatedSettings ??
                  const DesktopLyricsSettings(locked: false, singleLine: true),
              current: '测试歌词',
              next: '',
              isPlaying: true,
              onControlPlayback: (_) {},
              onToggleLock: (_) {},
              onClose: () {},
              onUpdateSettings: (s) => setState(() => updatedSettings = s),
            );
          },
        ),
      );

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      // 单行模式下文案为“切换双行”
      expect(find.text('切换双行'), findsOneWidget);
      await tester.tap(find.text('切换双行'));
      await tester.pumpAndSettle();

      expect(updatedSettings?.singleLine, isFalse);
      expect(find.text('切换单行'), findsOneWidget);

      // 再次点击切回单行
      await tester.tap(find.text('切换单行'));
      await tester.pumpAndSettle();
      expect(updatedSettings?.singleLine, isTrue);
    });

    testWidgets('点击更多设置触发 onOpenDetailedSettings 回调并关闭菜单', (tester) async {
      var openedDetailed = false;

      await pumpQuickSettings(
        tester,
        child: DesktopLyricsOverlayContent(
          settings: const DesktopLyricsSettings(locked: false),
          current: '测试歌词',
          next: '',
          isPlaying: true,
          onControlPlayback: (_) {},
          onToggleLock: (_) {},
          onClose: () {},
          onOpenDetailedSettings: () => openedDetailed = true,
        ),
      );

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      expect(find.text('更多设置'), findsOneWidget);
      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();

      expect(openedDetailed, isTrue);
      // 菜单已淡出收起
      expect(menuOpacity(tester), 0.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('菜单展开/收起零原生窗口几何调用（常驻高度，纯 Flutter 动画——防 DWM 拉伸闪帧回归）', (
      tester,
    ) async {
      final geometryCalls = <String>[];

      await pumpQuickSettings(
        tester,
        windowManagerHandler: (call) async {
          if (call.method == 'setSize' ||
              call.method == 'setBounds' ||
              call.method == 'setPosition') {
            geometryCalls.add(call.method);
          }
          return null;
        },
        child: DesktopLyricsOverlayContent(
          settings: const DesktopLyricsSettings(locked: false),
          current: '测试歌词',
          next: '',
          isPlaying: true,
          onControlPlayback: (_) {},
          onToggleLock: (_) {},
          onClose: () {},
        ),
      );
      geometryCalls.clear();

      // 1. 展开菜单：不得触碰窗口几何（历史实现 setBounds 124↔296，
      //    DWM 拉伸旧帧即"点设置闪一下"的根因）。
      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();
      expect(menuOpacity(tester), 1.0);
      expect(geometryCalls, isEmpty);

      // 2. 收起：同样零几何调用。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(menuOpacity(tester), 0.0);
      expect(geometryCalls, isEmpty);

      // 3. 再展开后销毁组件：亦无防御性还原调用（窗口几何从未改变）。
      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(geometryCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('常驻高度布局：卡片贴窗口底、菜单带在卡片上方、锚点与窗口总高无关', (tester) async {
      await pumpQuickSettings(
        tester,
        child: DesktopLyricsOverlayContent(
          settings: const DesktopLyricsSettings(locked: false),
          current: '测试歌词',
          next: '',
          isPlaying: true,
          onControlPlayback: (_) {},
          onToggleLock: (_) {},
          onClose: () {},
        ),
      );

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      // 根容器恒为常驻窗口高度（不读 MediaQuery，杜绝 metrics 竞态中间帧）。
      final rootSizedBox = tester.widget<SizedBox>(
        find.descendant(
          of: find.byType(HoverableOverlay),
          matching: find.byType(SizedBox).first,
        ),
      );
      expect(
        rootSizedBox.height,
        WindowsDesktopLyricsBridge.overlayWindowHeight,
      );

      // 歌词卡片贴窗口底（bottom: 0），高度恒 124。
      final lyricsCardFinder = find.descendant(
        of: find.byType(HoverableOverlay),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Positioned &&
              w.height == WindowsDesktopLyricsBridge.overlayHeight &&
              w.bottom == 0.0,
        ),
      );
      expect(lyricsCardFinder, findsOneWidget);

      // 菜单带恒占窗口顶部 172（top: 0、height: 菜单面板高度）。
      final menuBandFinder = find.descendant(
        of: find.byType(HoverableOverlay),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Positioned &&
              w.top == 0.0 &&
              w.height == WindowsDesktopLyricsBridge.overlayMenuPanelHeight,
        ),
      );
      expect(menuBandFinder, findsOneWidget);
      // 菜单内容在带内（淡入动画容器）。
      expect(find.byType(OverlayQuickSettingsMenu), findsOneWidget);
    });

    testWidgets('菜单展开后本窗失去前台焦点（点击别的软件）自动收起', (tester) async {
      var focused = true;

      await pumpQuickSettings(
        tester,
        child: DesktopLyricsOverlayContent(
          settings: const DesktopLyricsSettings(locked: false),
          current: '测试歌词',
          next: '',
          isPlaying: true,
          onControlPlayback: (_) {},
          onToggleLock: (_) {},
          onClose: () {},
          appFocusedProvider: () async => focused,
        ),
      );

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();
      expect(menuOpacity(tester), 1.0);

      // 第一轮轮询观察到"本窗是前台窗口"→ 武装失焦判定。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(menuOpacity(tester), 1.0);

      // 用户点了别的软件：本窗不再是前台窗口 → 菜单自动收起。
      focused = false;
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(menuOpacity(tester), 0.0);
    });

    testWidgets('窗口从未获得前台焦点时不被误关，鼠标离开窗口超时后兜底收起', (tester) async {
      final harness = await pumpQuickSettings(
        tester,
        child: DesktopLyricsOverlayContent(
          settings: const DesktopLyricsSettings(locked: false),
          current: '测试歌词',
          next: '',
          isPlaying: true,
          onControlPlayback: (_) {},
          onToggleLock: (_) {},
          onClose: () {},
          // 恒为 false：悬浮窗在不抢焦点的环境下 isFocused 永远不成立。
          appFocusedProvider: () async => false,
        ),
      );

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      // 多轮轮询后菜单仍在（没有被误判为"已失焦"而立刻关掉）。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(menuOpacity(tester), 1.0);

      // 鼠标移出整个窗口：兜底计时器 800ms 后收起。
      harness.moveCursor(const Offset(1500, 300));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      expect(menuOpacity(tester), 0.0);
    });

    testWidgets('未锁定态命中区域轮询：卡片带解除穿透，菜单带平时穿透、展开期间可交互', (tester) async {
      final ignoreCalls = <bool>[];

      final harness = await pumpQuickSettings(
        tester,
        child: DesktopLyricsOverlayContent(
          settings: const DesktopLyricsSettings(locked: false),
          current: '测试歌词',
          next: '',
          isPlaying: true,
          onControlPlayback: (_) {},
          onToggleLock: (_) {},
          onClose: () {},
          ignoreMouseEventsSetter: (ignore) async => ignoreCalls.add(ignore),
        ),
      );
      ignoreCalls.clear();

      // 光标移出窗口 → 恢复穿透（菜单带不挡下层应用点击）。
      harness.moveCursor(const Offset(1500, 300));
      await tester.pump(const Duration(milliseconds: 80));
      expect(ignoreCalls, isNotEmpty);
      expect(ignoreCalls.last, isTrue);

      // 光标回到卡片带 → 解除穿透（hover 卡片/工具栏/拖动）。
      harness.moveCursor(const Offset(390, 240));
      await tester.pump(const Duration(milliseconds: 80));
      expect(ignoreCalls.last, isFalse);

      // 光标进入菜单带（菜单收起）→ 仍穿透。
      harness.moveCursor(const Offset(390, 100));
      await tester.pump(const Duration(milliseconds: 80));
      expect(ignoreCalls.last, isTrue);

      // 菜单展开期间，光标在菜单带内也保持可交互（能点到菜单项）。
      harness.moveCursor(const Offset(390, 240));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();
      harness.moveCursor(const Offset(390, 100));
      await tester.pump(const Duration(milliseconds: 80));
      expect(ignoreCalls.last, isFalse);
    });
  });

  group('clampOverlayOriginToVisibleAreas（拔显示器/屏幕外位置钳制）', () {
    const primary = Rect.fromLTWH(0, 0, 1920, 1080);

    test('主屏内可见位置原样返回', () {
      final origin =
          WindowsDesktopLyricsBridge.clampOverlayOriginToVisibleAreas(
            const Offset(500, 900),
            [primary],
            fallback: const Offset(100, 100),
          );
      expect(origin, const Offset(500, 900));
    });

    test('位置在已拔掉的副屏（屏幕外）→ 钳回主屏右下可见区', () {
      final origin =
          WindowsDesktopLyricsBridge.clampOverlayOriginToVisibleAreas(
            const Offset(3840, 2000),
            [primary],
            fallback: const Offset(100, 100),
          );
      // 右/下至少留 80px 可见。
      expect(origin.dx, primary.right - 80);
      expect(origin.dy, primary.bottom - 80);
    });

    test('与主屏仅数像素交集（DPI 换算贴边残余）→ 钳回可见区', () {
      // 窗口宽 780：左沿 1915 只剩 5px 可见。
      final origin =
          WindowsDesktopLyricsBridge.clampOverlayOriginToVisibleAreas(
            const Offset(1915, 500),
            [primary],
            fallback: const Offset(100, 100),
          );
      expect(origin.dx, primary.right - 80);
      expect(origin.dy, 500);
    });

    test('无显示器信息时返回 fallback（无从钳制）', () {
      final origin =
          WindowsDesktopLyricsBridge.clampOverlayOriginToVisibleAreas(
            const Offset(-5000, -5000),
            const <Rect>[],
            fallback: const Offset(100, 100),
          );
      expect(origin, const Offset(100, 100));
    });

    test('多显示器：副屏内可见位置不误钳', () {
      const secondary = Rect.fromLTWH(1920, 0, 1920, 1080);
      final origin =
          WindowsDesktopLyricsBridge.clampOverlayOriginToVisibleAreas(
            const Offset(2500, 900),
            [primary, secondary],
            fallback: const Offset(100, 100),
          );
      expect(origin, const Offset(2500, 900));
    });
  });

  group('存量位置语义迁移（loadStoredOverlayOrigin）', () {
    const primary = Rect.fromLTWH(0, 0, 1920, 1080);
    const fallback = Offset(570, 624);

    Future<SharedPreferences> mockPrefs(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    bool semanticsKeysAllSet(SharedPreferences prefs) =>
        prefs.getBool(WindowsDesktopLyricsBridge.windowInsetMigratedPrefKey) ==
            true &&
        prefs.getBool(WindowsDesktopLyricsBridge.windowTallMigratedPrefKey) ==
            true &&
        prefs.getBool(
              WindowsDesktopLyricsBridge.windowMenuProgressRowMigratedPrefKey,
            ) ==
            true;

    test('全新安装（无存量坐标）：不写坐标，但三枚语义键置位', () async {
      final prefs = await mockPrefs(<String, Object>{});

      final origin = await WindowsDesktopLyricsBridge.loadStoredOverlayOrigin(
        visibleAreas: const [primary],
        fallback: fallback,
      );

      expect(origin, isNull, reason: '无存量位置时由调用方落主屏默认点');
      // 回归：全新安装的首次坐标由子窗落盘（拖动/关窗），语义键不置位
      // 会让第二次启动把它当迁移前旧值再减 248px。
      expect(semanticsKeysAllSet(prefs), isTrue);
      expect(
        prefs.getDouble(WindowsDesktopLyricsBridge.windowLeftPrefKey),
        isNull,
      );
      expect(
        prefs.getDouble(WindowsDesktopLyricsBridge.windowTopPrefKey),
        isNull,
      );
    });

    test('迁移前旧语义（三键全 false）→ top 一次性减 36+212 并置键', () async {
      final prefs = await mockPrefs(<String, Object>{
        WindowsDesktopLyricsBridge.windowLeftPrefKey: 400.0,
        WindowsDesktopLyricsBridge.windowTopPrefKey: 900.0,
      });

      final origin = await WindowsDesktopLyricsBridge.loadStoredOverlayOrigin(
        visibleAreas: const [primary],
        fallback: fallback,
      );

      const expectedTop =
          900.0 -
          WindowsDesktopLyricsBridge.lyricsTopInset -
          WindowsDesktopLyricsBridge.overlayMenuPanelHeight;
      expect(origin, const Offset(400, 652));
      expect(expectedTop, 652.0); // 36（工具栏带）+ 212（常驻菜单带）
      expect(
        prefs.getDouble(WindowsDesktopLyricsBridge.windowTopPrefKey),
        expectedTop,
      );
      expect(semanticsKeysAllSet(prefs), isTrue);
    });

    test('v3.0.7 存量（菜单带 172 已迁移）→ 只补减 212-172', () async {
      final prefs = await mockPrefs(<String, Object>{
        WindowsDesktopLyricsBridge.windowLeftPrefKey: 400.0,
        WindowsDesktopLyricsBridge.windowTopPrefKey: 900.0,
        WindowsDesktopLyricsBridge.windowInsetMigratedPrefKey: true,
        WindowsDesktopLyricsBridge.windowTallMigratedPrefKey: true,
      });

      final origin = await WindowsDesktopLyricsBridge.loadStoredOverlayOrigin(
        visibleAreas: const [primary],
        fallback: fallback,
      );

      // 迁移（三）只补减菜单带增量：212 - 172 = 40（不再减 36+212）。
      final expectedTop =
          900.0 -
          (WindowsDesktopLyricsBridge.overlayMenuPanelHeight -
              WindowsDesktopLyricsBridge.overlayMenuPanelHeightBeforeProgressRow);
      expect(origin, Offset(400, expectedTop));
      expect(expectedTop, 860.0);
      expect(semanticsKeysAllSet(prefs), isTrue);
    });

    test('三键已置位 → 坐标原样返回、不重复迁移', () async {
      const stored = Offset(300, 700);
      final prefs = await mockPrefs(<String, Object>{
        WindowsDesktopLyricsBridge.windowLeftPrefKey: stored.dx,
        WindowsDesktopLyricsBridge.windowTopPrefKey: stored.dy,
        WindowsDesktopLyricsBridge.windowInsetMigratedPrefKey: true,
        WindowsDesktopLyricsBridge.windowTallMigratedPrefKey: true,
        WindowsDesktopLyricsBridge.windowMenuProgressRowMigratedPrefKey: true,
      });

      final origin = await WindowsDesktopLyricsBridge.loadStoredOverlayOrigin(
        visibleAreas: const [primary],
        fallback: fallback,
      );

      expect(origin, stored);
      expect(
        prefs.getDouble(WindowsDesktopLyricsBridge.windowTopPrefKey),
        stored.dy,
      );
    });

    test('存量位置在已拔掉的副屏 → 钳回可见区并回写', () async {
      final prefs = await mockPrefs(<String, Object>{
        WindowsDesktopLyricsBridge.windowLeftPrefKey: 3840.0,
        WindowsDesktopLyricsBridge.windowTopPrefKey: 2000.0,
        WindowsDesktopLyricsBridge.windowInsetMigratedPrefKey: true,
        WindowsDesktopLyricsBridge.windowTallMigratedPrefKey: true,
        WindowsDesktopLyricsBridge.windowMenuProgressRowMigratedPrefKey: true,
      });

      final origin = await WindowsDesktopLyricsBridge.loadStoredOverlayOrigin(
        visibleAreas: const [primary],
        fallback: fallback,
      );

      expect(origin, Offset(primary.right - 80, primary.bottom - 80));
      expect(
        prefs.getDouble(WindowsDesktopLyricsBridge.windowLeftPrefKey),
        primary.right - 80,
      );
      expect(
        prefs.getDouble(WindowsDesktopLyricsBridge.windowTopPrefKey),
        primary.bottom - 80,
      );
    });
  });

  group('persistOverlayWindowPosition（活坐标落盘必带语义键）', () {
    test('落盘活窗口坐标的同时置位三枚语义键', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const channel = MethodChannel('window_manager');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getBounds') {
              return <String, dynamic>{
                'x': 123.0,
                'y': 456.0,
                'width': WindowsDesktopLyricsBridge.overlayWidth,
                'height': WindowsDesktopLyricsBridge.overlayWindowHeight,
              };
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      await persistOverlayWindowPosition();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getDouble(WindowsDesktopLyricsBridge.windowLeftPrefKey),
        123.0,
      );
      expect(
        prefs.getDouble(WindowsDesktopLyricsBridge.windowTopPrefKey),
        456.0,
      );
      // 活坐标 = 现行语义：三枚键必须同一次落盘置位（漏置会让下次启动
      // 把该坐标当迁移前旧值再减 248px）。
      expect(
        prefs.getBool(WindowsDesktopLyricsBridge.windowInsetMigratedPrefKey),
        isTrue,
      );
      expect(
        prefs.getBool(WindowsDesktopLyricsBridge.windowTallMigratedPrefKey),
        isTrue,
      );
      expect(
        prefs.getBool(
          WindowsDesktopLyricsBridge.windowMenuProgressRowMigratedPrefKey,
        ),
        isTrue,
      );
    });

    test('全链路回归：全新安装首次落盘后，第二次启动不再上跳 248px', () async {
      // 复现历史 bug 的最小链路：全新安装 → 子窗落盘活坐标（用户拖动，或
      // 关闭悬浮窗时的补存）→ 第二次启动。旧实现在第三步会把现行语义坐标
      // 再迁移一遍，歌词整体上跳 36+212=248px。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const primary = Rect.fromLTWH(0, 0, 1920, 1080);
      const defaultOrigin = Offset(570, 624);
      const channel = MethodChannel('window_manager');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getBounds') {
              return <String, dynamic>{
                'x': 400.0,
                'y': 700.0,
                'width': WindowsDesktopLyricsBridge.overlayWidth,
                'height': WindowsDesktopLyricsBridge.overlayWindowHeight,
              };
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      // 1) 首次启动：无存量坐标，用默认落点，只置位语义键。
      final firstStart =
          await WindowsDesktopLyricsBridge.loadStoredOverlayOrigin(
            visibleAreas: const [primary],
            fallback: defaultOrigin,
          );
      expect(firstStart, isNull);

      // 2) 子窗落盘用户的活坐标 (400, 700)。
      await persistOverlayWindowPosition();

      // 3) 第二次启动：坐标原样恢复，不再迁移。
      final secondStart =
          await WindowsDesktopLyricsBridge.loadStoredOverlayOrigin(
            visibleAreas: const [primary],
            fallback: defaultOrigin,
          );
      expect(secondStart, const Offset(400, 700));
    });
  });

  group('锁定态靠近悬浮「🔒 解锁」胶囊与鼠标动态穿透', () {
    /// 卡片带顶边的全局坐标 = 窗口顶边 + 常驻菜单带高度。
    ///
    /// 光标坐标全部由它推导：菜单带高度变化（历史上 172 → 212）时不必
    /// 逐个改硬编码数字，测试也不至于因为窗口长高 40px 就假失败。
    double cardBandTop(Offset windowPos) =>
        windowPos.dy +
        (WindowsDesktopLyricsBridge.overlayWindowHeight -
            WindowsDesktopLyricsBridge.overlayHeight);

    testWidgets('光标在窗口外时胶囊不可见 (opacity 0.0)', (tester) async {
      Offset? cursorPos = const Offset(0, 0);
      const windowPos = Offset(100, 100);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LockedLyricsBody(
              settings: const DesktopLyricsSettings(locked: true),
              current: '当前歌词',
              next: '下一句歌词',
              onToggleLock: (_) {},
              cursorPositionProvider: () async => cursorPos,
              windowPositionProvider: () async => windowPos,
            ),
          ),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      // 80ms 定时轮询
      await tester.pump(const Duration(milliseconds: 80));

      final opacityFinder = find.descendant(
        of: find.byType(LockedLyricsBody),
        matching: find.byType(AnimatedOpacity),
      );
      expect(opacityFinder, findsOneWidget);
      expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 0.0);
    });

    testWidgets('光标移入窗口内时胶囊淡入可见 (opacity 1.0)', (tester) async {
      Offset? cursorPos = const Offset(0, 0);
      const windowPos = Offset(100, 100);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LockedLyricsBody(
              settings: const DesktopLyricsSettings(locked: true),
              current: '当前歌词',
              next: '下一句歌词',
              onToggleLock: (_) {},
              cursorPositionProvider: () async => cursorPos,
              windowPositionProvider: () async => windowPos,
            ),
          ),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pump(const Duration(milliseconds: 80));
      final opacityFinder = find.descendant(
        of: find.byType(LockedLyricsBody),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 0.0);

      // 光标移入卡片带内（卡片带 = 窗口底部 124 高，非胶囊横向范围 (200, …)）
      cursorPos = Offset(200, cardBandTop(windowPos) + 60);
      await tester.pump(const Duration(milliseconds: 80));
      // 推进 AnimatedOpacity 动画 180ms
      await tester.pump(const Duration(milliseconds: 180));

      expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 1.0);
    });

    testWidgets('解锁胶囊锚定卡片顶专属带（bottom: 歌词带高度，高 36）且防遮挡', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LockedLyricsBody(
              settings: const DesktopLyricsSettings(locked: true),
              current: '当前歌词',
              next: '下一句歌词',
              onToggleLock: (_) {},
            ),
          ),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      // 胶囊所在 Positioned = 卡片顶专属带：贴卡片顶（bottom = 歌词带高度 88），
      // 带高 lyricsTopInset(36)。
      final pillBandFinder = find.descendant(
        of: find.byType(LockedLyricsBody),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Positioned &&
              w.bottom == WindowsDesktopLyricsBridge.overlayLyricsHeight &&
              w.height == WindowsDesktopLyricsBridge.lyricsTopInset,
        ),
      );
      expect(pillBandFinder, findsOneWidget);

      final containerFinder = find.descendant(
        of: find.byType(LockedLyricsBody),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.borderRadius ==
                  BorderRadius.circular(12.0),
        ),
      );
      expect(containerFinder, findsOneWidget);
      final container = tester.widget<Container>(containerFinder);
      expect(container.constraints?.maxHeight, 24.0);
      expect(container.constraints?.maxWidth, 84.0);
    });

    testWidgets('光标悬浮在胶囊上时触发 setIgnoreMouseEvents(false)', (tester) async {
      const windowPos = Offset(100, 100);
      Offset? cursorPos = Offset(200, cardBandTop(windowPos) + 60);
      final mouseEventsCalls = <bool>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LockedLyricsBody(
              settings: const DesktopLyricsSettings(locked: true),
              current: '当前歌词',
              next: '下一句歌词',
              onToggleLock: (_) {},
              cursorPositionProvider: () async => cursorPos,
              windowPositionProvider: () async => windowPos,
              ignoreMouseEventsSetter: (ignore) async =>
                  mouseEventsCalls.add(ignore),
            ),
          ),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pump(const Duration(milliseconds: 80));
      expect(mouseEventsCalls, isEmpty);

      // 胶囊水平居中于卡片带顶：pillLeft = 100 + (780 - 84)/2 = 448,
      // 卡片带顶 = 100 + 212 = 312，pillTop = 312 + 2 = 314, pillHeight = 24
      // 光标移入胶囊矩形内 (450, 320)
      cursorPos = Offset(450, cardBandTop(windowPos) + 8);
      await tester.pump(const Duration(milliseconds: 80));

      expect(mouseEventsCalls, contains(false));
      expect(mouseEventsCalls.last, isFalse);

      // 光标在胶囊上方但在卡片带内 (450, 312) 恢复穿透
      // （卡片带顶 312 <= 312 < pillTop = 314）
      cursorPos = Offset(450, cardBandTop(windowPos));
      await tester.pump(const Duration(milliseconds: 80));
      expect(mouseEventsCalls.last, isTrue);
    });

    testWidgets('设置外部重推后胶囊悬浮可恢复（穿透死锁回归）', (tester) async {
      const windowPos = Offset(100, 100);
      Offset? cursorPos = Offset(450, cardBandTop(windowPos) + 8);
      final mouseEventsCalls = <bool>[];

      Widget buildWith({required double opacity}) => MaterialApp(
        home: Scaffold(
          body: LockedLyricsBody(
            settings: DesktopLyricsSettings(locked: true, opacity: opacity),
            current: '当前歌词',
            next: '下一句歌词',
            onToggleLock: (_) {},
            cursorPositionProvider: () async => cursorPos,
            windowPositionProvider: () async => windowPos,
            ignoreMouseEventsSetter: (ignore) async =>
                mouseEventsCalls.add(ignore),
          ),
        ),
      );

      await tester.pumpWidget(buildWith(opacity: 1.0));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      // 悬浮胶囊：穿透解除（false）
      await tester.pump(const Duration(milliseconds: 80));
      expect(mouseEventsCalls.last, isFalse);

      // 主窗推送设置更新（如拖动不透明度滑杆）：updateSettings 会无条件
      // 重施 setIgnoreMouseEvents(true)（外部写入，不经过 setter 记录）。
      await tester.pumpWidget(buildWith(opacity: 0.9));
      await tester.pump(const Duration(milliseconds: 80));

      // 光标仍在胶囊上：轮询必须把它当作"新进入胶囊"重新解除穿透，
      // 否则本地 hover 标记仍为 true，穿透永远恢复不了（胶囊死锁）。
      expect(mouseEventsCalls.last, isFalse);
      expect(mouseEventsCalls.where((c) => !c).length, greaterThanOrEqualTo(2));
    });

    testWidgets('点击胶囊触发 onToggleLock(false)', (tester) async {
      const windowPos = Offset(100, 100);
      Offset? cursorPos = Offset(450, cardBandTop(windowPos) + 8);
      bool? toggledLock;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LockedLyricsBody(
              settings: const DesktopLyricsSettings(locked: true),
              current: '当前歌词',
              next: '下一句歌词',
              onToggleLock: (locked) => toggledLock = locked,
              cursorPositionProvider: () async => cursorPos,
              windowPositionProvider: () async => windowPos,
              ignoreMouseEventsSetter: (ignore) async {},
            ),
          ),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 180));

      await tester.tap(find.text('解锁'));
      await tester.pump();

      expect(toggledLock, isFalse);
    });

    testWidgets('光标离开窗口时胶囊淡出且恢复 setIgnoreMouseEvents(true)', (tester) async {
      const windowPos = Offset(100, 100);
      Offset? cursorPos = Offset(450, cardBandTop(windowPos) + 8);
      final mouseEventsCalls = <bool>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LockedLyricsBody(
              settings: const DesktopLyricsSettings(locked: true),
              current: '当前歌词',
              next: '下一句歌词',
              onToggleLock: (_) {},
              cursorPositionProvider: () async => cursorPos,
              windowPositionProvider: () async => windowPos,
              ignoreMouseEventsSetter: (ignore) async =>
                  mouseEventsCalls.add(ignore),
            ),
          ),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      // 悬浮在胶囊上
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 180));
      expect(mouseEventsCalls.last, isFalse);

      final opacityFinder = find.descendant(
        of: find.byType(LockedLyricsBody),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 1.0);

      // 光标移出窗口
      cursorPos = const Offset(0, 0);
      await tester.pump(const Duration(milliseconds: 80));

      expect(mouseEventsCalls.last, isTrue);

      await tester.pump(const Duration(milliseconds: 180));
      expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 0.0);
    });
  });
}
