// AI / 外部 DeepLink（shiyin://）解析与分发：
// - 解析是纯函数：非法 scheme/host/空参数静默返回 null；
// - 分发通过注入回调完成，不依赖真实 PlayerController / 网络；
// - 原生通道（冷启动 getInitialLink / 热启动 onDeepLink）用 mock 通道模拟。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/deep_link_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(DeepLinkService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 排空平台通道往返（getInitialLink/onDeepLink 都是异步下发）。
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 模拟原生侧主动推送热启动链接（singleTop onNewIntent → onDeepLink）。
  Future<void> pushFromNative(String link) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(DeepLinkService.methodOnDeepLink, link),
      ),
      (ByteData? data) {},
    );
    await settle();
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('DeepLinkService.parse', () {
    test('play?keyword 解析为播放指令', () {
      final command = DeepLinkService.parse('shiyin://play?keyword=晴天');

      expect(command, isA<DeepLinkPlayCommand>());
      expect((command as DeepLinkPlayCommand).query, '晴天');
    });

    test('play?song / q / title 为兼容别名', () {
      for (final key in ['song', 'q', 'title']) {
        final command = DeepLinkService.parse('shiyin://play?$key=七里香');
        expect(command, isA<DeepLinkPlayCommand>(), reason: '别名 $key');
        expect((command as DeepLinkPlayCommand).query, '七里香');
      }
    });

    test('百分号编码的中文正确解码，首尾空白被 trim', () {
      final command = DeepLinkService.parse(
        'shiyin://play?keyword=%20%E5%91%A8%E6%9D%B0%E4%BC%A6%20',
      );

      expect(command, isA<DeepLinkPlayCommand>());
      expect((command as DeepLinkPlayCommand).query, '周杰伦');
    });

    test('control 各 action 映射（含 prev/previous 别名与 cmd 别名）', () {
      const expected = <String, DeepLinkControlAction>{
        'next': DeepLinkControlAction.next,
        'prev': DeepLinkControlAction.previous,
        'previous': DeepLinkControlAction.previous,
        'play': DeepLinkControlAction.play,
        'pause': DeepLinkControlAction.pause,
        'toggle': DeepLinkControlAction.toggle,
      };
      for (final entry in expected.entries) {
        final command = DeepLinkService.parse(
          'shiyin://control?action=${entry.key}',
        );
        expect(command, isA<DeepLinkControlCommand>(), reason: entry.key);
        expect(
          (command as DeepLinkControlCommand).action,
          entry.value,
          reason: entry.key,
        );
      }

      // 上游兼容 cmd 参数名 + 大小写不敏感。
      final alias = DeepLinkService.parse('shiyin://control?cmd=NEXT');
      expect(alias, isA<DeepLinkControlCommand>());
      expect(
        (alias as DeepLinkControlCommand).action,
        DeepLinkControlAction.next,
      );
    });

    test('非法 scheme / 未知 host 静默返回 null', () {
      for (final link in [
        'kgka://play?keyword=晴天', // 上游旧 scheme
        'https://example.com/play?keyword=晴天',
        'shiyin://search?keyword=晴天', // search 未实现，维持对等不支持
        'shiyin://download?song=晴天',
        'shiyin:play?keyword=晴天', // 缺 //
      ]) {
        expect(DeepLinkService.parse(link), isNull, reason: link);
      }
    });

    test('空参数 / 未知 action / 纯垃圾串静默返回 null', () {
      for (final link in [
        'shiyin://play',
        'shiyin://play?keyword=',
        'shiyin://play?keyword=%20%20',
        'shiyin://control',
        'shiyin://control?action=',
        'shiyin://control?action=volumeup',
        'shiyin://',
        '',
        '   ',
        'not a uri at all',
        '://',
      ]) {
        expect(DeepLinkService.parse(link), isNull, reason: link);
      }
      expect(DeepLinkService.parse(null), isNull);
    });
  });

  group('DeepLinkService 分发', () {
    test('冷启动 getInitialLink：启动后向回调分发指令', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == DeepLinkService.methodGetInitialLink) {
          return 'shiyin://play?keyword=晴天';
        }
        return null;
      });
      final received = <DeepLinkCommand>[];
      final service = DeepLinkService(
        onCommand: (command) async => received.add(command),
        channel: channel,
      );

      await service.start();
      await settle();

      expect(received, hasLength(1));
      expect(received.single, isA<DeepLinkPlayCommand>());
      expect((received.single as DeepLinkPlayCommand).query, '晴天');
      service.dispose();
    });

    test('冷启动无链接（桌面/普通启动）不分发、不抛异常', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == DeepLinkService.methodGetInitialLink) return null;
        return null;
      });
      final received = <DeepLinkCommand>[];
      final service = DeepLinkService(
        onCommand: (command) async => received.add(command),
        channel: channel,
      );

      await service.start();
      await settle();

      expect(received, isEmpty);
      service.dispose();
    });

    test('Activity 重建补拉：requestInitialLink 取到暂存链接且不重复执行', () async {
      // 模拟原生侧语义：getInitialLink 返回后立即置空，第二次返回 null。
      var pending = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != DeepLinkService.methodGetInitialLink) return null;
        return pending.isEmpty ? null : pending.removeAt(0);
      });
      final received = <DeepLinkCommand>[];
      final service = DeepLinkService(
        onCommand: (command) async => received.add(command),
        channel: channel,
      );

      // 冷启动阶段没有链接（普通启动）。
      await service.start();
      await settle();
      expect(received, isEmpty);

      // 模拟 Dart 引擎存活、后台 Activity 重建时新 Activity 暂存了 VIEW intent。
      pending = <String>['shiyin://control?action=toggle'];
      await service.requestInitialLink();
      await settle();

      expect(received, hasLength(1));
      expect(received.single, isA<DeepLinkControlCommand>());
      expect(
        (received.single as DeepLinkControlCommand).action,
        DeepLinkControlAction.toggle,
      );

      // 再次补拉：原生已置空，不得重复执行同一条链接。
      await service.requestInitialLink();
      await settle();
      expect(received, hasLength(1));
      service.dispose();
    });

    test('原生无 channel（MissingPluginException）时 start 静默降级', () async {
      // 不注册 mock handler：invokeMethod 抛 MissingPluginException。
      final service = DeepLinkService(
        onCommand: (command) async {},
        channel: channel,
      );

      await expectLater(service.start(), completes);
      service.dispose();
    });

    test('热启动 onDeepLink：原生推送分发播控指令', () async {
      final received = <DeepLinkCommand>[];
      final service = DeepLinkService(
        onCommand: (command) async => received.add(command),
        channel: channel,
      );
      await service.start();
      await settle();

      await pushFromNative('shiyin://control?action=next');

      expect(received, hasLength(1));
      expect(received.single, isA<DeepLinkControlCommand>());
      expect(
        (received.single as DeepLinkControlCommand).action,
        DeepLinkControlAction.next,
      );
      service.dispose();
    });

    test('热启动非法链接：静默丢弃，不触发回调', () async {
      final received = <DeepLinkCommand>[];
      final service = DeepLinkService(
        onCommand: (command) async => received.add(command),
        channel: channel,
      );
      await service.start();
      await settle();

      await pushFromNative('https://example.com/evil');
      await pushFromNative('shiyin://play?keyword=');
      await pushFromNative('');

      expect(received, isEmpty);
      service.dispose();
    });

    test('非 onDeepLink 方法调用被忽略', () async {
      final received = <DeepLinkCommand>[];
      final service = DeepLinkService(
        onCommand: (command) async => received.add(command),
        channel: channel,
      );
      await service.start();
      await settle();

      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onVisibilityChanged', 'x'),
        ),
        (ByteData? data) {},
      );
      await settle();

      expect(received, isEmpty);
      service.dispose();
    });

    test('回调抛异常时 handleLink 吞掉异常（DeepLink 失败不得崩溃）', () async {
      final service = DeepLinkService(
        onCommand: (command) async => throw StateError('播放器未就绪'),
        channel: channel,
      );

      await expectLater(
        service.handleLink('shiyin://control?action=toggle'),
        completes,
      );
      service.dispose();
    });

    test('dispose 后不再响应原生推送', () async {
      final received = <DeepLinkCommand>[];
      final service = DeepLinkService(
        onCommand: (command) async => received.add(command),
        channel: channel,
      );
      await service.start();
      await settle();
      service.dispose();

      await pushFromNative('shiyin://control?action=pause');

      expect(received, isEmpty);
    });
  });
}
