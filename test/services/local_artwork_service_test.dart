import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/local_artwork_service.dart';

/// [root] 下的全部文件（递归）。
List<File> _filesIn(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .toList();

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

  group('系统媒体会话封面落盘（issue #34）', () {
    late Directory root;
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
    final png = Uint8List.fromList(
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9],
    );

    setUp(() {
      root = Directory.systemTemp.createTempSync('shiyin_localart_test');
      LocalArtworkService.debugSystemArtRootOverride = () async => root;
      LocalArtworkService.debugSystemArtByteCapOverride = null;
      // 走 Android 分支（通道取图），不碰 Rust 引擎。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      LocalArtworkService.debugSystemArtRootOverride = null;
      LocalArtworkService.debugSystemArtByteCapOverride = null;
      debugDefaultTargetPlatformOverride = null;
      root.deleteSync(recursive: true);
    });

    test('内嵌图原样落盘为 file URI，扩展名按魔数识别', () async {
      reply = jpeg;
      final uri = await LocalArtworkService.systemArtUriFor('/m/a.mp3');

      expect(uri, isNotNull);
      expect(uri!.scheme, 'file');
      final file = File(uri.toFilePath());
      expect(file.path, startsWith(root.path));
      expect(file.parent.path, endsWith('localart'));
      expect(file.path, endsWith('.jpg'));
      expect(await file.readAsBytes(), jpeg);
    });

    test('文件名是读取目标的 sha1：同一目标稳定复用，不同目标互不覆盖', () async {
      reply = jpeg;
      final a = await LocalArtworkService.systemArtUriFor('/m/a.mp3');
      final b = await LocalArtworkService.systemArtUriFor('/m/b.mp3');
      final again = await LocalArtworkService.systemArtUriFor('/m/a.mp3');
      // Android 10 上同一首歌可能按 content:// 读，是另一份独立文件。
      final byContentUri = await LocalArtworkService.systemArtUriFor(
        'content://media/external/audio/media/7',
      );

      expect(again, a);
      expect(b, isNot(a));
      expect(byContentUri, isNot(a));
      expect(
        Uri.parse(a.toString()).pathSegments.last,
        '${sha1.convert(utf8.encode('/m/a.mp3'))}.jpg',
      );
    });

    test('再次取用不再解析音频，也不重复写盘、不留 .tmp 残片', () async {
      reply = png;
      final first = await LocalArtworkService.systemArtUriFor('/m/b.flac');
      final second = await LocalArtworkService.systemArtUriFor('/m/b.flac');

      expect(second, first);
      expect(first.toString(), endsWith('.png'));
      expect(calls, 1);
      final files = _filesIn(root);
      expect(files, hasLength(1));
      expect(files.single.path, isNot(endsWith('.tmp')));
    });

    test('确定无图 / 通道报错 / 取不到缓存目录都返回 null 且不落盘', () async {
      reply = null;
      expect(await LocalArtworkService.systemArtUriFor('/m/none.mp3'), isNull);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'getEmbeddedCover') return null;
        throw PlatformException(code: 'cover_failed', message: 'io');
      });
      expect(await LocalArtworkService.systemArtUriFor('/m/broken.mp3'), isNull);

      // 读图正常但拿不到缓存目录（path_provider 通道不可用）：同样不外抛。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'getEmbeddedCover') return null;
        return jpeg;
      });
      LocalArtworkService.debugSystemArtRootOverride =
          () async => throw StateError('no path_provider channel');
      await expectLater(
        LocalArtworkService.systemArtUriFor('/m/a.mp3'),
        completion(isNull),
      );

      expect(_filesIn(root), isEmpty);
    });

    test('超过上限时淘汰最久未用的，刚写的那张一定保留', () async {
      final dir = Directory(
        '${root.path}/${LocalArtworkService.systemArtDirName}',
      )..createSync(recursive: true);
      final base = DateTime(2026, 1, 1);
      for (var i = 0; i < 64; i++) {
        final file = File('${dir.path}/old_$i.jpg')..writeAsBytesSync([i]);
        file.setLastModifiedSync(base.add(Duration(minutes: i)));
      }

      reply = jpeg;
      final written = (await LocalArtworkService.systemArtUriFor('/m/new.mp3'))!;

      // 函数返回时淘汰已收尾：文件数回到上限。
      final names =
          _filesIn(root).map((file) => file.uri.pathSegments.last).toList();
      expect(names, hasLength(64));
      expect(names, isNot(contains('old_0.jpg')), reason: '最旧的先淘汰');
      expect(names, containsAll(['old_1.jpg', 'old_63.jpg']));
      expect(names, contains(written.pathSegments.last));
    });

    test('超过字节上限时同样按最久未用淘汰，刚写的那张一定保留', () async {
      LocalArtworkService.debugSystemArtByteCapOverride = 1000;
      final dir = Directory(
        '${root.path}/${LocalArtworkService.systemArtDirName}',
      )..createSync(recursive: true);
      final base = DateTime(2026, 1, 1);
      for (var i = 0; i < 3; i++) {
        final file = File('${dir.path}/old_$i.jpg')
          ..writeAsBytesSync(List<int>.filled(600, i));
        file.setLastModifiedSync(base.add(Duration(minutes: i)));
      }

      reply = jpeg;
      final written = (await LocalArtworkService.systemArtUriFor('/m/new.mp3'))!;

      final names =
          _filesIn(root).map((file) => file.uri.pathSegments.last).toList();
      // 3 × 600B + 新图 7B > 1000B：淘汰最旧的两张，保留最新旧图 + 新图。
      expect(names, hasLength(2));
      expect(names, isNot(contains('old_0.jpg')));
      expect(names, isNot(contains('old_1.jpg')));
      expect(names, contains('old_2.jpg'));
      expect(names, contains(written.pathSegments.last));
    });
  });

  group('imageExtensionForBytes 按魔数识别', () {
    test('jpg/png/webp/gif/bmp，其余与过短输入返回 null', () {
      String? ext(List<int> bytes) =>
          LocalArtworkService.imageExtensionForBytes(bytes);

      expect(ext([0xFF, 0xD8, 0xFF, 0xE0]), 'jpg');
      expect(ext([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), 'png');
      // RIFF....WEBP：RIFF 容器里第 8~11 字节才是格式标识。
      expect(
        ext([0x52, 0x49, 0x46, 0x46, 0x10, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]),
        'webp',
      );
      // RIFF 但不是 WEBP（如 WAV）不能认成图片。
      expect(
        ext([0x52, 0x49, 0x46, 0x46, 0x10, 0, 0, 0, 0x57, 0x41, 0x56, 0x45]),
        isNull,
      );
      expect(ext([0x47, 0x49, 0x46, 0x38, 0x39]), 'gif');
      expect(ext([0x42, 0x4D, 1, 2]), 'bmp');
      expect(ext([0, 1, 2, 3, 4, 5]), isNull);
      expect(ext([0xFF]), isNull);
      expect(ext(const []), isNull);
    });
  });
}
