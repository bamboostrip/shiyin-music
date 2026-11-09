// CacheService.write 的两个降本行为（Windows 上每次写 prefs 都会整文件 JSON
// 编解码，文件大时单次数百毫秒）：
// 1) payload 未变则跳过写入（savedAt 不刷新）；
// 2) 按前缀条数上限淘汰最旧条目，防止 prefs 重新膨胀。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/config/app_config.dart';
import 'package:shiyin_music/services/cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<int> savedAtOf(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    expect(raw, isNotNull, reason: '$key 应存在');
    return (jsonDecode(raw!) as Map<String, dynamic>)['savedAt'] as int;
  }

  group('CacheService.write 去重', () {
    test('payload 未变不重写：savedAt 保持不变', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = CacheService();

      await service.write('cache_user_1', {'name': 'a', 'n': 1});
      final firstSavedAt = await savedAtOf('cache_user_1');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await service.write('cache_user_1', {'name': 'a', 'n': 1});

      expect(await savedAtOf('cache_user_1'), firstSavedAt);
    });

    test('payload 变化时正常重写：savedAt 前进', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = CacheService();

      await service.write('cache_user_1', {'name': 'a'});
      final firstSavedAt = await savedAtOf('cache_user_1');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await service.write('cache_user_1', {'name': 'b'});

      expect(
        await savedAtOf('cache_user_1'),
        greaterThan(firstSavedAt),
      );
      final prefs = await SharedPreferences.getInstance();
      final decoded =
          jsonDecode(prefs.getString('cache_user_1')!) as Map<String, dynamic>;
      expect(decoded['payload'], {'name': 'b'});
    });

    test('缓存损坏时按不一致处理，正常覆盖修复', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cache_user_1': '{broken',
      });
      final service = CacheService();

      await service.write('cache_user_1', {'name': 'a'});

      final prefs = await SharedPreferences.getInstance();
      final decoded =
          jsonDecode(prefs.getString('cache_user_1')!) as Map<String, dynamic>;
      expect(decoded['payload'], {'name': 'a'});
    });

    test('内容未变但 savedAt 太旧时仍写一次（刷新最后校验时间）', () async {
      // 预置 1 小时前的同内容缓存：超过 cacheSavedAtRefreshAfter。
      final oldSavedAt = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cache_playlist_1_full': jsonEncode({
          'savedAt': oldSavedAt,
          'payload': {'songs': <Object>[]},
        }),
      });
      final service = CacheService();

      await service.write('cache_playlist_1_full', {'songs': <Object>[]});

      expect(await savedAtOf('cache_playlist_1_full'), greaterThan(oldSavedAt));
    });
  });

  group('CacheService.write 前缀条数上限', () {
    test('超过上限时淘汰最旧条目（按 savedAt）', () async {
      final prefix = 'cache_album_';
      final cap = AppConfig.dataCachePrefixCaps[prefix]!;
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      // 预置 cap 条旧缓存（savedAt 递增）。
      for (var i = 0; i < cap; i++) {
        await prefs.setString(
          '$prefix$i',
          jsonEncode({'savedAt': 1000 + i, 'payload': {'i': i}}),
        );
      }

      // 再写一条新 id：总数 cap+1，应淘汰 savedAt 最小的 $prefix0。
      final service = CacheService();
      await service.write('${prefix}new', {'fresh': true});

      final keys = prefs.getKeys().where((k) => k.startsWith(prefix)).toList();
      expect(keys.length, cap);
      expect(keys, isNot(contains('${prefix}0')));
      expect(keys, contains('${prefix}new'));
      expect(keys, contains('${prefix}1'));
    });

    test('未超过上限不淘汰', () async {
      final prefix = 'cache_artist_';
      final cap = AppConfig.dataCachePrefixCaps[prefix]!;
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final service = CacheService();

      for (var i = 0; i < cap; i++) {
        await service.write('$prefix$i', {'i': i});
      }

      expect(
        prefs.getKeys().where((k) => k.startsWith(prefix)).length,
        cap,
      );
    });
  });
}
