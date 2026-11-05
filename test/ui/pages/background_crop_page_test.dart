import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/background_crop.dart';
import 'package:shiyin_music/ui/pages/background_crop_page.dart';
import 'package:shiyin_music/ui/widgets/background_crop_view.dart';

/// 不需要真实解码的图片 provider：直接给出 setUpAll 里创建好的 [ui.Image]。
///
/// widget 测试的 fake async 环境里做真实文件解码很容易卡死，这里包一层
/// [createTestImage]，测试只关心页面生命周期与手势换算。
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

/// 永远不完成解码的 provider：用来锁住「尺寸未知 → 转圈 + 完成禁用」。
class _PendingImageProvider extends ImageProvider<_PendingImageProvider> {
  @override
  Future<_PendingImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_PendingImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
  }

  @override
  bool operator ==(Object other) => other is _PendingImageProvider;

  @override
  int get hashCode => 0;
}

/// 截获 push 的返回值：pop 页面时由宿主页回调写入。
class _Harness {
  BackgroundCrop? result;
  bool completed = false;
}

/// 宿主页：用真实 Navigator 推入 [BackgroundCropPage]，验证 pop 结果与出栈。
class _HostPage extends StatelessWidget {
  const _HostPage({
    required this.image,
    required this.initialCrop,
    required this.onPopped,
  });

  final ImageProvider image;
  final BackgroundCrop initialCrop;
  final ValueChanged<BackgroundCrop?> onPopped;

  Future<void> _open(BuildContext context) async {
    final crop = await Navigator.of(context).push<BackgroundCrop>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            BackgroundCropPage(image: image, initialCrop: initialCrop),
      ),
    );
    onPopped(crop);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => _open(context),
          child: const Text('打开裁剪页'),
        ),
      ),
    );
  }
}

/// 裁剪页的手势与返回值测试。
///
/// 拖拽方向、缩放锚点、夹紧等几何数学已由 test/ui/background_crop_test.dart
/// 的纯函数覆盖；这里只验证页面层最容易出 bug 的接线：crop 透传、手势到
/// crop 的参数流向、按钮步进、重置、取消返回 null 以及路由出栈。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image image;

  setUpAll(() async {
    // createTestImage 需要真实异步，必须在 testWidgets 之外创建。
    image = await createTestImage(width: 4, height: 2);
  });

  /// 打开裁剪页。图片解码是同步的，尺寸会在首帧的帧后回调里上报，
  /// 因此这里可以直接 pumpAndSettle（转圈会在尺寸上报后消失）。
  Future<void> openPage(
    WidgetTester tester, {
    required _Harness harness,
    ImageProvider? provider,
    BackgroundCrop initialCrop = BackgroundCrop.center,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: _HostPage(
          image: provider ?? _StubImageProvider(image),
          initialCrop: initialCrop,
          onPopped: (crop) {
            harness.result = crop;
            harness.completed = true;
          },
        ),
      ),
    );
    await tester.tap(find.text('打开裁剪页'));
    await tester.pumpAndSettle();
  }

  testWidgets('合法初始 crop 透传给预览，「完成」原样返回并出栈', (tester) async {
    final harness = _Harness();
    // 800×600 视口 + 4×2 图 + zoom1.5 时，可见范围约为 x∈[.22,.78]、y∈[.33,.67]。
    const initial = BackgroundCrop(focusX: .4, focusY: .4, zoom: 1.5);
    await openPage(tester, harness: harness, initialCrop: initial);

    expect(find.byType(BackgroundCropPage), findsOneWidget);
    final view = tester.widget<BackgroundCropView>(
      find.byType(BackgroundCropView),
    );
    expect(view.crop, initial);
    expect(find.text('150%'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(harness.completed, isTrue);
    expect(harness.result, initial);
    expect(find.byType(BackgroundCropPage), findsNothing);
  });

  testWidgets('可见范围之外的脏构图进页即夹紧，拖动不再有死区', (tester) async {
    final harness = _Harness();
    // 手改 prefs 可能留下越界焦点：渲染层会把它钉在边缘（视觉不变），
    // 但直接拖会先「空走」一段；进页后应先夹回可见范围。
    await openPage(
      tester,
      harness: harness,
      initialCrop: const BackgroundCrop(focusX: .05, focusY: .95, zoom: 2),
    );

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 4×2 图 / 800×600 框 / zoom2：可见宽 1/3、高 1/2，焦点范围 x∈[1/6,5/6]、y∈[1/4,3/4]。
    expect(harness.result!.focusX, closeTo(1 / 6, 1e-9));
    expect(harness.result!.focusY, closeTo(3 / 4, 1e-9));
    expect(harness.result!.zoom, 2);
  });

  testWidgets('拖动后聚焦点方向正确，缩放不变', (tester) async {
    final harness = _Harness();
    await openPage(tester, harness: harness);

    // 往左拖 = 拖图片向左 = 可见区域在图像中右移 → focusX 增大。
    await tester.dragFrom(
      tester.getCenter(find.byType(BackgroundCropView)),
      const Offset(-80, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final crop = harness.result!;
    expect(crop.focusX, greaterThan(0.5));
    // 4x2 的图放进按屏幕比例的框里，高度方向刚好铺满，不可上下平移。
    expect(crop.focusY, closeTo(0.5, 1e-9));
    expect(crop.zoom, 1);
  });

  testWidgets('点放大按钮 zoom 增加，倍率文本同步刷新', (tester) async {
    final harness = _Harness();
    await openPage(tester, harness: harness);
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.byTooltip('放大背景'));
    await tester.pumpAndSettle();

    expect(find.text('125%'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(harness.result!.zoom, closeTo(1.25, 1e-9));
  });

  testWidgets('点重置回到居中最小放大的默认构图', (tester) async {
    final harness = _Harness();
    await openPage(
      tester,
      harness: harness,
      initialCrop: const BackgroundCrop(focusX: .2, focusY: .3, zoom: 2),
    );
    expect(find.text('200%'), findsOneWidget);

    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(harness.result, BackgroundCrop.center);
  });

  testWidgets('关闭按钮取消：返回 null，不覆盖已有构图', (tester) async {
    final harness = _Harness();
    await openPage(
      tester,
      harness: harness,
      initialCrop: const BackgroundCrop(focusX: .25, zoom: 2),
    );

    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();

    expect(harness.completed, isTrue);
    expect(harness.result, isNull);
    expect(find.byType(BackgroundCropPage), findsNothing);
  });

  testWidgets('尺寸未知时转圈且「完成」禁用，但仍能取消返回', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: _HostPage(
          image: _PendingImageProvider(),
          initialCrop: BackgroundCrop.center,
          onPopped: (crop) {
            harness.result = crop;
            harness.completed = true;
          },
        ),
      ),
    );
    await tester.tap(find.text('打开裁剪页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final done = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '完成'),
    );
    expect(done.onPressed, isNull);

    // 加载中也不能把用户困在页面里：取消必须可用。
    await tester.tap(find.byTooltip('取消'));
    await tester.pump();
    // 加载中的转圈是无限动画，pumpAndSettle 永远不收敛；按时间推进到退场动画
    // 结束（Android 全屏对话框约 450ms）再多一帧，让路由从 Overlay 摘除。
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();

    expect(harness.completed, isTrue);
    expect(harness.result, isNull);
    expect(find.byType(BackgroundCropPage), findsNothing);
  });

  testWidgets('双击重置回默认构图', (tester) async {
    final harness = _Harness();
    await openPage(
      tester,
      harness: harness,
      initialCrop: const BackgroundCrop(focusX: .25, focusY: .75, zoom: 2),
    );
    expect(find.text('200%'), findsOneWidget);

    final center = tester.getCenter(find.byType(BackgroundCropView));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();

    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(harness.result, BackgroundCrop.center);
  });

  testWidgets('鼠标滚轮以指针为锚点缩放', (tester) async {
    final harness = _Harness();
    await openPage(tester, harness: harness);
    final rect = tester.getRect(find.byType(BackgroundCropView));

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(rect.center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
    await tester.pumpAndSettle();

    expect(find.text('100%'), findsNothing);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(harness.result!.zoom, greaterThan(1));
  });

  testWidgets('双指捏合放大', (tester) async {
    final harness = _Harness();
    await openPage(tester, harness: harness);
    final rect = tester.getRect(find.byType(BackgroundCropView));
    final center = rect.center;
    final spread = rect.width * 0.2;

    final first = await tester.startGesture(center - Offset(spread, 0));
    final second = await tester.startGesture(center + Offset(spread, 0));
    await tester.pump();
    await first.moveBy(Offset(-spread, 0));
    await second.moveBy(Offset(spread, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(find.text('100%'), findsNothing);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(harness.result!.zoom, greaterThan(1));
  });

  testWidgets('缩放按钮保留读屏点击动作', (tester) async {
    final harness = _Harness();
    await openPage(tester, harness: harness);

    // SemanticsHandle 必须在测试体结束前释放（addTearDown 晚于框架的
    // 「未释放句柄」校验，会误报）。
    final handle = tester.ensureSemantics();
    await tester.pumpAndSettle();
    try {
      final data = tester
          .getSemantics(find.byIcon(Icons.add_rounded))
          .getSemanticsData();
      // 之前外包的 Semantics(excludeSemantics) 会把 IconButton 的 tap 动作丢掉，
      // 读屏能聚焦却按不动；这条断言锁住「可激活」。
      expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
      // IconButton 的 tooltip 走 SemanticsData.tooltip，而不是 label。
      expect(data.tooltip, '放大背景');
    } finally {
      handle.dispose();
    }
  });
}
