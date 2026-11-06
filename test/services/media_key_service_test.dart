// #15 车机方向盘媒体键兜底：原生 Activity KeyEvent → MethodChannel →
// Dart 播控分发（lib/services/media_key_service.dart）。
//
// 用 TestDefaultBinaryMessenger 模拟「原生 → Dart」的下行方法调用，不依赖
// 真机；平台判定经构造参数注入（host 测试进程不是 Android），避免测试
// 结果随运行平台漂移。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyin_music/services/media_key_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(MediaKeyService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 排空平台通道的异步往返（handler 内部 await 播控回调）。
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 模拟 CarMediaKeyHandler 的原生下行 `channel.invokeMethod(method)`。
  Future<void> pushFromNative(String method) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (ByteData? data) {},
    );
    await settle();
  }

  /// 构造并 attach 一个服务：所有回调把命中的 method 名记进 [calls]。
  MediaKeyService attachService(List<String> calls) {
    return MediaKeyService(channel: channel, isAndroid: true)
      ..attach(
        onTogglePlay: () async => calls.add(MediaKeyService.methodTogglePlay),
        onPlay: () async => calls.add(MediaKeyService.methodPlay),
        onPause: () async => calls.add(MediaKeyService.methodPause),
        onNext: () async => calls.add(MediaKeyService.methodNext),
        onPrevious: () async => calls.add(MediaKeyService.methodPrevious),
        onStop: () async => calls.add(MediaKeyService.methodStop),
      );
  }

  tearDown(() {
    // 原生 → Dart 的 handler 按通道名注册在 BinaryMessenger 上，不随
    // channel 对象销毁，必须显式清掉，避免用例间串扰。
    channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('Android 平台分发', () {
    test('attach 后 isAttached/isSupported 为 true', () {
      final service = attachService(<String>[]);

      expect(service.isSupported, isTrue);
      expect(service.isAttached, isTrue);

      service.detach();
    });

    test('每个原生 method 命中对应的注入回调', () async {
      final calls = <String>[];
      final service = attachService(calls);

      const expected = <String, String>{
        MediaKeyService.methodNext: MediaKeyService.methodNext,
        MediaKeyService.methodPrevious: MediaKeyService.methodPrevious,
        MediaKeyService.methodTogglePlay: MediaKeyService.methodTogglePlay,
        MediaKeyService.methodPlay: MediaKeyService.methodPlay,
        MediaKeyService.methodPause: MediaKeyService.methodPause,
        MediaKeyService.methodStop: MediaKeyService.methodStop,
      };
      for (final entry in expected.entries) {
        calls.clear();
        await pushFromNative(entry.key);
        expect(calls, <String>[entry.value], reason: 'method=${entry.key}');
      }

      service.detach();
    });

    test('未知 method 不触发回调、也不抛异常', () async {
      final calls = <String>[];
      final service = attachService(calls);

      await pushFromNative('unknownMethod');
      await pushFromNative('fastForward');
      await pushFromNative('');

      expect(calls, isEmpty);
      service.detach();
    });

    test('播控回调抛异常被吞掉，后续按键仍正常分发', () async {
      final calls = <String>[];
      final service = MediaKeyService(channel: channel, isAndroid: true)
        ..attach(
          onTogglePlay: () async => throw StateError('播放器未就绪'),
          onPlay: () async => calls.add(MediaKeyService.methodPlay),
          onPause: () async => calls.add(MediaKeyService.methodPause),
          onNext: () async => calls.add(MediaKeyService.methodNext),
          onPrevious: () async => calls.add(MediaKeyService.methodPrevious),
          onStop: () async => calls.add(MediaKeyService.methodStop),
        );

      // 不抛即通过（异常若冒泡，handlePlatformMessage 的 Future 会带错）。
      await pushFromNative(MediaKeyService.methodTogglePlay);
      expect(calls, isEmpty);

      await pushFromNative(MediaKeyService.methodPlay);
      expect(calls, <String>[MediaKeyService.methodPlay]);

      service.detach();
    });

    test('detach 置空回调：之后原生下行不再触发，且可重复 detach', () async {
      final calls = <String>[];
      final service = attachService(calls);

      await pushFromNative(MediaKeyService.methodNext);
      expect(calls, <String>[MediaKeyService.methodNext]);

      service.detach();
      expect(service.isAttached, isFalse);
      // 重复 detach 应为 no-op，不抛。
      service.detach();

      await pushFromNative(MediaKeyService.methodNext);
      expect(
        calls,
        <String>[MediaKeyService.methodNext],
        reason: 'detach 后到达的媒体键不得再触发播控',
      );
    });

    test('重复 attach 不叠加触发，只使用最新回调', () async {
      final first = <String>[];
      final second = <String>[];
      final firstService = attachService(first);

      // 同一个 service 再 attach 一次：只更新回调，不重复注册 handler。
      firstService.attach(
        onTogglePlay: () async => second.add(MediaKeyService.methodTogglePlay),
        onPlay: () async => second.add(MediaKeyService.methodPlay),
        onPause: () async => second.add(MediaKeyService.methodPause),
        onNext: () async => second.add(MediaKeyService.methodNext),
        onPrevious: () async => second.add(MediaKeyService.methodPrevious),
        onStop: () async => second.add(MediaKeyService.methodStop),
      );

      await pushFromNative(MediaKeyService.methodTogglePlay);

      expect(first, isEmpty, reason: '旧回调不得再被触发');
      expect(second, <String>[MediaKeyService.methodTogglePlay]);

      firstService.detach();
    });

    test('detach 后重新 attach 可恢复分发', () async {
      final calls = <String>[];
      final service = attachService(calls);

      service.detach();
      await pushFromNative(MediaKeyService.methodNext);
      expect(calls, isEmpty);

      service.attach(
        onTogglePlay: () async => calls.add(MediaKeyService.methodTogglePlay),
        onPlay: () async => calls.add(MediaKeyService.methodPlay),
        onPause: () async => calls.add(MediaKeyService.methodPause),
        onNext: () async => calls.add(MediaKeyService.methodNext),
        onPrevious: () async => calls.add(MediaKeyService.methodPrevious),
        onStop: () async => calls.add(MediaKeyService.methodStop),
      );
      await pushFromNative(MediaKeyService.methodNext);

      expect(calls, <String>[MediaKeyService.methodNext]);
      service.detach();
    });
  });

  group('非 Android 平台', () {
    test('attach no-op：不注册 handler、不触发回调', () async {
      final calls = <String>[];
      final service = MediaKeyService(channel: channel, isAndroid: false)
        ..attach(
          onTogglePlay: () async => calls.add(MediaKeyService.methodTogglePlay),
          onPlay: () async => calls.add(MediaKeyService.methodPlay),
          onPause: () async => calls.add(MediaKeyService.methodPause),
          onNext: () async => calls.add(MediaKeyService.methodNext),
          onPrevious: () async => calls.add(MediaKeyService.methodPrevious),
          onStop: () async => calls.add(MediaKeyService.methodStop),
        );

      expect(service.isSupported, isFalse);
      expect(service.isAttached, isFalse);

      await pushFromNative(MediaKeyService.methodTogglePlay);
      expect(calls, isEmpty);

      // detach 也应为 no-op（不抛、不影响其他已注册的 handler）。
      service.detach();
    });
  });
}
