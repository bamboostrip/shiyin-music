import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 只覆写被调用的 downloadDir：避免真实 DownloadService 走 path_provider
/// （单测环境没有平台插件）。
class _StubDownloadService extends DownloadService {
  _StubDownloadService(this.dir);

  final Directory dir;

  @override
  Future<Directory> downloadDir() async => dir;
}

class _FakeMusicApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  DownloadController buildController(Directory dir) =>
      DownloadController(_StubDownloadService(dir), _FakeMusicApi());

  group('DownloadController 下载目录路径（缓存弹层展示数据源）', () {
    test('getDownloadDirPath 返回实际生效目录的绝对路径', () async {
      final dir = await Directory.systemTemp.createTemp('shiyin_dir_path_');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });

      expect(await buildController(dir).getDownloadDirPath(), dir.path);
    });

    test('getCustomDownloadDir：未配置返回 null，配置后返回 override 路径', () async {
      final controller = buildController(Directory.systemTemp);
      expect(await controller.getCustomDownloadDir(), isNull);

      await DownloadService.setCustomDownloadDir(r'D:\MyMusic');
      expect(await controller.getCustomDownloadDir(), r'D:\MyMusic');

      // 清除 override 后回到「跟随系统默认」。
      await DownloadService.setCustomDownloadDir(null);
      expect(await controller.getCustomDownloadDir(), isNull);
    });
  });
}
