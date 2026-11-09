import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/song.dart';
import 'package:shiyin_music/services/lyric_cache_service.dart';

/// 歌词文件缓存（每首歌一个 JSON，不进 SharedPreferences）。
void main() {
  final service = LyricCacheService.instance;
  late Directory tmp;

  LyricLine line(int timeMs, String text) =>
      LyricLine(time: Duration(milliseconds: timeMs), text: text);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('shiyin_lyric_cache_');
    service.debugReset();
    service.configure(1024 * 1024);
    service.debugOverrideDirectory(tmp);
  });

  tearDown(() async {
    service.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  List<File> cacheFiles() => tmp
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .toList();

  group('LyricCacheService', () {
    test('写入后可读回（内容一致）', () async {
      final lines = [line(0, '第一句'), line(1000, '第二句')];

      await service.write('ABC123', lines);
      final cached = await service.read('ABC123');

      expect(cached, isNotNull);
      expect(cached!.length, 2);
      expect(cached[0].text, '第一句');
      expect(cached[1].time, const Duration(milliseconds: 1000));
    });

    test('未命中返回 null', () async {
      expect(await service.read('NOT_EXIST'), isNull);
    });

    test('不安全 hash 不落盘也不读盘（防目录穿越）', () async {
      await service.write('../evil', [line(0, 'x')]);
      expect(cacheFiles(), isEmpty);
      expect(await service.read('../evil'), isNull);
    });

    test('空歌词不落盘', () async {
      await service.write('EMPTY', const []);
      expect(cacheFiles(), isEmpty);
    });

    test('文件损坏按未命中处理', () async {
      await File('${tmp.path}${Platform.pathSeparator}BROKEN.json')
          .writeAsString('{not json');
      expect(await service.read('BROKEN'), isNull);
    });

    test('count / totalBytes 统计文件', () async {
      await service.write('A', [line(0, 'a')]);
      await service.write('B', [line(0, 'b')]);

      expect(await service.count(), 2);
      expect(await service.totalBytes(), greaterThan(0));
    });

    test('clear 删除全部缓存文件', () async {
      await service.write('A', [line(0, 'a')]);
      await service.clear();

      expect(await service.count(), 0);
      expect(await service.totalBytes(), 0);
      expect(await service.read('A'), isNull);
    });

    test('未配置（disabled）时不读写', () async {
      service.debugReset();

      await service.write('A', [line(0, 'a')]);
      expect(await service.read('A'), isNull);
      expect(await service.totalBytes(), 0);
      expect(cacheFiles(), isEmpty);
    });

    test('prune 按 TTL 删除过期条目', () async {
      await service.write('OLD', [line(0, 'old')]);
      await service.write('FRESH', [line(0, 'fresh')]);
      // 把 OLD 的 mtime 改到 31 天前。
      final oldFile = File('${tmp.path}${Platform.pathSeparator}OLD.json');
      await oldFile.setLastModified(
        DateTime.now().subtract(const Duration(days: 31)),
      );

      await service.prune();

      expect(await service.read('OLD'), isNull);
      expect(await service.read('FRESH'), isNotNull);
    });

    test('prune 超容量时按最旧优先淘汰到 80%', () async {
      service.debugReset();
      service.configure(1000); // 1KB 上限，便于构造
      service.debugOverrideDirectory(tmp);

      // 每条歌词约 100+ 字节，写 20 条远超上限。
      for (var i = 0; i < 20; i++) {
        await service.write('H$i', [
          line(0, '这是一条测试歌词内容 ${'x' * 40}'),
        ]);
        // 让 mtime 递增，保证淘汰顺序确定。
        await File('${tmp.path}${Platform.pathSeparator}H$i.json')
            .setLastModified(DateTime.now().add(Duration(seconds: i)));
      }
      final before = await service.totalBytes();
      expect(before, greaterThan(1000));

      await service.prune();

      final after = await service.totalBytes();
      expect(after, lessThanOrEqualTo(1000));
      expect(after, lessThanOrEqualTo(800 + 200)); // 目标 80%，留一点文件系统误差
      // 最新的 H19 一定还在。
      expect(await service.read('H19'), isNotNull);
    });

    test('prune 清理写盘残留的临时文件', () async {
      final junk =
          File('${tmp.path}${Platform.pathSeparator}A.json.tmp');
      await junk.writeAsString('partial');

      await service.prune();

      expect(junk.existsSync(), isFalse);
    });
  });
}
