import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/local_artwork_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('shiyin_music/local_music');
  late int calls;
  late Uint8List? reply;
  late String? lastSource;

  setUp(() {
    LocalArtworkService.debugReset();
    calls = 0;
    lastSource = null;
    reply = Uint8List.fromList(const [1, 2, 3, 4]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'getEmbeddedCover') return null;
          calls++;
          lastSource = (call.arguments as Map)['source'] as String?;
          return reply;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    LocalArtworkService.debugReset();
  });

  group('伪 URL 编解码', () {
    test('中文/空格/#/% 都能原样往返', () {
      for (final path in const [
        r'D:\Music\晴天 #1.flac',
        '/storage/emulated/0/Music/100%纯净.aiff',
        r'\\nas\music\a&b.mp3',
      ]) {
        final url = LocalArtworkService.artworkUrlFor(path);
        expect(LocalArtworkService.isArtworkUrl(url), isTrue);
        // 路径不能以明文出现在 URL 里：`#`/`%` 会被当成 fragment/转义符。
        expect(url.contains('#'), isFalse);
        expect(LocalArtworkService.targetOf(url), path);
      }
    });

    test('content:// 目标同样能原样往返', () {
      const uri = 'content://media/external/audio/media/42';
      final url = LocalArtworkService.artworkUrlFor(uri);
      expect(LocalArtworkService.isArtworkUrl(url), isTrue);
      expect(url.contains('://media'), isFalse);
      expect(LocalArtworkService.targetOf(url), uri);
    });

    test('非本服务 URL 识别与还原都返回空', () {
      expect(
        LocalArtworkService.isArtworkUrl('http://cdn/a.jpg'),
        isFalse,
      );
      expect(LocalArtworkService.isArtworkUrl(null), isFalse);
      expect(LocalArtworkService.targetOf('http://cdn/a.jpg'), isNull);
      expect(LocalArtworkService.targetOf('localart://%zz'), isNull);
      expect(LocalArtworkService.targetOf('localart://'), isNull);
    });
  });

  group('读取与缓存', () {
    test('读到字节后进程内复用，不再重复走平台通道', () async {
      final first = await LocalArtworkService.load(r'D:\m\a.mp3');
      expect(first, isNotNull);
      expect(calls, 1);
      final second = await LocalArtworkService.load(r'D:\m\a.mp3');
      // 必须复用同一实例：Image.memory 以字节对象身份做 ImageCache key。
      expect(identical(first, second), isTrue);
      expect(calls, 1);
      expect(LocalArtworkService.debugCacheStats.entries, 1);
    });

    test('无封面时记负缓存，滚动重进不会反复 probe 文件', () async {
      reply = null;
      expect(await LocalArtworkService.load(r'D:\m\noart.mp3'), isNull);
      expect(await LocalArtworkService.load(r'D:\m\noart.mp3'), isNull);
      expect(calls, 1);
      expect(LocalArtworkService.debugMissingEntries, 1);

      // 同一路径后面真的读到图了，负缓存必须让位（换文件/补标签的场景）。
      reply = Uint8List.fromList(const [9]);
      LocalArtworkService.debugReset();
      expect(await LocalArtworkService.load(r'D:\m\noart.mp3'), isNotNull);
    });

    test('并发读取同一路径只解析一次', () async {
      final results = await Future.wait([
        LocalArtworkService.load(r'D:\m\a.mp3'),
        LocalArtworkService.load(r'D:\m\a.mp3'),
        LocalArtworkService.load(r'D:\m\a.mp3'),
      ]);
      expect(results.every((bytes) => bytes != null), isTrue);
      expect(calls, 1);
    });

    test('字节预算超限时按 LRU 淘汰最旧条目', () async {
      reply = Uint8List(1024 * 1024); // 1MB/张，预算 12MB
      for (var i = 0; i < 13; i++) {
        await LocalArtworkService.load('D:\\m\\song$i.mp3');
      }
      final stats = LocalArtworkService.debugCacheStats;
      expect(stats.bytes, lessThanOrEqualTo(12 * 1024 * 1024));
      expect(stats.entries, lessThanOrEqualTo(12));
    });

    test('content:// 目标原样交给原生（Android 分区存储下唯一可读的地址）', () async {
      const uri = 'content://media/external/audio/media/42';
      await LocalArtworkService.load(uri);
      expect(calls, 1);
      expect(lastSource, uri);
    });

    test('通道报错=瞬时失败：不进负缓存，下次重试能拿到图', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        LocalArtworkService.debugReset();
        var fail = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'getEmbeddedCover') return null;
          calls++;
          if (fail) {
            throw PlatformException(code: 'cover_failed', message: 'io');
          }
          return Uint8List.fromList(const [9, 9]);
        });

        expect(await LocalArtworkService.load('/x/a.mp3'), isNull);
        expect(await LocalArtworkService.load('/x/a.mp3'), isNull);
        expect(calls, 2); // 失败不缓存 → 重进视口重试

        fail = false;
        expect(await LocalArtworkService.load('/x/a.mp3'), const [9, 9]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('通道返回 null=确定无图：照旧进负缓存', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        LocalArtworkService.debugReset();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'getEmbeddedCover') return null;
          calls++;
          return null;
        });

        expect(await LocalArtworkService.load('/y/b.flac'), isNull);
        expect(await LocalArtworkService.load('/y/b.flac'), isNull);
        expect(calls, 1); // 确定无图 → 负缓存
        expect(LocalArtworkService.debugMissingEntries, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
