import 'package:lpinyin/lpinyin.dart';

/// 拼音工具类，用于中文字符串按首字母拼音排序
class PinyinUtils {
  static final Map<String, String> _pinyinCache = {};

  /// 获取字符串的拼音排序 Key（转为小写、无声调）
  static String getPinyinSortKey(String input) {
    if (input.isEmpty) return '';
    return _pinyinCache.putIfAbsent(input, () {
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
    });
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
