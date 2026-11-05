import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/background_crop.dart';
import 'package:shiyin_music/ui/widgets/background_crop_view.dart';

/// 不需要真实解码的图片 provider：直接给出 [ui.Image]。
///
/// widget 测试的 fake async 环境里做真实解码很容易卡住，这里用
/// [createTestImage]（在 setUp 的真实异步里创建）包一层，测试只关心组件
/// 生命周期与尺寸回调。
///
/// 注意：这些用例刻意依赖「同步投递 + 单次上报」的语义（模拟缓存命中）。
/// 换成真实 FileImage 是异步解码，断言会全部失效——不要拿它替换。
class _StubImageProvider extends ImageProvider<_StubImageProvider> {
  _StubImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_StubImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_StubImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _StubImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(ImageInfo(image: image.clone())),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _StubImageProvider && identical(other.image, image);

  @override
  int get hashCode => identityHashCode(image);
}

class _FailingImageProvider extends ImageProvider<_FailingImageProvider> {
  @override
  Future<_FailingImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FailingImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _FailingImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      Future<ImageInfo>.error(StateError('decode failed')),
    );
  }

  @override
  bool operator ==(Object other) => other is _FailingImageProvider;

  @override
  int get hashCode => 0;
}

/// [BackgroundCropView] 的渲染/生命周期测试。
///
/// 比例正确性由 background_crop_test.dart 的纯函数覆盖；这里只验证组件层面
/// 最容易出 bug 的部分：原图尺寸回调、换图后重新解析、解码失败走
/// errorBuilder、裁剪参数变化不重建解码流。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image image4x2;
  late ui.Image image6x3;

  setUpAll(() async {
    // createTestImage 需要真实异步，必须在 testWidgets 之外创建。
    image4x2 = await createTestImage(width: 4, height: 2);
    image6x3 = await createTestImage(width: 6, height: 3);
  });

  Widget build(
    ImageProvider provider, {
    BackgroundCrop crop = BackgroundCrop.center,
    ValueChanged<Size>? onImageSizeChanged,
    WidgetBuilder? errorBuilder,
  }) {
    return MaterialApp(
      home: Center(
        child: SizedBox(
          width: 8,
          height: 4,
          child: BackgroundCropView(
            image: provider,
            crop: crop,
            onImageSizeChanged: onImageSizeChanged,
            errorBuilder: errorBuilder,
          ),
        ),
      ),
    );
  }

  testWidgets('解析出原图尺寸并通过回调上报', (tester) async {
    final reported = <Size>[];
    await tester.pumpWidget(
      build(_StubImageProvider(image4x2), onImageSizeChanged: reported.add),
    );
    await tester.pump();

    expect(reported, isNotEmpty);
    expect(reported.last, const Size(4, 2));
    expect(
      find.descendant(
        of: find.byType(BackgroundCropView),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('换图后重新解析并上报新尺寸', (tester) async {
    final reported = <Size>[];
    await tester.pumpWidget(
      build(_StubImageProvider(image4x2), onImageSizeChanged: reported.add),
    );
    await tester.pump();
    expect(reported.last, const Size(4, 2));

    await tester.pumpWidget(
      build(_StubImageProvider(image6x3), onImageSizeChanged: reported.add),
    );
    await tester.pump();

    expect(reported.last, const Size(6, 3));
  });

  testWidgets('解码失败走 errorBuilder，不抛未处理异常', (tester) async {
    await tester.pumpWidget(
      build(_FailingImageProvider(), errorBuilder: (_) => const Text('ERR')),
    );
    await tester.pump();

    expect(find.text('ERR'), findsOneWidget);
  });

  testWidgets('裁剪参数变化不重建解码流', (tester) async {
    final reported = <Size>[];
    await tester.pumpWidget(
      build(_StubImageProvider(image4x2), onImageSizeChanged: reported.add),
    );
    await tester.pump();
    expect(reported, <Size>[const Size(4, 2)]);
    final initialPaint = find.descendant(
      of: find.byType(BackgroundCropView),
      matching: find.byType(CustomPaint),
    );
    expect(initialPaint, findsOneWidget);

    await tester.pumpWidget(
      build(
        _StubImageProvider(image4x2),
        crop: const BackgroundCrop(focusX: 0.2, focusY: 0.8, zoom: 2),
        onImageSizeChanged: reported.add,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 只是重绘，不能重新解析/回调尺寸（否则裁剪页每拖一下就重置一次基准）。
    expect(reported, <Size>[const Size(4, 2)]);
    expect(
      find.descendant(
        of: find.byType(BackgroundCropView),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });
}
