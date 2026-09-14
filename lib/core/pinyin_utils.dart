import 'package:lpinyin/lpinyin.dart';

/// 拼音缓存条目上限：曲库/歌单排序会把每个歌名都塞进缓存，长会话下
/// 无上限缓存会涨到数百 KB 级。命中/写入均把条目移到 Map 尾部
/// （LinkedHashMap 插入序 = LRU 序），超限时逐条淘汰最旧条目。
const int _kPinyinCacheLimit = 2048;

/// 拼音工具类，用于中文字符串按首字母拼音排序
class PinyinUtils {
  /// map 字面量即 LinkedHashMap（插入序），配合命中移尾实现 LRU。
  static final Map<String, String> _pinyinCache = <String, String>{};

  /// 获取字符串的拼音排序 Key（转为小写、无声调）
  static String getPinyinSortKey(String input) {
    if (input.isEmpty) return '';

    // 命中即移到尾部（最近使用）；LinkedHashMap 迭代序 = LRU 序。
    final cached = _pinyinCache.remove(input);
    if (cached != null) {
      _pinyinCache[input] = cached;
      return cached;
    }

    final value = _computePinyinSortKey(input);
    _pinyinCache[input] = value;
    // 淘汰最旧（Map 头部）条目，直到回到上限内。
    while (_pinyinCache.length > _kPinyinCacheLimit) {
      _pinyinCache.remove(_pinyinCache.keys.first);
    }
    return value;
  }

  static String _computePinyinSortKey(String input) {
    try {
      final pinyin = PinyinHelper.getPinyinE(
        input,
        separator: '',
        defPinyin: '',
        format: PinyinFormat.WITHOUT_TONE,
      );
      return pinyin.toLowerCase();
    } catch (_) {
      return input.toLowerCase();
    }
  }

  /// 按拼音顺序比较两个字符串
  /// 优先比较拼音 Key，拼音相同时按原字符串兜底比较
  static int comparePinyin(String a, String b) {
    final keyA = getPinyinSortKey(a);
    final keyB = getPinyinSortKey(b);
    final result = keyA.compareTo(keyB);
    if (result != 0) return result;
    return a.compareTo(b);
  }
}
