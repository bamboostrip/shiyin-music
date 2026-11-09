import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/config/app_config.dart';
import 'package:shiyin_music/services/prefs_compaction.dart';

/// prefs 瘦身规则（issue：PC 启动卡顿，见 PrefsCompaction 文档）。
void main() {
  /// 构造一条 cache 值：`{"savedAt": <ms>, "payload": {...}}`。
  String cacheValue(int savedAt) =>
      jsonEncode({'savedAt': savedAt, 'payload': {'v': savedAt}});

  group('PrefsCompaction.plan', () {
    test('删除歌词缓存，保留设置与单条缓存', () {
      final raw = <String, dynamic>{
        'flutter.shiyin_token': 'tok',
        'flutter.cache_home': cacheValue(1),
        'flutter.cache_radio': cacheValue(2),
        'flutter.cache_lyric_AAA': cacheValue(3),
        'flutter.cache_lyric_BBB': cacheValue(4),
        'flutter.playback_history': '[1,2,3]',
      };

      final result = PrefsCompaction.plan(raw);

      expect(result.droppedLyricKeys, 2);
      expect(result.evictedCacheKeys, 0);
      expect(result.changed, isTrue);
      expect(result.map.keys, isNot(contains('flutter.cache_lyric_AAA')));
      expect(result.map.keys, isNot(contains('flutter.cache_lyric_BBB')));
      expect(result.map['flutter.shiyin_token'], 'tok');
      expect(result.map['flutter.cache_home'], isNotNull);
      expect(result.map['flutter.cache_radio'], isNotNull);
      expect(result.map['flutter.playback_history'], '[1,2,3]');
      // 不改动入参（调用方可能还要用原始 map）。
      expect(raw.keys, contains('flutter.cache_lyric_AAA'));
    });

    test('兼容没有 flutter. 前缀的 key', () {
      final result = PrefsCompaction.plan(<String, dynamic>{
        'cache_lyric_AAA': cacheValue(1),
        'setting': true,
      });
      expect(result.droppedLyricKeys, 1);
      expect(result.map.containsKey('cache_lyric_AAA'), isFalse);
      expect(result.map['setting'], true);
    });

    test('按前缀上限淘汰最旧条目，保留最新 N 条', () {
      final cap = AppConfig.dataCachePrefixCaps['cache_playlist_collection_']!;
      final raw = <String, dynamic>{
        for (var i = 0; i < cap + 5; i++)
          'flutter.cache_playlist_collection_$i': cacheValue(i),
      };

      final result = PrefsCompaction.plan(raw);

      expect(result.evictedCacheKeys, 5);
      // 保留 savedAt 最大的 cap 条（i = 5..cap+4）。
      for (var i = 0; i < 5; i++) {
        expect(
          result.map.containsKey('flutter.cache_playlist_collection_$i'),
          isFalse,
          reason: '最旧的 $i 应被淘汰',
        );
      }
      for (var i = 5; i < cap + 5; i++) {
        expect(
          result.map.containsKey('flutter.cache_playlist_collection_$i'),
          isTrue,
        );
      }
    });

    test('未超上限不动', () {
      final cap = AppConfig.dataCachePrefixCaps['cache_album_']!;
      final result = PrefsCompaction.plan(<String, dynamic>{
        for (var i = 0; i < cap; i++) 'flutter.cache_album_$i': cacheValue(i),
      });
      expect(result.evictedCacheKeys, 0);
      expect(result.changed, isFalse);
    });

    test('最长前缀优先：cache_playlist_collection_ 不被算进 cache_playlist_', () {
      final playlistCap = AppConfig.dataCachePrefixCaps['cache_playlist_']!;
      final raw = <String, dynamic>{
        // 恰好等于上限的普通歌单缓存（不应被 collection 的淘汰波及）。
        for (var i = 0; i < playlistCap; i++)
          'flutter.cache_playlist_$i': cacheValue(i),
        // 集合缓存也恰好等于上限。
        for (var i = 0; i < playlistCap; i++)
          'flutter.cache_playlist_collection_$i': cacheValue(i),
      };

      final result = PrefsCompaction.plan(raw);

      expect(result.changed, isFalse);
      expect(
        result.map.length,
        raw.length,
        reason: 'collection 条目若被归到 cache_playlist_ 组会被误删',
      );
    });

    test('损坏/非 JSON 的缓存值按最旧处理', () {
      final cap = AppConfig.dataCachePrefixCaps['cache_artist_']!;
      final raw = <String, dynamic>{
        for (var i = 0; i < cap; i++)
          'flutter.cache_artist_$i': cacheValue(1000 + i),
        'flutter.cache_artist_broken': 'not-json',
      };

      final result = PrefsCompaction.plan(raw);

      expect(result.evictedCacheKeys, 1);
      expect(
        result.map.containsKey('flutter.cache_artist_broken'),
        isFalse,
        reason: '解析不出 savedAt 的条目视为最旧',
      );
    });

    test('settings 等非 cache 前缀永远不动', () {
      final result = PrefsCompaction.plan(<String, dynamic>{
        'flutter.shiyin_token': 'tok',
        'flutter.settings.desktop_roots': '["D:/Music"]',
        'flutter.playback_state': '{"queue":[]}',
      });
      expect(result.changed, isFalse);
      expect(result.map.length, 3);
    });

    test('总字符预算超限时按 savedAt 从旧到新淘汰', () {
      // 构造两条各 3MB 的缓存（条数远低于上限，但总量 6MB 超 4MB 预算）。
      final big = 'x' * (3 * 1024 * 1024);
      final result = PrefsCompaction.plan(<String, dynamic>{
        'flutter.cache_home': '{"savedAt":1000,"payload":{"a":"$big"}}',
        'flutter.cache_radio': '{"savedAt":2000,"payload":{"a":"$big"}}',
        'flutter.shiyin_token': 'tok',
      });

      expect(result.evictedForBudget, greaterThan(0));
      expect(result.changed, isTrue);
      // 最旧的 cache_home 先出局，最新的 cache_radio 保留。
      expect(result.map.containsKey('flutter.cache_home'), isFalse);
      expect(result.map.containsKey('flutter.cache_radio'), isTrue);
      expect(result.map['flutter.shiyin_token'], 'tok');
    });
  });

  group('PrefsCompaction.runIfNeeded', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shiyin_prefs_compact_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    File prefsFile() =>
        File('${tmp.path}${Platform.pathSeparator}shared_preferences.json');

    test('超过阈值时删除歌词缓存并原子落盘', () async {
      await prefsFile().writeAsString(
        jsonEncode(<String, dynamic>{
          'flutter.shiyin_token': 'tok',
          'flutter.cache_lyric_AAA': cacheValue(1),
          'flutter.cache_home': cacheValue(2),
        }),
      );

      final result = await PrefsCompaction.runIfNeeded(
        overrideDir: tmp,
        thresholdBytes: 0,
      );

      expect(result, isNotNull);
      expect(result!.droppedLyricKeys, 1);
      final written =
          jsonDecode(await prefsFile().readAsString()) as Map<String, dynamic>;
      expect(written.containsKey('flutter.cache_lyric_AAA'), isFalse);
      expect(written['flutter.shiyin_token'], 'tok');
      expect(written.containsKey('flutter.cache_home'), isTrue);
      // 临时文件不残留。
      expect(
        File('${prefsFile().path}.compact.tmp').existsSync(),
        isFalse,
      );
    });

    test('未超过阈值不读写文件', () async {
      final content = jsonEncode(<String, dynamic>{
        'flutter.shiyin_token': 'tok',
      });
      await prefsFile().writeAsString(content);

      final result = await PrefsCompaction.runIfNeeded(
        overrideDir: tmp,
        thresholdBytes: 1024 * 1024,
      );

      expect(result, isNull);
      expect(await prefsFile().readAsString(), content);
    });

    test('小于阈值但残留旧版歌词缓存时也会清理', () async {
      await prefsFile().writeAsString(
        jsonEncode(<String, dynamic>{
          'flutter.shiyin_token': 'tok',
          'flutter.cache_lyric_AAA': cacheValue(1),
        }),
      );

      final result = await PrefsCompaction.runIfNeeded(
        overrideDir: tmp,
        thresholdBytes: 1024 * 1024,
      );

      expect(result, isNotNull);
      expect(result!.droppedLyricKeys, 1);
      final written =
          jsonDecode(await prefsFile().readAsString()) as Map<String, dynamic>;
      expect(written.containsKey('flutter.cache_lyric_AAA'), isFalse);
      expect(written['flutter.shiyin_token'], 'tok');
    });

    test('没东西可删时不重写文件', () async {
      final content = jsonEncode(<String, dynamic>{
        'flutter.shiyin_token': 'tok',
      });
      await prefsFile().writeAsString(content);
      final before = await prefsFile().lastModified();

      final result = await PrefsCompaction.runIfNeeded(
        overrideDir: tmp,
        thresholdBytes: 0,
      );

      expect(result, isNull);
      expect(await prefsFile().readAsString(), content);
      expect(await prefsFile().lastModified(), before);
    });

    test('文件不存在时安全返回 null', () async {
      final result = await PrefsCompaction.runIfNeeded(
        overrideDir: tmp,
        thresholdBytes: 0,
      );
      expect(result, isNull);
    });

    test('非法 JSON 不抛异常、不改文件', () async {
      const broken = '{not json';
      await prefsFile().writeAsString(broken);

      final result = await PrefsCompaction.runIfNeeded(
        overrideDir: tmp,
        thresholdBytes: 0,
      );

      expect(result, isNull);
      expect(await prefsFile().readAsString(), broken);
    });
  });
}
