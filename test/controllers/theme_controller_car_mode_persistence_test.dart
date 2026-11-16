import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/services/device_info_service.dart';
import 'package:shiyin_music/ui/form_factor.dart';

/// 依次返回预设结果，超出后重复最后一个（模拟"通道就绪后补判成功"）。
class _FakeDeviceInfo extends DeviceInfoService {
  _FakeDeviceInfo(this.results);

  final List<bool?> results;
  int calls = 0;

  @override
  Future<bool?> isAutomotive({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    final index = calls < results.length ? calls : results.length - 1;
    calls++;
    return results[index];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  group('车机模式默认值与持久化（issue #24）', () {
    test('首次安装在车机上默认开启，并把自动判定结果落盘', () async {
      final theme = ThemeController();
      await theme.detectAutomotive(_FakeDeviceInfo([true]));
      await theme.load();

      expect(theme.carModeEnabled, isTrue, reason: '车机首次安装应默认开启');
      expect(theme.hasExplicitCarModeChoice, isFalse, reason: '用户还没手动选择');
      expect(theme.resolvedCarMode, isTrue);
      expect(theme.automotiveDetectionPending, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('theme.car_mode_auto_resolved'),
        isTrue,
        reason: '判定结果必须落盘，后续启动不再依赖检测通道',
      );
    });

    test('检测通道未就绪时判为未知，不落盘，补判成功后自动开启', () async {
      // audio_service 会先于 Activity 启动 Dart 入口，此刻自定义通道不存在：
      // isAutomotive 只能返回 null（未知），不能当成"不是车机"。
      final theme = ThemeController();
      await theme.detectAutomotive(_FakeDeviceInfo([null, true]));
      await theme.load();

      expect(theme.carModeEnabled, isFalse, reason: '未知时先按关闭显示');
      expect(theme.automotiveDetectionPending, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.containsKey('theme.car_mode_auto_resolved'),
        isFalse,
        reason: '未知结果不能落盘，否则车机会被永久判成手机',
      );

      // 补判成功后必须通知 UI，否则布局不会自己切过去。
      var notified = 0;
      void listener() => notified++;
      theme.addListener(listener);
      addTearDown(() => theme.removeListener(listener));

      // 首帧后补判：通道就绪，判定为车机。
      await theme.recheckAutomotiveIfPending(attempts: 2, delay: Duration.zero);
      expect(theme.automotiveDetectionPending, isFalse);
      expect(theme.carModeEnabled, isTrue, reason: '补判成功后应自动进入车机模式');
      expect(prefs.getBool('theme.car_mode_auto_resolved'), isTrue);
      expect(notified, greaterThan(0), reason: '补判结果要驱动界面重建');
    });

    test('已落盘的车机判定不因下次检测失败而回退', () async {
      final first = ThemeController();
      await first.detectAutomotive(_FakeDeviceInfo([true]));
      await first.load();
      expect(first.carModeEnabled, isTrue);

      // 第二次启动：通道又没就绪（返回 null），但上次的判定已经落盘。
      final second = ThemeController();
      await second.detectAutomotive(_FakeDeviceInfo([null]));
      await second.load();
      expect(second.carModeEnabled, isTrue, reason: '车机模式不能因为一次检测失败就自己变回关闭');
      expect(second.automotiveDetectionPending, isTrue);
    });

    test('用户显式选择优先于自动判定，不会被自动结果翻盘', () async {
      final theme = ThemeController();
      await theme.detectAutomotive(_FakeDeviceInfo([true]));
      await theme.load();
      expect(theme.carModeEnabled, isTrue);

      expect(await theme.setCarModeEnabled(false), isTrue);
      expect(theme.carModeEnabled, isFalse);
      expect(theme.hasExplicitCarModeChoice, isTrue);

      // 下次启动即使自动判定仍是车机，也尊重用户关掉的选择。
      final next = ThemeController();
      await next.detectAutomotive(_FakeDeviceInfo([true]));
      await next.load();
      expect(next.carModeEnabled, isFalse);
      expect(next.isAutomotiveDevice, isTrue, reason: '设备识别结果仍应保留');
    });

    test('老用户手动开过车机模式：检测失败也保持开启', () async {
      // 老键存在 = 用户显式选择过，升级后语义必须完全不变。
      SharedPreferences.setMockInitialValues({'theme.car_mode_enabled': true});
      final theme = ThemeController();
      await theme.detectAutomotive(_FakeDeviceInfo([null]));
      await theme.load();

      expect(theme.hasExplicitCarModeChoice, isTrue);
      expect(theme.carModeEnabled, isTrue);
      expect(theme.automotiveDetectionPending, isTrue);

      // 补判失败（通道始终没就绪）也不能把用户的开启回退成关闭。
      await theme.recheckAutomotiveIfPending(attempts: 2, delay: Duration.zero);
      expect(theme.carModeEnabled, isTrue);
    });

    test('桌面形态恒关闭（残留开关值不劫持 PC 布局）', () async {
      SharedPreferences.setMockInitialValues({'theme.car_mode_enabled': true});
      debugDesktopFormFactorOverride = true;

      final theme = ThemeController();
      await theme.load();
      expect(theme.carModeEnabled, isFalse);
      expect(theme.hasExplicitCarModeChoice, isTrue);
    });

    test('补判在非待判状态下是空操作', () async {
      final theme = ThemeController();
      final probe = _FakeDeviceInfo([true]);
      await theme.detectAutomotive(probe);
      await theme.load();
      final callsBefore = probe.calls;

      await theme.recheckAutomotiveIfPending(attempts: 3, delay: Duration.zero);
      expect(probe.calls, callsBefore, reason: '结果已确定就不该再打通道');
    });

    test('递增重试：通道晚几次才就绪也能补判成功', () async {
      // 引擎由音频服务在无 Activity 时先跑：前几次查询都问不出来，
      // 用户打开界面（通道注册）后才拿到结果。
      final probe = _FakeDeviceInfo([null, null, null, true]);
      final theme = ThemeController();
      await theme.detectAutomotive(probe);
      await theme.load();
      expect(theme.carModeEnabled, isFalse);
      expect(theme.automotiveDetectionPending, isTrue);

      await theme.recheckAutomotiveIfPending(
        delays: const [
          Duration.zero,
          Duration.zero,
          Duration.zero,
          Duration.zero,
        ],
      );
      expect(probe.calls, 4);
      expect(theme.carModeEnabled, isTrue);
      expect(theme.automotiveDetectionPending, isFalse);
    });

    test('补判链不会并发叠加（首帧与回前台同时触发）', () async {
      final probe = _FakeDeviceInfo([null]);
      final theme = ThemeController();
      await theme.detectAutomotive(probe);
      await theme.load();
      final callsBefore = probe.calls;

      final first = theme.recheckAutomotiveIfPending(
        delays: const [Duration.zero, Duration.zero],
      );
      final second = theme.recheckAutomotiveIfPending(
        delays: const [Duration.zero, Duration.zero],
      );
      await Future.wait([first, second]);

      expect(
        probe.calls - callsBefore,
        lessThanOrEqualTo(2),
        reason: '第二条链应直接返回，不能叠加打通道',
      );
    });
  });
}
