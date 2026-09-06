import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/form_factor.dart';

void main() {
  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  test('默认跟随平台（测试宿主为 Windows 桌面）', () {
    debugDesktopFormFactorOverride = null;
    // flutter test 在宿主 OS 上运行；CI/本机均为 Windows → true。
    // 若未来在非桌面宿主跑测试，此断言需按宿主调整。
    expect(isDesktopFormFactor, isTrue);
  });

  test('override 强制非桌面', () {
    debugDesktopFormFactorOverride = false;
    expect(isDesktopFormFactor, isFalse);
  });

  test('override 强制桌面', () {
    debugDesktopFormFactorOverride = true;
    expect(isDesktopFormFactor, isTrue);
  });

  test('isDesktopPlatform 真实反映宿主平台', () {
    expect(isDesktopPlatform, isTrue);
    debugDesktopFormFactorOverride = false;
    // isDesktopPlatform 不受 debugDesktopFormFactorOverride 影响
    expect(isDesktopPlatform, isTrue);
  });
}
