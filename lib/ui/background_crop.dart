import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable;

/// 背景图裁剪参数：聚焦点（归一化图像坐标）+ 相对缩放。
///
/// 存参数而不是存裁好的图片，原因有三：
/// 1. 不重编码：HEIC/JPEG 原样保留，没有画质损失，也不会产生体积巨大的 PNG；
/// 2. 旋转屏幕、桌面窗口拉伸后能按新比例重新框取，不用重新裁剪；
/// 3. 渲染时永远是「源矩形 → 视口矩形」的等比映射，数学上不可能拉伸变形。
///
/// [focusX]/[focusY] 是可见区域中心在图像里的归一化坐标（0 = 左/上，1 = 右/下），
/// [zoom] 是相对「刚好铺满（cover）」的放大倍数：1 = 最小放大、画面最多。
@immutable
class BackgroundCrop {
  const BackgroundCrop({this.focusX = 0.5, this.focusY = 0.5, this.zoom = 1});

  /// 默认构图：居中 + 最小放大，等价于旧的纯 BoxFit.cover，老用户观感不变。
  static const BackgroundCrop center = BackgroundCrop();

  /// 允许的放大范围（上限受背景图解码分辨率限制，太大只会发虚）。
  static const double minZoom = 1;
  static const double maxZoom = 3;

  /// 可见区域中心在图像中的归一化坐标。
  final double focusX;
  final double focusY;

  /// 相对 cover 的放大倍数，[minZoom] ~ [maxZoom]。
  final double zoom;

  /// 当前是否为默认构图（居中、未放大）。
  bool get isDefault =>
      focusX == center.focusX && focusY == center.focusY && zoom == center.zoom;

  BackgroundCrop copyWith({double? focusX, double? focusY, double? zoom}) {
    return BackgroundCrop(
      focusX: focusX ?? this.focusX,
      focusY: focusY ?? this.focusY,
      zoom: zoom ?? this.zoom,
    );
  }

  /// 夹到合法范围：手改 prefs、旧版本/未来版本脏数据都能安全回落。
  ///
  /// 缩放值在 1 附近做一次吸附：`1.25 × 0.8` 在 double 下等于
  /// `1.0000000000000002`，不吸附会让「重置」按钮在回到 100% 后仍然亮着，
  /// 落盘 JSON 也会带一串浮点尾数。
  BackgroundCrop normalized() {
    final clampedZoom = _clampFinite(zoom, minZoom, maxZoom, center.zoom);
    return BackgroundCrop(
      focusX: _clampFinite(focusX, 0, 1, center.focusX),
      focusY: _clampFinite(focusY, 0, 1, center.focusY),
      zoom: (clampedZoom - minZoom).abs() < 1e-9 ? minZoom : clampedZoom,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BackgroundCrop &&
      other.focusX == focusX &&
      other.focusY == focusY &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(focusX, focusY, zoom);

  @override
  String toString() => 'BackgroundCrop(focus: $focusX, $focusY, zoom: $zoom)';
}

double _clampFinite(double value, double min, double max, double fallback) {
  if (!value.isFinite) return fallback;
  return value.clamp(min, max).toDouble();
}

/// 可见区域占整张图的比例（宽、高均在 0~1）。
///
/// 只依赖「原图尺寸」与「视口尺寸」的比例关系：cover 基准
/// `s0 = max(boxW/imgW, boxH/imgH)`，实际缩放 `s = s0 * zoom`，可见宽
/// `boxW / s` 换算成图像归一化比例即 `boxW / (s * imgW)`。
Size visibleImageFraction({
  required Size imageSize,
  required Size boxSize,
  required BackgroundCrop crop,
}) {
  final normalized = crop.normalized();
  if (!_isUsable(imageSize) || !_isUsable(boxSize)) {
    return const Size(1, 1);
  }
  final coverScale = math.max(
    boxSize.width / imageSize.width,
    boxSize.height / imageSize.height,
  );
  final scale = coverScale * normalized.zoom;
  if (!scale.isFinite || scale <= 0) return const Size(1, 1);
  return Size(
    (boxSize.width / (scale * imageSize.width)).clamp(0.0, 1.0).toDouble(),
    (boxSize.height / (scale * imageSize.height)).clamp(0.0, 1.0).toDouble(),
  );
}

/// 计算要绘制的源矩形（图像像素坐标）。
///
/// 矩形的宽高比恒等于 [boxSize] 的宽高比（浮点误差内），因此把它画到
/// 视口矩形上是纯等比缩放——这是「背景永不变形」的数学保证。
Rect backgroundSourceRect({
  required Size imageSize,
  required Size boxSize,
  required BackgroundCrop crop,
}) {
  if (!_isUsable(imageSize) || !_isUsable(boxSize)) return Rect.zero;
  final normalized = crop.normalized();
  final visible = visibleImageFraction(
    imageSize: imageSize,
    boxSize: boxSize,
    crop: normalized,
  );
  final width = math.min(visible.width * imageSize.width, imageSize.width);
  final height = math.min(visible.height * imageSize.height, imageSize.height);
  if (width <= 0 || height <= 0) return Rect.zero;

  final maxLeft = math.max(0.0, imageSize.width - width);
  final maxTop = math.max(0.0, imageSize.height - height);
  final left = (normalized.focusX * imageSize.width - width / 2)
      .clamp(0.0, maxLeft)
      .toDouble();
  final top = (normalized.focusY * imageSize.height - height / 2)
      .clamp(0.0, maxTop)
      .toDouble();
  return Rect.fromLTWH(left, top, width, height);
}

/// 拖动 [delta]（裁剪框内的逻辑像素）后的裁剪参数。
///
/// 采用「拖图片」语义：手指往右拖，画面跟着右移 → 可见区域在图像里左移。
/// 聚焦点会被夹紧，保证可见区域不越出图像边界。
BackgroundCrop panBackgroundCrop({
  required BackgroundCrop crop,
  required Offset delta,
  required Size imageSize,
  required Size boxSize,
}) {
  final normalized = crop.normalized();
  if (!_isUsable(imageSize) || !_isUsable(boxSize)) return normalized;
  if (!delta.dx.isFinite || !delta.dy.isFinite) return normalized;
  final visible = visibleImageFraction(
    imageSize: imageSize,
    boxSize: boxSize,
    crop: normalized,
  );
  final offsetX = delta.dx / boxSize.width * visible.width;
  final offsetY = delta.dy / boxSize.height * visible.height;
  return BackgroundCrop(
    focusX: _clampFocus(normalized.focusX - offsetX, visible.width),
    focusY: _clampFocus(normalized.focusY - offsetY, visible.height),
    zoom: normalized.zoom,
  );
}

/// 以 [focal]（裁剪框内归一化坐标，默认中心）为锚点缩放 [scaleFactor] 倍。
///
/// 锚点下的图像内容保持不动（双指/滚轮缩放手感），缩放后聚焦点夹回图像内。
BackgroundCrop zoomBackgroundCrop({
  required BackgroundCrop crop,
  required double scaleFactor,
  required Size imageSize,
  required Size boxSize,
  Offset focal = const Offset(0.5, 0.5),
}) {
  final normalized = crop.normalized();
  if (!_isUsable(imageSize) || !_isUsable(boxSize)) return normalized;
  if (!scaleFactor.isFinite || scaleFactor <= 0) return normalized;
  if (!focal.dx.isFinite || !focal.dy.isFinite) return normalized;

  final newZoom = _clampFinite(
    normalized.zoom * scaleFactor,
    BackgroundCrop.minZoom,
    BackgroundCrop.maxZoom,
    normalized.zoom,
  );
  if (newZoom == normalized.zoom) return normalized;

  final before = visibleImageFraction(
    imageSize: imageSize,
    boxSize: boxSize,
    crop: normalized,
  );
  final after = visibleImageFraction(
    imageSize: imageSize,
    boxSize: boxSize,
    crop: normalized.copyWith(zoom: newZoom),
  );
  // 锚点当前对应的图像坐标（归一化）。
  final anchorX = normalized.focusX + (focal.dx - 0.5) * before.width;
  final anchorY = normalized.focusY + (focal.dy - 0.5) * before.height;
  return BackgroundCrop(
    focusX: _clampFocus(anchorX - (focal.dx - 0.5) * after.width, after.width),
    focusY: _clampFocus(
      anchorY - (focal.dy - 0.5) * after.height,
      after.height,
    ),
    zoom: newZoom,
  );
}

bool _isUsable(Size size) =>
    size.width.isFinite &&
    size.height.isFinite &&
    size.width > 0 &&
    size.height > 0;

/// 把聚焦点夹到「可见区域完全落在图像内」的范围；可见区域不小于整图时只能居中。
double _clampFocus(double focus, double visibleFraction) {
  if (!visibleFraction.isFinite || visibleFraction >= 1) return 0.5;
  final half = visibleFraction / 2;
  return focus.clamp(half, 1 - half).toDouble();
}
