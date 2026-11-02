import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/android_storage_access.dart';

/// Android 自定义下载目录的权限桥：通道结果解析、平台兜底与路径归属判定。
///
/// 真实权限弹窗（系统设置页）无法在单测环境复现，这里覆盖 Dart 侧决策：
/// - 原生返回的状态如何映射为「可用 / 可申请 / 不可申请」；
/// - 通道未注册或非 Android 宿主时不得抛错，按保守值回退；
/// - 应用专属目录前缀判断（免「所有文件访问」）的边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('shiyin_music/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    AndroidStorageAccess.debugForceAndroid = true;
  });

  tearDown(() {
    AndroidStorageAccess.debugForceAndroid = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('AndroidStorageAccess.status', () {
    test('Android 11 已授予「所有文件访问」', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getStatus');
        return <String, Object?>{
          'sdkInt': 31,
          'granted': true,
          'canRequest': true,
        };
      });

      final status = await AndroidStorageAccess.status();
      expect(status.sdkInt, 31);
      expect(status.granted, isTrue);
      expect(status.canRequest, isTrue);
      expect(status.supported, isTrue);
      expect(await AndroidStorageAccess.hasSharedStorageAccess(), isTrue);
    });

    test('Android 10：不可申请，supported 为 false', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{
          'sdkInt': 29,
          'granted': false,
          'canRequest': false,
        };
      });

      final status = await AndroidStorageAccess.status();
      expect(status.granted, isFalse);
      expect(status.canRequest, isFalse);
      expect(status.supported, isFalse);
    });

    test('未授权但可申请（Android 11 用户尚未开启）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{
          'sdkInt': 34,
          'granted': false,
          'canRequest': true,
        };
      });

      final status = await AndroidStorageAccess.status();
      expect(status.granted, isFalse);
      expect(status.canRequest, isTrue);
      expect(status.supported, isTrue);
    });

    test('原生通道未注册时不抛错，按不可用处理', () async {
      // 不设置 mock handler：调用方拿不到原生实现，应降级而不是崩溃。
      final status = await AndroidStorageAccess.status();
      expect(status.granted, isFalse);
      expect(status.canRequest, isFalse);
      expect(status.supported, isFalse);
    });
  });

  group('AndroidStorageAccess.requestAccess', () {
    test('透传原生申请结果（true / false）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'requestAccess');
        return true;
      });
      expect(await AndroidStorageAccess.requestAccess(), isTrue);

      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await AndroidStorageAccess.requestAccess(), isFalse);
    });

    test('通道未注册时返回 false（权限未获取）', () async {
      expect(await AndroidStorageAccess.requestAccess(), isFalse);
    });
  });

  group('AndroidStorageAccess.scanFile', () {
    test('把下载路径交给原生媒体库扫描', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return true;
      });

      await AndroidStorageAccess.scanFile('/storage/emulated/0/Music/a.mp3');

      expect(received?.method, 'scanFile');
      expect(received?.arguments, {'path': '/storage/emulated/0/Music/a.mp3'});
    });

    test('空路径 / 非 Android 平台不触碰原生通道', () async {
      var called = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        called = true;
        return true;
      });

      await AndroidStorageAccess.scanFile('   ');
      AndroidStorageAccess.debugForceAndroid = false;
      await AndroidStorageAccess.scanFile('/storage/emulated/0/Music/a.mp3');

      expect(called, isFalse);
    });

    test('通道异常时静默忽略，不影响下载结果', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'scan_failed');
      });

      await expectLater(
        AndroidStorageAccess.scanFile('/storage/emulated/0/Music/a.mp3'),
        completes,
      );
    });
  });

  group('平台兜底', () {
    test('非 Android 平台恒视为已授权，且不触碰原生通道', () async {
      AndroidStorageAccess.debugForceAndroid = false;
      final status = await AndroidStorageAccess.status();
      expect(status.granted, isTrue);
      expect(status.canRequest, isFalse);
      expect(status.supported, isTrue);
      expect(await AndroidStorageAccess.requestAccess(), isTrue);
    });
  });

  group('isPathWithinDirectories', () {
    const androidFiles = '/storage/emulated/0/Android/data/top.famlife/files';

    test('目录本身与子目录都算应用专属目录', () {
      expect(
        isPathWithinDirectories(androidFiles, const [androidFiles]),
        isTrue,
      );
      expect(
        isPathWithinDirectories(
          '$androidFiles/shiyin_downloads',
          const [androidFiles],
        ),
        isTrue,
      );
    });

    test('同前缀的兄弟目录不算（不能只做 startsWith）', () {
      expect(
        isPathWithinDirectories(
          '/storage/emulated/0/Android/data/top.famlife/files2/x',
          const [androidFiles],
        ),
        isFalse,
      );
      expect(
        isPathWithinDirectories('/storage/emulated/0/Music/时音', const [
          androidFiles,
        ]),
        isFalse,
      );
    });

    test('忽略末尾分隔符与反斜杠（Windows 风格路径）', () {
      expect(
        isPathWithinDirectories(
          r'D:\Music',
          const [r'D:\Music\'],
        ),
        isTrue,
      );
      expect(
        isPathWithinDirectories(
          r'D:\Music2',
          const [r'D:\Music'],
        ),
        isFalse,
      );
    });

    test('空路径 / 空目录列表返回 false', () {
      expect(isPathWithinDirectories('', const ['/tmp']), isFalse);
      expect(isPathWithinDirectories('/tmp/x', const []), isFalse);
      expect(isPathWithinDirectories('/tmp/x', const ['  ']), isFalse);
    });
  });
}
