import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/ui/form_factor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 本机跑的是 Windows 宿主，默认 isDesktopFormFactor=true 会让车机
    // 显示 getter 恒返回中性值；这里按移动形态验证真实读写。
    debugDesktopFormFactorOverride = false;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  test('默认值中性：老用户升级与普通用户零感知', () async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    await theme.load();

    expect(theme.carDisplayScale, 1.0);
    expect(theme.carMarginTop, 0.0);
    expect(theme.carMarginBottom, 0.0);
    expect(theme.hasCustomCarDisplay, isFalse);
  });

  test('缩放只接受白名单档位，留白钳制在 0~100', () async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    await theme.load();

    await theme.setCarDisplayScale(1.15);
    expect(theme.carDisplayScale, 1.15);

    await theme.setCarDisplayScale(1.23); // 非白名单档位
    expect(theme.carDisplayScale, 1.0);

    await theme.setCarMarginTop(150);
    expect(theme.carMarginTop, 100.0);

    await theme.setCarMarginTop(-8);
    expect(theme.carMarginTop, 0.0);

    await theme.setCarMarginBottom(45);
    expect(theme.carMarginBottom, 45.0);
  });

  test('持久化、恢复默认与重新加载', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ThemeController();
    await first.load();
    await first.setCarDisplayScale(1.3);
    await first.setCarMarginTop(30);
    await first.setCarMarginBottom(24);

    final second = ThemeController();
    await second.load();
    expect(second.carDisplayScale, 1.3);
    expect(second.carMarginTop, 30.0);
    expect(second.carMarginBottom, 24.0);
    expect(second.hasCustomCarDisplay, isTrue);

    await second.resetCarDisplay();
    expect(second.carDisplayScale, 1.0);
    expect(second.carMarginTop, 0.0);
    expect(second.carMarginBottom, 0.0);
    expect(second.hasCustomCarDisplay, isFalse);

    final third = ThemeController();
    await third.load();
    expect(third.hasCustomCarDisplay, isFalse);
  });

  test('非法持久化值回落默认（手改 prefs 不会把界面调坏）', () async {
    SharedPreferences.setMockInitialValues({
      'theme.car_display_scale': 7.5,
      'theme.car_margin_top': 999.0,
      'theme.car_margin_bottom': -3.0,
    });
    final theme = ThemeController();
    await theme.load();

    expect(theme.carDisplayScale, 1.0);
    expect(theme.carMarginTop, 100.0);
    expect(theme.carMarginBottom, 0.0);
  });

  test('桌面形态恒为中性值：移动端残留不劫持 PC 布局', () async {
    debugDesktopFormFactorOverride = true;
    SharedPreferences.setMockInitialValues({
      'theme.car_display_scale': 1.3,
      'theme.car_margin_top': 40.0,
      'theme.car_margin_bottom': 20.0,
    });
    final theme = ThemeController();
    await theme.load();

    expect(theme.carDisplayScale, 1.0);
    expect(theme.carMarginTop, 0.0);
    expect(theme.carMarginBottom, 0.0);
    expect(theme.hasCustomCarDisplay, isFalse);
  });
}
