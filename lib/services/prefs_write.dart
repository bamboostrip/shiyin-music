import 'package:flutter/foundation.dart' show listEquals;
import 'package:shared_preferences/shared_preferences.dart';

/// `prefs.setX` 的「值没变就不写」版本。
///
/// ## 为什么需要
///
/// Windows 的 shared_preferences 实现是纯 Dart 的：**每次 `setX` 都会把
/// 整张 map 重新 `json.encode` 并同步写盘**。文件越用越大（历史版本里
/// 十几 MB），单次写入就会阻塞 UI 线程数百毫秒。
///
/// 而启动/恢复流程里有大量"写回同样的值"的调用：未变化的登录 token、
/// 已恢复的收藏列表、同一份歌单缓存……这类调用对功能毫无意义，却要付出
/// 一次整文件重写的代价。统一改用这里的 IfChanged 版本即可整次跳过。
///
/// 语义与 `setX` 保持一致：返回 true 表示确实写了，false 表示值未变跳过。
extension PrefsWriteIfChanged on SharedPreferences {
  Future<bool> setStringIfChanged(String key, String value) async {
    if (getString(key) == value) return false;
    return setString(key, value);
  }

  Future<bool> setBoolIfChanged(String key, bool value) async {
    if (getBool(key) == value) return false;
    return setBool(key, value);
  }

  Future<bool> setIntIfChanged(String key, int value) async {
    if (getInt(key) == value) return false;
    return setInt(key, value);
  }

  Future<bool> setDoubleIfChanged(String key, double value) async {
    if (getDouble(key) == value) return false;
    return setDouble(key, value);
  }

  Future<bool> setStringListIfChanged(String key, List<String> value) async {
    final current = getStringList(key);
    if (current != null && listEquals(current, value)) return false;
    return setStringList(key, value);
  }

  /// 键不存在时也返回 false（无写入）。
  Future<bool> removeIfExists(String key) async {
    if (!containsKey(key)) return false;
    return remove(key);
  }
}
