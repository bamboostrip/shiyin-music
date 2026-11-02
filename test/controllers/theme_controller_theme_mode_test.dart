import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';

/// 外观模式（跟随系统 / 浅色 / 深色）单测。
///
/// 用真实 [ThemeController] + mock SharedPreferences 验证默认值、持久化、
/// 重启后恢复与非法值回落，不跨用例复用实例。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认跟随系统：老用户升级后行为不变', () async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    await theme.load();

    expect(theme.themeMode, ThemeMode.system);
    expect(theme.themeModeLabel, '跟随系统');
  });

  test('切换深色 / 浅色：状态、标签与持久化同步，重新加载后保持', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ThemeController();
    await first.load();

    await first.setThemeMode(ThemeMode.dark);
    expect(first.themeMode, ThemeMode.dark);
    expect(first.themeModeLabel, '深色模式');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme.mode'), 'dark');

    // 新建实例重新加载，模拟应用重启后恢复上次选择。
    final second = ThemeController();
    await second.load();
    expect(second.themeMode, ThemeMode.dark);
    expect(second.themeModeLabel, '深色模式');

    await second.setThemeMode(ThemeMode.light);
    expect(second.themeMode, ThemeMode.light);
    expect(second.themeModeLabel, '浅色模式');
    expect(prefs.getString('theme.mode'), 'light');

    final third = ThemeController();
    await third.load();
    expect(third.themeMode, ThemeMode.light);
    expect(third.themeModeLabel, '浅色模式');

    // 还能切回跟随系统，且持久化为 system。
    await third.setThemeMode(ThemeMode.system);
    expect(third.themeMode, ThemeMode.system);
    expect(third.themeModeLabel, '跟随系统');
    expect(prefs.getString('theme.mode'), 'system');
  });

  test('非法持久化值回落跟随系统（手改 prefs 不会把界面调坏）', () async {
    SharedPreferences.setMockInitialValues({'theme.mode': 'amoled'});
    final theme = ThemeController();
    await theme.load();

    expect(theme.themeMode, ThemeMode.system);
    expect(theme.themeModeLabel, '跟随系统');
    // 空串同样视为非法值。
    SharedPreferences.setMockInitialValues({'theme.mode': ''});
    final empty = ThemeController();
    await empty.load();
    expect(empty.themeMode, ThemeMode.system);
  });

  test('重复设置相同值不触发 notifyListeners', () async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    await theme.load();
    var notified = 0;
    theme.addListener(() => notified++);

    // 默认已是 system，重复设置应直接返回。
    await theme.setThemeMode(ThemeMode.system);
    expect(notified, 0);
    expect(theme.themeMode, ThemeMode.system);

    await theme.setThemeMode(ThemeMode.dark);
    expect(notified, 1);

    // 再设一次相同值不重复通知。
    await theme.setThemeMode(ThemeMode.dark);
    expect(notified, 1);
    expect(theme.themeMode, ThemeMode.dark);
  });
}
