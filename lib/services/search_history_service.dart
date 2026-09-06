import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 搜索历史服务。
///
/// 使用 SharedPreferences 持久化最近 10 条搜索词，按时间倒序排列。
/// 同一关键词再次搜索时会移到最前，超出上限自动截断。
class SearchHistoryService {
  static const _key = 'search_history';
  static const _maxRecords = 10;

  /// 读取全部历史记录（最新在前，至多 [_maxRecords] 条）。
  Future<List<String>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        final items = list.whereType<String>().toList();
        if (items.length > _maxRecords) {
          return items.sublist(0, _maxRecords);
        }
        return items;
      }
    } catch (_) {}
    return [];
  }

  /// 新增一条搜索词，去重并截断至上限。
  Future<void> add(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    final history = await getHistory();
    history.remove(trimmed);
    history.insert(0, trimmed);
    if (history.length > _maxRecords) {
      history.removeRange(_maxRecords, history.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(history));
  }

  /// 删除指定搜索词。
  Future<void> remove(String keyword) async {
    final history = await getHistory();
    history.remove(keyword);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(history));
  }

  /// 清空全部历史记录。
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
