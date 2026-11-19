// #15 Flyme Auto（ECARX）媒体中心接入：EAS Binder 回调 → MethodChannel →
// Dart 播控分发 / 原生日志落盘 / 状态上行载荷（lib/services/car_media_center_service.dart）。
//
// 用 TestDefaultBinaryMessenger 双向模拟：下行（原生→Dart）模拟方向盘
// 按键与日志推送；上行（Dart→原生）用 mock handler 捕获 pushState 载荷。
// 平台判定经构造参数注入（host 测试进程不是 Android）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyin_music/services/car_media_center_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(CarMediaCenterService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 排空平台通道的异步往返。
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 模拟原生下发的控制动作。
  Future<void> pushControlFromNative(String action) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onControl', {'action': action, 'source': 'test'}),
      ),
      (ByteData? data) {},
    );
    await settle();
  }

  /// 模拟原生下发的日志行。
  Future<void> pushLogFromNative(String line) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('onLog', line)),
      (ByteData? data) {},
    );
    await settle();
  }

  /// 上行调用的捕获器：记录 (method, args)。
  final uplink = <(String, Object?)>[];

  void mockUplink() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      uplink.add((call.method, call.arguments));
      return null;
    });
  }

  CarMediaCenterService attachService(
    List<String> calls, {
    void Function(String line)? onLog,
  }) {
    return CarMediaCenterService(channel: channel, isAndroid: true)
      ..attach(
        onPlay: () async => calls.add('play'),
        onPause: () async => calls.add('pause'),
        onNext: () async => calls.add('next'),
        onPrevious: () async => calls.add('previous'),
        onLog: onLog,
      );
  }

  tearDown(() {
    channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
    uplink.clear();
  });

  group('Android 平台控制分发（方向盘按键）', () {
    test('attach 后 isAttached/isSupported 为 true', () {
      final service = attachService(<String>[]);
      expect(service.isSupported, isTrue);
      expect(service.isAttached, isTrue);
      service.detach();
    });

    test('四个控制动作命中对应回调', () async {
      final calls = <String>[];
      final service = attachService(calls);

      for (final action in [
        CarMediaCenterService.actionNext,
        CarMediaCenterService.actionPrevious,
        CarMediaCenterService.actionPlay,
        CarMediaCenterService.actionPause,
      ]) {
        calls.clear();
        await pushControlFromNative(action);
        expect(calls, <String>[action], reason: 'action=$action');
      }
      service.detach();
    });

    test('未知动作与缺失参数静默忽略', () async {
      final calls = <String>[];
      final service = attachService(calls);

      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('onControl', 'not-a-map')),
        (ByteData? data) {},
      );
      await pushControlFromNative('fastForward');
      await settle();

      expect(calls, isEmpty);
      service.detach();
    });

    test('播控回调抛异常被吞掉，后续按键仍正常分发', () async {
      final calls = <String>[];
      final service = CarMediaCenterService(channel: channel, isAndroid: true)
        ..attach(
          onPlay: () async => throw StateError('播放器未就绪'),
          onPause: () async => calls.add('pause'),
          onNext: () async => calls.add('next'),
          onPrevious: () async => calls.add('previous'),
        );

      await pushControlFromNative(CarMediaCenterService.actionPlay);
      expect(calls, isEmpty);

      await pushControlFromNative(CarMediaCenterService.actionNext);
      expect(calls, <String>['next']);
      service.detach();
    });

    test('detach 后不再分发，且可重复 detach / 重新 attach', () async {
      final calls = <String>[];
      final service = attachService(calls);

      service.detach();
      service.detach();
      await pushControlFromNative(CarMediaCenterService.actionNext);
      expect(calls, isEmpty);

      service.attach(
        onPlay: () async => calls.add('play'),
        onPause: () async => calls.add('pause'),
        onNext: () async => calls.add('next'),
        onPrevious: () async => calls.add('previous'),
      );
      await pushControlFromNative(CarMediaCenterService.actionNext);
      expect(calls, <String>['next']);
      service.detach();
    });
  });

  group('原生日志转发（AppLogService 诊断出口）', () {
    test('onLog 行透传给注入的回调', () async {
      final lines = <String>[];
      final service = attachService(<String>[], onLog: lines.add);

      await pushLogFromNative('[eas] 已连接 descriptor=IEASFrameworkService');

      expect(lines, hasLength(1));
      expect(lines.single, contains('IEASFrameworkService'));
      service.detach();
    });

    test('空行与 detach 后的日志不再转发', () async {
      final lines = <String>[];
      final service = attachService(<String>[], onLog: lines.add);

      await pushLogFromNative('');
      expect(lines, isEmpty);

      service.detach();
      await pushLogFromNative('[焦点] …');
      expect(lines, isEmpty);
    });
  });

  group('状态上行（Dart→原生）', () {
    test('pushState 载荷完整，lyric 为 null 时键省略', () async {
      mockUplink();
      final service = attachService(<String>[]);

      await service.pushState(
        title: '晴天',
        artist: '周杰伦',
        durationMs: 269000,
        positionMs: 1200,
        playing: true,
      );

      expect(uplink, hasLength(1));
      final (method, rawArgs) = uplink.single;
      expect(method, 'pushState');
      final args = rawArgs! as Map<Object?, Object?>;
      expect(args['title'], '晴天');
      expect(args['artist'], '周杰伦');
      expect(args['album'], '');
      expect(args['durationMs'], 269000);
      expect(args['positionMs'], 1200);
      expect(args['playing'], true);
      expect(args['speed'], 1.0);
      expect(args.containsKey('lyric'), isFalse,
          reason: '未提供歌词时必须省略键，原生侧保留上次 LRC');
      service.detach();
    });

    test('pushState 附带歌词与当前行', () async {
      mockUplink();
      final service = attachService(<String>[]);

      await service.pushState(
        title: 't',
        artist: 'a',
        durationMs: 1,
        positionMs: 0,
        playing: false,
        lyric: '[00:01.00]line',
        lyricLine: 'line',
      );

      final args = uplink.single.$2! as Map<Object?, Object?>;
      expect(args['lyric'], '[00:01.00]line');
      expect(args['lyricLine'], 'line');
      service.detach();
    });

    test('notifyPlayStarted / notifyPaused 走对应原生方法', () async {
      mockUplink();
      final service = attachService(<String>[]);

      await service.notifyPlayStarted();
      await service.notifyPaused();

      expect(uplink.map((e) => e.$1).toList(),
          <String>['notifyPlayStarted', 'notifyPaused']);
      service.detach();
    });
  });

  group('非 Android 平台', () {
    test('attach/上行全部 no-op', () async {
      mockUplink();
      final calls = <String>[];
      final service = CarMediaCenterService(channel: channel, isAndroid: false)
        ..attach(
          onPlay: () async => calls.add('play'),
          onPause: () async => calls.add('pause'),
          onNext: () async => calls.add('next'),
          onPrevious: () async => calls.add('previous'),
        );

      expect(service.isSupported, isFalse);
      expect(service.isAttached, isFalse);

      await pushControlFromNative(CarMediaCenterService.actionNext);
      expect(calls, isEmpty);

      await service.notifyPlayStarted();
      await service.pushState(
        title: 't',
        artist: 'a',
        durationMs: 0,
        positionMs: 0,
        playing: false,
      );
      expect(uplink, isEmpty, reason: '非 Android 不得触达平台通道');
      service.detach();
    });
  });

  group('CarMediaControlGate（外部播控去重）', () {
    test('窗口内同动作折叠、不同动作互不影响、窗口外放行', () {
      var now = DateTime(2026, 11, 19, 12, 0, 0);
      final gate = CarMediaControlGate(now: () => now);

      expect(gate.shouldRun('next'), isTrue);
      expect(gate.shouldRun('next'), isFalse,
          reason: 'EAS 与 MediaSession 双路由的第二次 next 必须折叠');

      // 不同动作不受 'next' 窗口影响。
      expect(gate.shouldRun('previous'), isTrue);

      // 越过窗口后放行（真实连按方向盘两次的间隔远大于窗口）。
      now = now.add(const Duration(milliseconds: 301));
      expect(gate.shouldRun('next'), isTrue);
    });

    test('reset 清空窗口状态', () {
      var now = DateTime(2026, 11, 19, 12, 0, 0);
      final gate = CarMediaControlGate(now: () => now);
      expect(gate.shouldRun('play'), isTrue);
      expect(gate.shouldRun('play'), isFalse);
      gate.reset();
      expect(gate.shouldRun('play'), isTrue);
    });
  });
}
