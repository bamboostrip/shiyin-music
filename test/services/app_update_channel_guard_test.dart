// 渠道包（-PcustomPackageName）运行时包名守卫：
// 非官方 applicationId 下跳过在线更新检查（自动 + 手动），避免把用户引向
// 装不上的官方 APK（不同 applicationId 覆盖安装失败，同签名会并存成第二
// 个应用）。包名经 `shiyin_music/update` 通道的 `getPackageName` 获取，
// 这里用 mock 通道模拟原生返回，不依赖真实设备与网络。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyin_music/services/app_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channel = AppUpdateService.updateChannel;

  /// 模拟原生 `getPackageName` 返回 [name]。
  void mockPackageName(String? name) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getPackageName');
      return name;
    });
  }

  /// 模拟通道异常（缺失实现 / PlatformException 等）。
  void mockChannelError(Object error) {
    messenger.setMockMethodCallHandler(channel, (call) async => throw error);
  }

  // 每例开始前清空包名缓存，保证读取的是本用例 mock 的原生返回值。
  setUp(AppUpdateService.resetOfficialPackageCacheForTest);

  // 每例结束后重置缓存与 mock 通道，避免污染后续用例。
  tearDown(() {
    AppUpdateService.resetOfficialPackageCacheForTest();
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('isOfficialPackage', () {
    test('官方包名 → true', () async {
      mockPackageName(AppUpdateService.officialPackageName);

      expect(await AppUpdateService.isOfficialPackage(), isTrue);
    });

    test('渠道自定义包名 → false', () async {
      mockPackageName('com.shiyin.channelexample');

      expect(await AppUpdateService.isOfficialPackage(), isFalse);
    });

    test('MissingPluginException（桌面/无原生实现）→ true', () async {
      mockChannelError(MissingPluginException('no implementation'));

      expect(await AppUpdateService.isOfficialPackage(), isTrue);
    });

    test('PlatformException → true', () async {
      mockChannelError(PlatformException(code: 'boom', message: '原生异常'));

      expect(await AppUpdateService.isOfficialPackage(), isTrue);
    });

    test('原生返回非字符串等意外错误 → true（兜底不拦截更新）', () async {
      // invokeMethod<String> 对非字符串结果的类型转换错误不是 PlatformException，
      // 走的是 catch (_) 兜底分支。
      messenger.setMockMethodCallHandler(channel, (call) async => 123);

      expect(await AppUpdateService.isOfficialPackage(), isTrue);
    });

    test('结果缓存：进程内只查询原生一次', () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        return AppUpdateService.officialPackageName;
      });

      expect(await AppUpdateService.isOfficialPackage(), isTrue);
      expect(await AppUpdateService.isOfficialPackage(), isTrue);
      expect(calls, 1);
    });
  });

  group('isOfficialPackageName（纯函数）', () {
    test('null / 空白 → true（拿不到包名按官方处理）', () {
      expect(AppUpdateService.isOfficialPackageName(null), isTrue);
      expect(AppUpdateService.isOfficialPackageName(''), isTrue);
      expect(AppUpdateService.isOfficialPackageName('   '), isTrue);
    });

    test('官方包名（含首尾空白）→ true', () {
      expect(
        AppUpdateService.isOfficialPackageName(AppUpdateService.officialPackageName),
        isTrue,
      );
      expect(AppUpdateService.isOfficialPackageName(' shiyin.famlife.top '), isTrue);
    });

    test('自定义包名 → false', () {
      expect(
        AppUpdateService.isOfficialPackageName('com.shiyin.channelexample'),
        isFalse,
      );
      expect(AppUpdateService.isOfficialPackageName('com.example.shiyin'), isFalse);
    });
  });

  group('checkForUpdate 渠道包守卫', () {
    test('非官方包名：手动检查快速返回 null，不发起网络请求', () async {
      mockPackageName('com.shiyin.channelexample');

      final version = await AppUpdateService()
          .checkForUpdate(manual: true)
          .timeout(const Duration(seconds: 2));

      expect(version, isNull);
    });

    test('非官方包名：自动检查同样返回 null（守卫先于节流与联网）', () async {
      mockPackageName('com.shiyin.channelexample');

      final version = await AppUpdateService()
          .checkForUpdate()
          .timeout(const Duration(seconds: 2));

      expect(version, isNull);
    });
  });
}
