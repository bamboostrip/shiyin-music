import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyin_music/services/download_service.dart';

/// 本地 Range 感知文件服务器（模拟酷狗 CDN）。
class _RangeFileServer {
  _RangeFileServer(this.data, {required this.honorRange});

  final List<int> data;
  final bool honorRange;
  HttpServer? _server;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) async {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      if (range != null && honorRange) {
        start = int.tryParse(range.replaceFirst('bytes=', '').split('-').first) ?? 0;
      }
      if (start >= data.length) {
        req.response.statusCode = 416;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${data.length}',
        );
        await req.response.close();
        return;
      }
      req.response.statusCode =
          range != null && honorRange ? 206 : HttpStatus.ok;
      if (range != null && honorRange) {
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${data.length - 1}/${data.length}',
        );
      }
      req.response.headers.contentLength = data.length - start;
      // 分块推送：让"收到首个进度回调即取消"的用例能在中途被打断。
      const chunkSize = 16 * 1024;
      for (var offset = start; offset < data.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, data.length);
        req.response.add(
          Uint8List.fromList(data.sublist(offset, end)),
        );
        await req.response.flush();
      }
      await req.response.close();
    });
    return 'http://127.0.0.1:${server.port}/audio.mp3';
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}

void main() {
  // 纯 IO 测试（本地 HttpServer + 真实 dio）：不能初始化
  // TestWidgetsFlutterBinding——它会劫持 HttpClient 全部返回 400。
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
  ));

  tearDownAll(() => dio.close());

  group('resolveResumeOffset', () {
    test('已有 .part 且服务器 206 才续传', () {
      expect(
        DownloadService.resolveResumeOffset(
            existingPartLength: 100, statusCode: 206),
        100,
      );
    });

    test('服务器忽略 Range 返回 200 时必须整包重写', () {
      expect(
        DownloadService.resolveResumeOffset(
            existingPartLength: 100, statusCode: 200),
        0,
      );
    });

    test('无已有 .part 一律从 0 开始', () {
      expect(
        DownloadService.resolveResumeOffset(existingPartLength: 0, statusCode: 206),
        0,
      );
    });
  });

  group('downloadWithResume（本地服务器）', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('shiyin_dl_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('全新下载：字节完整、进度单调', () async {
      final data = List<int>.generate(64 * 1024, (i) => i % 251);
      final server = _RangeFileServer(data, honorRange: true);
      final url = await server.start();
      addTearDown(server.stop);
      final partPath = '${tempDir.path}/a.mp3.part';

      final progresses = <int>[];
      await DownloadService.downloadWithResume(
        dio: dio,
        url: url,
        partPath: partPath,
        onProgress: (received, total) => progresses.add(received),
      );

      expect(File(partPath).readAsBytesSync(), data);
      // 进度事件 received 单调不减。
      for (var i = 1; i < progresses.length; i++) {
        expect(progresses[i], greaterThanOrEqualTo(progresses[i - 1]));
      }
    });

    test('中断后续传（服务器支持 Range）：最终文件与原始字节一致（回归：dio FileMode.write 截断损坏）', () async {
      final data = List<int>.generate(128 * 1024, (i) => (i * 7) % 253);
      final server = _RangeFileServer(data, honorRange: true);
      final url = await server.start();
      addTearDown(server.stop);
      final partPath = '${tempDir.path}/b.mp3.part';

      // 第一次：收到首段进度后取消，留下 .part。
      final cancelToken = CancelToken();
      try {
        await DownloadService.downloadWithResume(
          dio: dio,
          url: url,
          partPath: partPath,
          onProgress: (received, total) {
            cancelToken.cancel();
          },
          cancelToken: cancelToken,
        );
        fail('取消后应抛出异常');
      } on DioException {
        // 预期：取消。
      }
      final partLength = File(partPath).lengthSync();
      expect(partLength, greaterThan(0));
      expect(partLength, lessThan(data.length));

      // 第二次：续传完成后文件必须等于完整原始字节。
      // 旧实现（dio.download + FileMode.write 截断 + Range 头）在这里产出
      // "只有后半段"的损坏文件。
      await DownloadService.downloadWithResume(
        dio: dio,
        url: url,
        partPath: partPath,
      );

      expect(File(partPath).readAsBytesSync(), data);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('服务器忽略 Range（返回 200 全量）：有脏 .part 也不追加，整包重写', () async {
      final data = List<int>.generate(32 * 1024, (i) => i % 199);
      final server = _RangeFileServer(data, honorRange: false);
      final url = await server.start();
      addTearDown(server.stop);
      final partPath = '${tempDir.path}/c.mp3.part';

      // 预置脏 .part（模拟上次中断遗留）。
      File(partPath).writeAsBytesSync(List<int>.filled(4096, 9));

      await DownloadService.downloadWithResume(
        dio: dio,
        url: url,
        partPath: partPath,
      );

      expect(File(partPath).readAsBytesSync(), data);
    });
  });

  group('resolveNonCollidingPath', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('shiyin_name_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('目标不存在 → 原名', () async {
      final service = DownloadService();
      final partPath = '${tempDir.path}/song.mp3.part';
      File(partPath).writeAsBytesSync(List<int>.filled(10, 1));
      expect(
        service.resolveNonCollidingPath('${tempDir.path}/song.mp3', partPath),
        '${tempDir.path}/song.mp3',
      );
    });

    test('目标存在且大小相同（同歌重下）→ 覆盖原名', () async {
      final service = DownloadService();
      final target = File('${tempDir.path}/song.mp3')
        ..writeAsBytesSync(List<int>.filled(10, 1));
      final partPath = '${tempDir.path}/song.mp3.part';
      File(partPath).writeAsBytesSync(List<int>.filled(10, 1));
      expect(
        service.resolveNonCollidingPath(target.path, partPath),
        target.path,
      );
    });

    test('目标存在但大小不同（同名不同歌）→ 换名不覆盖', () async {
      final service = DownloadService();
      final target = File('${tempDir.path}/song.mp3')
        ..writeAsBytesSync(List<int>.filled(999, 1));
      final partPath = '${tempDir.path}/song.mp3.part';
      File(partPath).writeAsBytesSync(List<int>.filled(10, 1));
      final resolved = service.resolveNonCollidingPath(target.path, partPath);
      expect(resolved, '${tempDir.path}/song (2).mp3');

      // 连续碰撞继续递增。
      File(resolved).writeAsBytesSync(List<int>.filled(1, 1));
      expect(
        service.resolveNonCollidingPath(target.path, partPath),
        '${tempDir.path}/song (3).mp3',
      );
    });
  });

  group('sanitizeFileName', () {
    final service = DownloadService();

    test('剥离控制字符（Windows CreateFile 拒绝、Linux 合法的分叉）', () {
      expect(service.sanitizeFileName('ac\ndc\nboom'), 'acdcboom');
      expect(service.sanitizeFileName('a\x00b\x1fc'), 'abc');
      expect(service.sanitizeFileName('正常歌名'), '正常歌名');
    });

    test('非法字符替换与压缩语义保持', () {
      expect(service.sanitizeFileName('AC/DC: Back In Black'), 'AC_DC_ Back In Black');
      expect(service.sanitizeFileName('__x__'), 'x');
    });

    test('超长截断到上限且不留尾部下划线', () {
      final long = '风' * 300;
      final sanitized = service.sanitizeFileName(long);
      expect(sanitized.length, lessThanOrEqualTo(120));
      expect(sanitized.endsWith('_'), isFalse);
    });
  });
}
