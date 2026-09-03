import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/ui/desktop/desktop_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('无存储值时返回 null', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(DesktopWindowGeometry.load(prefs), isNull);
  });

  test('save 后 load 返回原值', () async {
    final prefs = await SharedPreferences.getInstance();
    const geometry = DesktopWindowGeometry(
      left: 120.0,
      top: 80.0,
      width: 1280.0,
      height: 800.0,
    );
    await geometry.save(prefs);
    expect(DesktopWindowGeometry.load(prefs), geometry);
  });

  test('非法尺寸被拒绝（小于最小窗口视为无效）', () async {
    final prefs = await SharedPreferences.getInstance();
    const bad = DesktopWindowGeometry(
      left: 0,
      top: 0,
      width: 320.0,
      height: 200.0,
    );
    await bad.save(prefs);
    expect(DesktopWindowGeometry.load(prefs), isNull);
  });

  test('reset 清空存储', () async {
    final prefs = await SharedPreferences.getInstance();
    const geometry = DesktopWindowGeometry(
      left: 120.0,
      top: 80.0,
      width: 1280.0,
      height: 800.0,
    );
    await geometry.save(prefs);
    await DesktopWindowGeometry.reset(prefs);
    expect(DesktopWindowGeometry.load(prefs), isNull);
  });
}
