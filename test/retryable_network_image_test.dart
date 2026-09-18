import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/image_disk_cache.dart';
import 'package:shiyin_music/services/network_monitor.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';

/// 1×1 透明 PNG（Flutter 官方测试图 kTransparentImage 同款，引擎必然可解码）。
final Uint8List _pngBytes = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// 广播流事件在微任务里派发、setState 又要等下一帧，多 pump 几次才稳定。
Future<void> _settleFrames(WidgetTester tester, [int frames = 4]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump();
  }
}

Widget _host(String url) => MaterialApp(
  home: Center(
    child: RetryableNetworkImage(
      url: url,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    ),
  ),
);

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('shiyin_retry_image_test');
    ImageDiskCache.instance.debugReset();
    ImageDiskCache.instance.configure(1024 * 1024);
    ImageDiskCache.instance.debugOverrideDirectory(root);
  });

  tearDown(() {
    ImageDiskCache.instance.debugReset();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('未进入失败态的封面：网络恢复不换代（消除全量重新解析）', (tester) async {
    const url = 'http://example.com/ok.jpg';
    // 预置磁盘字节 → 该封面不会走网络、不会进入失败态。用同步写避免在
    // fake-async 测区里 await 真实文件 IO（那会把用例挂住）；即使磁盘查找
    // 在 FakeAsync 下始终不返回（一直停在"解析中"），也同样是"未失败"。
    File('${root.path}/${ImageDiskCache.fileNameFor(url)}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(_pngBytes);

    await tester.pumpWidget(_host(url));
    await _settleFrames(tester);
    expect(find.byKey(const ValueKey('retry-0')), findsOneWidget);

    NetworkMonitor.instance.debugSimulateRestored();
    await _settleFrames(tester);

    // 关键回归点：没失败过的图不该被换代——否则一次网络抖动会让全 App 的
    // 封面 Element 全部重建并重新解析，缓存吃紧时就是整页封面变白再重下。
    expect(find.byKey(const ValueKey('retry-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-1')), findsNothing);
  });

  testWidgets('加载失败的封面：网络恢复后换代重试（原有能力保留）', (tester) async {
    // 关掉磁盘缓存 → 直接走网络。用解析期就抛错的 URL 制造确定的失败：
    // flutter_test 的假 HttpClient 走真实 dart:io 链路，FakeAsync 下不推进，
    // 这条路径不依赖任何真实 IO，失败会立刻以微任务形式回灌。
    ImageDiskCache.instance.debugReset();

    await tester.pumpWidget(_host('http://[bad'));
    await _settleFrames(tester);
    expect(find.byKey(const ValueKey('retry-0')), findsOneWidget);

    NetworkMonitor.instance.debugSimulateRestored();
    await _settleFrames(tester);

    expect(find.byKey(const ValueKey('retry-0')), findsNothing);
    expect(find.byKey(const ValueKey('retry-1')), findsOneWidget);
  });

  testWidgets('Artwork 网络封面走 RetryableNetworkImage（断网失败后可自动重试）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: Artwork(url: 'http://example.com/a.jpg', size: 64)),
      ),
    );
    expect(find.byType(RetryableNetworkImage), findsOneWidget);
  });

  group('解码尺寸量化', () {
    setUp(() {
      // 桌面网格降档（P1-2）后，这里固定为移动/车机口径（旧 2x/600 公式）
      // 作为零回归基线；桌面 1.5x/400 档见 artwork_decode_size_test.dart。
      debugDesktopFormFactorOverride = false;
    });
    tearDown(() {
      debugDesktopFormFactorOverride = null;
    });

    test('吸附到固定档位，封顶 600，非法尺寸回落到 600', () {
      // 44/48 这类相邻尺寸历史上是两条缓存条目，量化后共用同一条。
      expect(decodeSizeFor(44), 96);
      expect(decodeSizeFor(48), 96);
      expect(decodeSizeFor(63), 128);
      expect(decodeSizeFor(100), 200);
      expect(decodeSizeFor(139), 320);
      expect(decodeSizeFor(231), 480);
      // 超过最大档位封顶 600（与改前 clamp(1, 600) 口径一致）。
      expect(decodeSizeFor(500), 600);
      expect(decodeSizeFor(double.infinity), 600);
      expect(decodeSizeFor(double.nan), 600);
      // 极小尺寸仍给出可解码的正尺寸。
      expect(decodeSizeFor(1), 64);
    });
  });
}
