import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../background_crop.dart';

/// 按 [BackgroundCrop] 渲染背景图：等比缩放 + 裁剪，永不拉伸。
///
/// 为什么不用 `Image(fit: ...)`：放大后需要能平移到图像任意边缘，而
/// `BoxFit.cover` + `alignment` 只能表达「cover 范围内的对齐」，没法放大到
/// 局部再移动。这里把 [backgroundSourceRect] 算出的源矩形直接画到视口矩形，
/// 源/目标宽高比恒相等，渲染阶段不存在非等比缩放。
///
/// 行为对齐原来的 `Image`：换图时保留上一帧直到新图解码完成（gapless），
/// 解码失败时走 [errorBuilder]，不会把旧图画到新路径上。
class BackgroundCropView extends StatefulWidget {
  const BackgroundCropView({
    super.key,
    required this.image,
    this.crop = BackgroundCrop.center,
    this.errorBuilder,
    this.placeholder,
    this.onImageSizeChanged,
  });

  final ImageProvider image;
  final BackgroundCrop crop;

  /// 解码失败时展示的内容（默认占位为空白）。
  final WidgetBuilder? errorBuilder;

  /// 首帧解码完成前展示的内容（默认空白，避免背景层闪烁）。
  final WidgetBuilder? placeholder;

  /// 原图解码完成后回调其像素尺寸（裁剪页用它做手势换算）。
  final ValueChanged<Size>? onImageSizeChanged;

  @override
  State<BackgroundCropView> createState() => _BackgroundCropViewState();
}

class _BackgroundCropViewState extends State<BackgroundCropView> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _imageInfo;
  bool _failed = false;
  Size? _reportedSize;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // createLocalImageConfiguration 依赖 InheritedWidget，只能在
    // didChangeDependencies 之后调用；这里用 _stream 判空保证只解析一次。
    _ensureResolved();
  }

  @override
  void didUpdateWidget(covariant BackgroundCropView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) {
      _failed = false;
      _reportedSize = null;
      _detach();
      // 换图时新 provider 可能同步命中缓存并立刻回调，而 didUpdateWidget
      // 处在构建阶段，直接 setState 会触发「setState during build」。
      // 放到帧后再解析：本帧继续画旧图（gapless），下一帧换新图。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureResolved();
      });
    }
  }

  @override
  void dispose() {
    _detach();
    _imageInfo?.dispose();
    _imageInfo = null;
    super.dispose();
  }

  void _detach() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _stream = null;
    _listener = null;
  }

  void _ensureResolved() {
    if (_stream != null) return;
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) {
        if (!mounted || _stream != stream) {
          info.dispose();
          return;
        }
        _replaceImage(info);
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!mounted || _stream != stream) return;
        _fail();
      },
    );
    _listener = listener;
    _stream = stream;
    stream.addListener(listener);
  }

  void _replaceImage(ImageInfo info) {
    final previous = _imageInfo;
    setState(() {
      _imageInfo = info;
      _failed = false;
    });
    previous?.dispose();
    _notifyImageSize(info.image);
  }

  void _fail() {
    final previous = _imageInfo;
    setState(() {
      _imageInfo = null;
      _failed = true;
    });
    previous?.dispose();
    _reportedSize = null;
  }

  void _notifyImageSize(ui.Image image) {
    final size = Size(image.width.toDouble(), image.height.toDouble());
    if (size == _reportedSize) return;
    _reportedSize = size;
    final callback = widget.onImageSizeChanged;
    if (callback == null) return;
    // 父级通常在回调里 setState（裁剪页记录原图尺寸），放到帧后避免
    // 在构建阶段触发布局重建。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = _imageInfo;
      if (current == null) return;
      callback(
        Size(current.image.width.toDouble(), current.image.height.toDouble()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = _imageInfo;
    if (info == null) {
      if (_failed) {
        return widget.errorBuilder?.call(context) ?? const SizedBox.shrink();
      }
      return widget.placeholder?.call(context) ?? const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
          return const SizedBox.shrink();
        }
        return RepaintBoundary(
          child: CustomPaint(
            size: Size(width, height),
            painter: _BackgroundCropPainter(
              image: info.image,
              crop: widget.crop,
            ),
          ),
        );
      },
    );
  }
}

class _BackgroundCropPainter extends CustomPainter {
  const _BackgroundCropPainter({required this.image, required this.crop});

  final ui.Image image;
  final BackgroundCrop crop;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final source = backgroundSourceRect(
      imageSize: imageSize,
      boxSize: size,
      crop: crop,
    );
    if (source.isEmpty) return;
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = true;
    canvas.drawImageRect(image, source, Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _BackgroundCropPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.crop != crop;
}
