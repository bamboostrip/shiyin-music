import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/ui/background_crop.dart';
import 'package:shiyin_music/ui/form_factor.dart';

/// 4×2 PNG（一张真实可解码的图），用来实测「降采样后宽高比是否还在」。
const String _png4x2 =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAAXNSR0IArs4c6QAAAARnQU1BAACx'
    'jwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAALSURBVBhXY2AgBAAAIgABjjNCtQAAAABJRU5Erk'
    'Jggg==';

/// 4×2 PNG 的字节（安装流程会先试解码，不能用假字节）。
final _png4x2Bytes = base64Decode(_png4x2);

/// 解析一张图并取到 [ImageInfo]（同 services/disk_cached_image_provider_test）。
Future<ImageInfo> _resolveOnce(ImageProvider provider) async {
  final completer = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (ImageInfo info, bool synchronousCall) {
      if (!completer.isCompleted) completer.complete(info);
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  stream.addListener(listener);
  try {
    return await completer.future.timeout(const Duration(seconds: 5));
  } finally {
    stream.removeListener(listener);
  }
}

/// 自定义背景图（issue #13）单测，锁住两个回归点：
///
/// 1. **图片被拉伸变形**：解码必须保持宽高比。`ResizeImagePolicy.exact`
///    （默认）会把横图硬拉成 width×height 正方形，全局背景层与设置页两处
///    预览都会「整体拉伸」；这里用 `fit` 策略做等比例降采样，再由渲染层的
///    `BoxFit.cover` 裁剪铺满。
/// 2. **换图后仍显示旧图**：ImageCache 以「文件路径 + 解码尺寸」为键。此前
///    每次选择都固定复制成 `bg_custom.jpg`，路径不变 → 直接命中上一张的
///    解码结果；现在每次落成带时间戳的新文件名，并清掉旧文件与旧缓存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late Directory pickDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    docsDir = await Directory.systemTemp.createTemp('bg_docs_');
    pickDir = await Directory.systemTemp.createTemp('bg_pick_');
  });

  tearDown(() async {
    for (final dir in [docsDir, pickDir]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  /// 造一个「相册里选中的临时文件」，只关心字节内容不关心是不是真图片。
  Future<File> pickedFile(String name, List<int> bytes) async {
    final file = File('${pickDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  group('解码 provider', () {
    tearDown(() {
      debugDesktopFormFactorOverride = null;
    });

    test('等比例降采样：fit 策略 + 上限尺寸 + 指向原文件', () {
      final provider = buildBackgroundImageProvider('/tmp/bg_custom_1.jpg');

      expect(provider, isA<ResizeImage>());
      final resize = provider as ResizeImage;
      // exact 会忽略原图宽高比（等价 BoxFit.fill），必须显式用 fit。
      expect(resize.policy, ResizeImagePolicy.fit);
      expect(resize.width, backgroundImageDecodeCap);
      expect(resize.height, backgroundImageDecodeCap);
      expect(resize.imageProvider, isA<FileImage>());
      expect(
        (resize.imageProvider as FileImage).file.path,
        '/tmp/bg_custom_1.jpg',
      );
    });

    test('上限按形态取值：桌面更清晰、移动更省内存，缩略图另取小上限', () {
      debugDesktopFormFactorOverride = true;
      expect(backgroundImageDecodeCap, backgroundImageDecodeCapDesktop);
      final desktop =
          buildBackgroundImageProvider('/tmp/bg.jpg') as ResizeImage;
      expect(desktop.width, backgroundImageDecodeCapDesktop);

      debugDesktopFormFactorOverride = false;
      expect(backgroundImageDecodeCap, backgroundImageDecodeCapMobile);
      final mobile = buildBackgroundImageProvider('/tmp/bg.jpg') as ResizeImage;
      expect(mobile.width, backgroundImageDecodeCapMobile);

      final thumb =
          buildBackgroundImageProvider(
                '/tmp/bg.jpg',
                cap: backgroundPreviewDecodeCap,
              )
              as ResizeImage;
      expect(thumb.width, backgroundPreviewDecodeCap);
      expect(thumb.policy, ResizeImagePolicy.fit);
    });

    test('同路径缓存键相同（旧实现固定文件名必命中旧图），换名后键不同', () async {
      final sameA = await buildBackgroundImageProvider(
        '/tmp/bg_same.jpg',
      ).obtainKey(ImageConfiguration.empty);
      final sameB = await buildBackgroundImageProvider(
        '/tmp/bg_same.jpg',
      ).obtainKey(ImageConfiguration.empty);
      final other = await buildBackgroundImageProvider(
        '/tmp/bg_other.jpg',
      ).obtainKey(ImageConfiguration.empty);

      // 这正是 issue #13 第 2 点的机制：路径不变 → 键不变 → 命中旧解码位图。
      expect(sameA, sameB);
      expect(other, isNot(equals(sameA)));
    });

    test('实测解码：4×2 图降到 2×1，不再被压成 2×2', () async {
      final file = File('${docsDir.path}/bg_probe.png');
      await file.writeAsBytes(base64Decode(_png4x2));

      final info = await _resolveOnce(
        buildBackgroundImageProvider(file.path, cap: 2),
      );
      addTearDown(info.dispose);

      // 旧实现（exact 策略）这里会得到 2×2：横图被压成正方形，正是
      // issue #13 的「整体变形」；fit 策略必须保持 4:2 = 2:1。
      expect(info.image.width, 2);
      expect(info.image.height, 1);
    });

    test('删除背景图文件时逐出各解码尺寸的缓存键', () async {
      final path = '${docsDir.path}/bg_evict.jpg';
      await File(path).writeAsBytes([1, 2, 3]);

      // 桌面主图、移动主图、设置页缩略图三种 cap 各占一个缓存键。
      final keys = <Object>[];
      for (final cap in <int>{
        backgroundImageDecodeCapDesktop,
        backgroundImageDecodeCapMobile,
        backgroundPreviewDecodeCap,
      }) {
        final key = await buildBackgroundImageProvider(
          path,
          cap: cap,
        ).obtainKey(ImageConfiguration.empty);
        keys.add(key);
        // 放一个永不完成的 completer 占住缓存槽位，避免单测里做真实解码。
        imageCache.putIfAbsent(
          key,
          () => OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
        );
        expect(imageCache.containsKey(key), isTrue);
      }

      await ThemeController.deleteBackgroundImageFile(path);

      for (final key in keys) {
        expect(imageCache.containsKey(key), isFalse, reason: '旧解码结果应被逐出');
      }
      expect(await File(path).exists(), isFalse);
    });
  });

  group('落盘文件名', () {
    test('连续两次复制得到不同路径，内容各自对应、扩展名保留', () async {
      final first = await ThemeController.saveBackgroundImageCopy(
        await pickedFile('a.jpg', [1, 2, 3]),
        docsDir,
      );
      final second = await ThemeController.saveBackgroundImageCopy(
        await pickedFile('b.png', [4, 5, 6]),
        docsDir,
      );

      expect(first, isNot(second), reason: '同名会命中旧图缓存，必须每次都换名');
      expect(first, endsWith('.jpg'));
      expect(second, endsWith('.png'));
      expect(await File(first).readAsBytes(), [1, 2, 3]);
      expect(await File(second).readAsBytes(), [4, 5, 6]);
    });

    test('扩展名大小写归一，无扩展名/异常后缀回落 .jpg', () async {
      final upper = await ThemeController.saveBackgroundImageCopy(
        await pickedFile('photo.JPG', [1]),
        docsDir,
      );
      final noExt = await ThemeController.saveBackgroundImageCopy(
        await pickedFile('noext', [1]),
        docsDir,
      );

      expect(upper, endsWith('.jpg'));
      expect(noExt, endsWith('.jpg'));
    });
  });

  group('安装 / 清除背景图', () {
    test('安装新背景图：路径换新、旧文件删除、自动开启并持久化', () async {
      final theme = ThemeController();
      await theme.load();

      final ok = await theme.installBackgroundImage(
        await pickedFile('first.jpg', _png4x2Bytes),
        targetDir: docsDir,
      );
      expect(ok, isTrue);
      final firstPath = theme.backgroundImagePath!;
      expect(theme.backgroundEnabled, isTrue);
      expect(await File(firstPath).readAsBytes(), _png4x2Bytes);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme.bg_image_path'), firstPath);
      expect(prefs.getBool('theme.bg_enabled'), isTrue);

      // 用户换第二张图：必须换路径，旧文件顺手清掉（不留垃圾文件）。
      final okSecond = await theme.installBackgroundImage(
        await pickedFile('second.png', _png4x2Bytes),
        targetDir: docsDir,
      );
      expect(okSecond, isTrue);
      final secondPath = theme.backgroundImagePath!;
      expect(secondPath, isNot(firstPath));
      expect(secondPath, endsWith('.png'));
      expect(await File(secondPath).readAsBytes(), _png4x2Bytes);
      expect(await File(firstPath).exists(), isFalse, reason: '换图后旧背景图文件应被删除');
      expect(prefs.getString('theme.bg_image_path'), secondPath);
    });

    test('选到无法解码的图片：抛错、保留原背景、不留垃圾文件', () async {
      final theme = ThemeController();
      await theme.load();
      await theme.installBackgroundImage(
        await pickedFile('good.png', _png4x2Bytes),
        targetDir: docsDir,
      );
      final goodPath = theme.backgroundImagePath!;
      final fileCount = docsDir.listSync().whereType<File>().length;

      // Windows 的选择器允许 tif/tiff 等 Flutter 解不了的格式；损坏文件同理。
      await expectLater(
        theme.installBackgroundImage(
          await pickedFile('bad.jpg', [1, 2, 3]),
          targetDir: docsDir,
        ),
        throwsA(isA<BackgroundImageException>()),
      );

      expect(theme.backgroundImagePath, goodPath);
      expect(await File(goodPath).exists(), isTrue, reason: '旧背景不能被删');
      expect(
        docsDir.listSync().whereType<File>().length,
        fileCount,
        reason: '失败的那次不留新副本',
      );
    });

    test('启动时背景图文件已不在：清掉脏设置并关闭开关', () async {
      final missing = '${docsDir.path}/bg_custom_123_0.jpg';
      SharedPreferences.setMockInitialValues({
        'theme.bg_image_path': missing,
        'theme.bg_enabled': true,
        'theme.bg_crop': '{"fx": 0.2, "fy": 0.8, "z": 2}',
      });

      final theme = ThemeController();
      await theme.load();

      expect(theme.backgroundImagePath, isNull);
      expect(theme.backgroundEnabled, isFalse);
      // 构图只服务于那张已不存在的图，自愈时一并清掉，避免套到下一张图上。
      expect(theme.backgroundCrop, BackgroundCrop.center);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme.bg_image_path'), isNull);
      expect(prefs.getBool('theme.bg_enabled'), isFalse);
      expect(prefs.getString('theme.bg_crop'), isNull);
    });

    test('清除背景图：路径置空、开关关闭、文件与持久化键都清掉', () async {
      final theme = ThemeController();
      await theme.load();
      await theme.installBackgroundImage(
        await pickedFile('bg.jpg', _png4x2Bytes),
        targetDir: docsDir,
      );
      final path = theme.backgroundImagePath!;
      expect(await File(path).exists(), isTrue);

      await theme.clearBackgroundImage();

      expect(theme.backgroundImagePath, isNull);
      expect(theme.backgroundEnabled, isFalse);
      expect(await File(path).exists(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme.bg_image_path'), isNull);
      expect(prefs.getBool('theme.bg_enabled'), isFalse);
    });

    test('重启后恢复上次选择的背景图路径', () async {
      final first = ThemeController();
      await first.load();
      await first.installBackgroundImage(
        await pickedFile('persist.png', _png4x2Bytes),
        targetDir: docsDir,
      );
      final path = first.backgroundImagePath;
      // 关掉开关，避免 load() 的预缓存再解一次图（本用例只关心路径恢复）。
      await first.setBackgroundEnabled(false);

      final second = ThemeController();
      await second.load();

      expect(second.backgroundImagePath, path);
    });
  });

  /// 背景构图（裁剪参数）的持久化契约：单键 JSON、坏数据自愈、与安装/清除
  /// 联动。构图本身由 background_crop_test 锁数学，这里只关心控制器的落盘。
  group('背景构图（裁剪参数）', () {
    test('默认构图为居中 + 未放大，且不写 prefs', () async {
      final theme = ThemeController();
      await theme.load();

      expect(theme.backgroundCrop, BackgroundCrop.center);
      expect(theme.backgroundCrop.isDefault, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme.bg_crop'), isNull);
    });

    test('安装时传入构图：getter 生效并按单个 JSON 字符串落盘', () async {
      final theme = ThemeController();
      await theme.load();
      const crop = BackgroundCrop(focusX: 0.2, focusY: 0.8, zoom: 2.5);

      final ok = await theme.installBackgroundImage(
        await pickedFile('crop.png', _png4x2Bytes),
        targetDir: docsDir,
        crop: crop,
      );

      expect(ok, isTrue);
      expect(theme.backgroundCrop, crop);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('theme.bg_crop');
      expect(raw, isNotNull);
      // 单键 JSON：fx/fy/z 分三个键写会「半写」（新焦点配旧缩放）。
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded.keys, unorderedEquals(<String>['fx', 'fy', 'z']));
      expect(decoded['fx'], closeTo(0.2, 1e-9));
      expect(decoded['fy'], closeTo(0.8, 1e-9));
      expect(decoded['z'], closeTo(2.5, 1e-9));
    });

    test('重启后恢复上次安装的构图', () async {
      final first = ThemeController();
      await first.load();
      const crop = BackgroundCrop(focusX: 0.35, focusY: 0.65, zoom: 1.8);
      await first.installBackgroundImage(
        await pickedFile('restart_crop.png', _png4x2Bytes),
        targetDir: docsDir,
        crop: crop,
      );
      // 关掉开关，避免 load() 的预缓存再解一次图（本用例只关心构图恢复）。
      await first.setBackgroundEnabled(false);

      final second = ThemeController();
      await second.load();

      expect(second.backgroundCrop, crop);
    });

    test('越界构图在写入与读取时都夹到合法范围', () async {
      final theme = ThemeController();
      await theme.load();
      await theme.setBackgroundCrop(
        const BackgroundCrop(focusX: -1, focusY: 2, zoom: 99),
      );

      expect(theme.backgroundCrop.focusX, 0.0);
      expect(theme.backgroundCrop.focusY, 1.0);
      expect(theme.backgroundCrop.zoom, BackgroundCrop.maxZoom);

      // 模拟手改/旧版本写进 prefs 的越界值：load 同样夹紧而不是原样启用。
      SharedPreferences.setMockInitialValues({
        'theme.bg_crop': '{"fx": -3, "fy": 4, "z": 0.2}',
      });
      final restored = ThemeController();
      await restored.load();

      expect(restored.backgroundCrop.focusX, 0.0);
      expect(restored.backgroundCrop.focusY, 1.0);
      expect(restored.backgroundCrop.zoom, BackgroundCrop.minZoom);
    });

    test('非法 JSON / 字段缺失 / 类型不符回落默认构图且不打断 load', () async {
      // 完全不是 JSON。
      SharedPreferences.setMockInitialValues({'theme.bg_crop': 'not-json'});
      var theme = ThemeController();
      await theme.load();
      expect(theme.backgroundCrop, BackgroundCrop.center);

      // 缺字段：不能拿解析到的部分值凑合，整体回落。
      SharedPreferences.setMockInitialValues({
        'theme.bg_crop': '{"fx": 0.2, "fy": 0.3}',
      });
      theme = ThemeController();
      await theme.load();
      expect(theme.backgroundCrop, BackgroundCrop.center);

      // 字段类型不对（z 是字符串）。
      SharedPreferences.setMockInitialValues({
        'theme.bg_crop': '{"fx": 0.2, "fy": 0.3, "z": "2"}',
      });
      theme = ThemeController();
      await theme.load();
      expect(theme.backgroundCrop, BackgroundCrop.center);

      // 1e999 这类溢出数值：无论解析成 Infinity 还是被解析器拒绝，都只能
      // 回落默认，不能把非有限值带进渲染。
      SharedPreferences.setMockInitialValues({
        'theme.bg_crop': '{"fx": 1e999, "fy": -1e999, "z": 1e999}',
      });
      theme = ThemeController();
      await theme.load();
      expect(theme.backgroundCrop, BackgroundCrop.center);
    });

    test('NaN / Infinity 输入在写入前被兜住，不抛也不落盘脏值', () async {
      final theme = ThemeController();
      await theme.load();

      // 手势计算异常可能产出非有限值；jsonEncode 遇到 NaN/Infinity 会抛，
      // 所以必须在编码前 normalize 掉。
      expect(
        await theme.setBackgroundCrop(
          const BackgroundCrop(
            focusX: double.nan,
            focusY: double.infinity,
            zoom: double.nan,
          ),
        ),
        isTrue,
      );
      expect(theme.backgroundCrop, BackgroundCrop.center);

      final prefs = await SharedPreferences.getInstance();
      final decoded =
          jsonDecode(prefs.getString('theme.bg_crop')!) as Map<String, dynamic>;
      expect(decoded['fx'], 0.5);
      expect(decoded['fy'], 0.5);
      expect(decoded['z'], 1.0);
    });

    test('setBackgroundCrop 往返：内存 / prefs / 重启三处一致', () async {
      final theme = ThemeController();
      await theme.load();
      const crop = BackgroundCrop(focusX: 0.25, focusY: 0.75, zoom: 1.5);

      expect(await theme.setBackgroundCrop(crop), isTrue);
      expect(theme.backgroundCrop, crop);

      final restarted = ThemeController();
      await restarted.load();
      expect(restarted.backgroundCrop, crop);
    });

    test('清除背景图后构图回默认并移除持久化键，无图时也安全', () async {
      final theme = ThemeController();
      await theme.load();
      await theme.installBackgroundImage(
        await pickedFile('clear_crop.png', _png4x2Bytes),
        targetDir: docsDir,
        crop: const BackgroundCrop(focusX: 0.1, focusY: 0.9, zoom: 2),
      );
      expect(theme.backgroundCrop, isNot(BackgroundCrop.center));

      await theme.clearBackgroundImage();

      expect(theme.backgroundCrop, BackgroundCrop.center);
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme.bg_crop'), isNull);

      // path 为 null（本就没有背景图）时再次清除也不能抛。
      await theme.clearBackgroundImage();
      expect(theme.backgroundCrop, BackgroundCrop.center);
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme.bg_crop'), isNull);
    });
  });
}
