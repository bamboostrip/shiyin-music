import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../background_crop.dart';
import '../design_tokens.dart';
import '../widgets/background_crop_view.dart';

/// 「调整背景位置」页：在「真实窗口比例」的预览框里拖动 / 缩放背景图。
///
/// 为什么单独开一页而不是在设置页里内联调：全局背景铺满的是整个窗口
/// （状态栏、底部系统手势区也盖得住），设置页的卡片只能看到近似效果；
/// 只有按真实屏幕比例框出预览区、并让手势直接作用在这块区域上，用户才能
/// 所见即所得地决定「哪一块画面会露出来」。
///
/// 本页只编辑 [BackgroundCrop] 参数，不碰文件与持久化：返回后由调用方决定
/// 保存还是丢弃（「选新图」与「重新调整已有图」两条路径共用本页）。
class BackgroundCropPage extends StatefulWidget {
  const BackgroundCropPage({
    super.key,
    required this.image,
    required this.initialCrop,
    this.title = '调整背景位置',
  });

  final ImageProvider image;

  /// 进入页面时的构图；脏数据在 [initState] 里经 normalized 兜底。
  final BackgroundCrop initialCrop;

  final String title;

  @override
  State<BackgroundCropPage> createState() => _BackgroundCropPageState();
}

class _BackgroundCropPageState extends State<BackgroundCropPage> {
  /// 与全局背景层兜底底色一致的近黑色：四周留黑才能看清真正的裁切边界。
  static const Color _canvasColor = Color(0xFF06070A);
  static const Color _borderColor = Color(0x38FFFFFF);

  late BackgroundCrop _crop;

  /// 原图像素尺寸，由 [BackgroundCropView.onImageSizeChanged] 解码后上报。
  /// 尺寸未知时算不出裁切区域，「完成」保持禁用。
  Size? _imageSize;

  /// 预览框的实际布局尺寸。在 LayoutBuilder 里缓存给手势换算用：
  /// 手势回调拿不到 constraints，事后再从 GlobalKey 量又太绕。
  Size? _frameSize;

  /// 当前手势的累计缩放值。onScaleUpdate.scale 是「相对手势起点」的累计值，
  /// 必须和上一帧相除才能换算成本次增量，否则双指捏合会被重复放大。
  double _gestureScale = 1;

  /// 解码失败标记。失败后要撤掉加载转圈，否则转圈会盖住 errorBuilder 提示。
  bool _failed = false;

  /// 是否已经发起 pop。
  ///
  /// 「完成」在退场动画期间仍然可点：第二次 pop 会沿着导航栈把下面的
  /// 设置页一起弹掉。所有返回路径共用这个闸门。
  bool _popping = false;

  /// 是否已经排了一个「帧后夹紧焦点」的回调（布局比例变化时用）。
  bool _clampScheduled = false;

  @override
  void initState() {
    super.initState();
    // 入口可能来自旧版本/手改 prefs 的脏数据，先夹到合法范围再参与换算。
    _crop = widget.initialCrop.normalized();
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accentColor(context);
    // 桌面习惯：Esc = 取消。本页是整屏模态、没有输入框，不会和输入法抢键；
    // 页内 Focus 同时保证按键不会落到被整屏盖住的下面一页。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: _canvasColor,
          appBar: AppBar(
            backgroundColor: _canvasColor,
            foregroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            // 本页永远是深色画布，浅色主题下也要让状态栏用浅色图标。
            systemOverlayStyle: SystemUiOverlayStyle.light,
            leading: IconButton(
              tooltip: '取消',
              onPressed: _cancel,
              icon: const Icon(Icons.close_rounded),
            ),
            title: Text(widget.title),
            actions: [
              TextButton(
                onPressed: _imageSize == null ? null : _confirm,
                style: TextButton.styleFrom(
                  foregroundColor: accent,
                  disabledForegroundColor: Colors.white.withValues(alpha: .28),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: const Text('完成'),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                  child: LayoutBuilder(builder: _buildPreview),
                ),
              ),
              _buildControlBar(accent),
            ],
          ),
        ),
      ),
    );
  }

  /// 全局背景层铺满的是**真实窗口**。
  ///
  /// 不能直接用 `MediaQuery.sizeOf`：车机模式下本页拿到的 MediaQuery 被
  /// [CarDisplayViewport] 换成了「按 scale 收缩、扣掉上下物理留白」的虚拟
  /// 视口，而背景层在它外面、仍然铺满真实窗口；两者在开了车机留白时宽高比
  /// 并不相同，用虚拟比例取框会让用户裁出来的画面对不上背景实际露出的部分。
  double _backgroundAspectRatio(BuildContext context) {
    final physical = View.of(context).physicalSize;
    if (physical.width.isFinite &&
        physical.height.isFinite &&
        physical.width > 0 &&
        physical.height > 0) {
      final aspect = physical.width / physical.height;
      if (aspect.isFinite && aspect > 0) return aspect;
    }
    // 拿不到窗口尺寸（极端平台/测试替身）时退回 MediaQuery，至少不会崩。
    return MediaQuery.sizeOf(context).aspectRatio;
  }

  /// 预览区：按背景层的真实窗口宽高比居中框出裁剪范围。
  Widget _buildPreview(BuildContext context, BoxConstraints constraints) {
    final screenAspect = _backgroundAspectRatio(context);
    final maxWidth = constraints.maxWidth;
    final maxHeight = constraints.maxHeight;
    if (!screenAspect.isFinite ||
        screenAspect <= 0 ||
        !maxWidth.isFinite ||
        !maxHeight.isFinite ||
        maxWidth <= 0 ||
        maxHeight <= 0) {
      _frameSize = null;
      return const SizedBox.shrink();
    }

    // 预览框取「真实窗口」比例，而不是 AppBar 下方这块剩余空间的比例；
    // 否则用户看到的裁切结果和实际显示会偏。车机模式的虚拟视口同理。
    var width = maxWidth;
    var height = width / screenAspect;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * screenAspect;
    }
    final frameSize = Size(width, height);
    // 手势换算要的是框的真实像素尺寸。这里只写字段不 setState：
    // build 阶段改状态会触发「setState during build」。
    final frameChanged = _frameSize != null && _frameSize != frameSize;
    _frameSize = frameSize;
    if (frameChanged && _imageSize != null) {
      // 旋转/改窗口大小/改车机参数后可见范围会变，旧焦点可能落到范围外：
      // 渲染层会把它钉在边缘（画面不跳），但拖动会出现「先空走一段」。
      // build 里不能直接 setState，放到帧后夹一次。
      _scheduleCropClamp();
    }

    return Center(
      child: SizedBox.fromSize(
        size: frameSize,
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Listener(
            // 滚轮是 pointer signal，不参与 gesture arena，必须用 Listener
            // 单独接；放在裁剪框内才能拿指针位置做缩放锚点。
            onPointerSignal: _onPointerSignal,
            child: GestureDetector(
              // 背景图是 CustomPaint，本身不参与命中测试；不设 opaque 的话
              // 只有边框等装饰能被拖到，手势会时灵时不灵。
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              // 双击直接回到「居中 + 最小放大」，比拖回原位快得多。
              onDoubleTap: _resetCrop,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      BackgroundCropView(
                        image: widget.image,
                        crop: _crop,
                        onImageSizeChanged: _onImageSizeChanged,
                        errorBuilder: _buildError,
                      ),
                      if (_imageSize != null)
                        // 三分线只做构图参考，IgnorePointer 保证它不抢手势。
                        const IgnorePointer(
                          child: CustomPaint(painter: _ThirdsGridPainter()),
                        ),
                      if (_imageSize == null && !_failed)
                        const Positioned.fill(
                          child: ColoredBox(
                            color: Color(0x59000000),
                            child: Center(
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      // 边框必须画在图片之上：DecoratedBox 的 border 会被
                      // 随后绘制的图片盖住，只有叠在最上层才能看到裁切边界。
                      const IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.all(
                              Radius.circular(AppRadius.md),
                            ),
                            border: Border.fromBorderSide(
                              BorderSide(color: _borderColor),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部控制条：重置、缩小 / 放大、当前倍率与操作提示。
  Widget _buildControlBar(Color accent) {
    final canEdit = _imageSize != null;
    final canZoomOut = canEdit && _crop.zoom > BackgroundCrop.minZoom;
    final canZoomIn = canEdit && _crop.zoom < BackgroundCrop.maxZoom;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: .08)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 用 Wrap 而不是 Row：窄屏 + 大字体时按钮能换行，不会横向溢出。
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              children: [
                TextButton(
                  onPressed: _crop.isDefault ? null : _resetCrop,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white.withValues(
                      alpha: .28,
                    ),
                    textStyle: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  child: const Text('重置'),
                ),
                _ZoomButton(
                  icon: Icons.remove_rounded,
                  tooltip: '缩小背景',
                  onPressed: canZoomOut ? () => _zoomBy(0.8) : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '${(_crop.zoom * 100).round()}%',
                    style: TextStyle(
                      color: accent,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      // 等宽数字：倍率变化时文字宽度不跳动，按钮位置才稳。
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                _ZoomButton(
                  icon: Icons.add_rounded,
                  tooltip: '放大背景',
                  onPressed: canZoomIn ? () => _zoomBy(1.25) : null,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '拖动调整位置 · 双指或滚轮缩放',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: .55),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 深色画布上的强调色。
  ///
  /// 主色来自用户自定义配色，可能选到很暗的颜色，压在近黑背景上几乎看不见；
  /// 亮度不足时退回白色，保证「完成」和放大倍率始终可读。
  Color _accentColor(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ThemeData.estimateBrightnessForColor(primary) == Brightness.dark
        ? Colors.white
        : primary;
  }

  void _onImageSizeChanged(Size size) {
    if (!mounted || size == _imageSize || size.isEmpty) return;
    // 手改 prefs / 旧版本可能把焦点存到可见范围之外：sourceRect 会把它钉在
    // 图像边缘，手感上表现为「先拖一段没反应」。拿到尺寸后用零位移平移把
    // 焦点夹回可见范围（视觉上不变，但后续拖动立刻跟手）。
    final boxSize = _frameSize;
    final clamped = boxSize == null || boxSize.isEmpty
        ? _crop
        : panBackgroundCrop(
            crop: _crop,
            delta: Offset.zero,
            imageSize: size,
            boxSize: boxSize,
          );
    setState(() {
      _imageSize = size;
      _failed = false;
      _crop = clamped.normalized();
    });
  }

  /// 帧后把焦点夹回当前可见范围（布局比例变化时调用）。
  ///
  /// 零位移的 [panBackgroundCrop] 只做夹紧、不改缩放，因此不会打断用户
  /// 正在进行的操作；`_crop` 没变时也不 setState。
  void _scheduleCropClamp() {
    if (_clampScheduled) return;
    _clampScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _clampScheduled = false;
      if (!mounted) return;
      final imageSize = _imageSize;
      final boxSize = _frameSize;
      if (imageSize == null || boxSize == null || boxSize.isEmpty) return;
      final clamped = panBackgroundCrop(
        crop: _crop,
        delta: Offset.zero,
        imageSize: imageSize,
        boxSize: boxSize,
      ).normalized();
      if (clamped != _crop) setState(() => _crop = clamped);
    });
  }

  /// 解码失败时的提示。
  ///
  /// errorBuilder 是在 [BackgroundCropView] 的 build 里同步调用的，此时
  /// setState 会报「setState during build」；把失败状态放到帧后再同步，
  /// 只用来撤掉加载转圈，不影响本次错误提示。
  Widget _buildError(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _failed) return;
      setState(() => _failed = true);
    });
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_rounded,
              size: 34,
              color: Colors.white.withValues(alpha: .45),
            ),
            const SizedBox(height: 8),
            Text(
              '图片加载失败',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: .7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureScale = 1;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final imageSize = _imageSize;
    final boxSize = _frameSize;
    if (imageSize == null || boxSize == null || boxSize.isEmpty) return;

    var crop = _crop;
    final cumulativeScale = details.scale;
    if (cumulativeScale.isFinite && cumulativeScale > 0 && _gestureScale > 0) {
      // scale 是相对手势起点的累计值：从 1 捏到 2 时，第一次 update 的增量
      // 是 2 / 1 = 2，下一次同样是 2 就不该再放大，所以每帧都要推进基准值。
      // 不再按「增量太小」丢帧：慢速捏合每帧增量极小，丢帧会被永久吞掉；
      // zoomBackgroundCrop 在 newZoom == zoom 时会自行早退，不会多余 setState。
      crop = zoomBackgroundCrop(
        crop: crop,
        scaleFactor: cumulativeScale / _gestureScale,
        imageSize: imageSize,
        boxSize: boxSize,
        focal: _normalizedFocal(details.localFocalPoint, boxSize),
      );
      _gestureScale = cumulativeScale;
    }

    // focalPointDelta 已经是本控件内的坐标增量；单指拖动与双指移动共用它，
    // 所以「手指往哪拖、画面跟着往哪走」的手感在两种手势下一致。
    final delta = details.focalPointDelta;
    if (delta != Offset.zero && delta.dx.isFinite && delta.dy.isFinite) {
      crop = panBackgroundCrop(
        crop: crop,
        delta: delta,
        imageSize: imageSize,
        boxSize: boxSize,
      );
    }

    _applyCrop(crop);
  }

  /// 桌面鼠标滚轮 / 触控板滚动缩放。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final imageSize = _imageSize;
    final boxSize = _frameSize;
    if (imageSize == null || boxSize == null || boxSize.isEmpty) return;
    final dy = event.scrollDelta.dy;
    if (!dy.isFinite || dy == 0) return;

    // 滚轮向上（dy < 0）放大。指数换算让一次常规滚轮约 1.1 倍；再夹到
    // [0.8, 1.25]：触控板一次能连发几十个事件，不夹会瞬间顶到 3 倍。
    final factor = math.pow(1.0015, -dy).toDouble().clamp(0.8, 1.25).toDouble();
    _applyCrop(
      zoomBackgroundCrop(
        crop: _crop,
        scaleFactor: factor,
        imageSize: imageSize,
        boxSize: boxSize,
        focal: _normalizedFocal(event.localPosition, boxSize),
      ),
    );
  }

  /// 底部按钮缩放。
  ///
  /// 「±25%」用乘法步进而非加减：放大 ×1.25、缩小 ÷1.25（即 0.8），
  /// 这样一进一出能回到原倍数，不会因为加减产生累积漂移。
  void _zoomBy(double factor) {
    final imageSize = _imageSize;
    final boxSize = _frameSize;
    if (imageSize == null || boxSize == null || boxSize.isEmpty) return;
    _applyCrop(
      zoomBackgroundCrop(
        crop: _crop,
        scaleFactor: factor,
        imageSize: imageSize,
        boxSize: boxSize,
      ),
    );
  }

  Offset _normalizedFocal(Offset position, Size boxSize) {
    return Offset(
      (position.dx / boxSize.width).clamp(0.0, 1.0).toDouble(),
      (position.dy / boxSize.height).clamp(0.0, 1.0).toDouble(),
    );
  }

  void _applyCrop(BackgroundCrop next) {
    final normalized = next.normalized();
    if (!mounted || normalized == _crop) return;
    setState(() => _crop = normalized);
  }

  void _resetCrop() {
    _applyCrop(BackgroundCrop.center);
  }

  void _confirm() {
    if (_imageSize == null || _popping) return;
    _popping = true;
    Navigator.of(context).pop<BackgroundCrop>(_crop.normalized());
  }

  void _cancel() {
    if (_popping) return;
    _popping = true;
    // 系统返回同样会 pop null；调用方据 null 判断「用户放弃」，
    // 不会覆盖已有背景，因此这里不需要额外的「是否放弃」确认弹窗。
    Navigator.of(context).maybePop();
  }
}

/// 缩放按钮：tooltip 同时充当读屏标签。
///
/// 不要再外包一层 `Semantics(excludeSemantics: true)`：那会把 IconButton
/// 自身的点击动作一并丢掉，读屏用户能聚焦却按不动。tooltip 文案带上「背景」，
/// 让读屏用户在整页编辑器里知道自己操作的对象。
class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon),
      iconSize: 22,
      color: Colors.white,
      disabledColor: Colors.white.withValues(alpha: .25),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// 三分线网格：只做构图参考，画得足够淡，不抢背景图本身的视觉。
class _ThirdsGridPainter extends CustomPainter {
  const _ThirdsGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .22)
      ..strokeWidth = 1;
    for (final fraction in const [1 / 3, 2 / 3]) {
      final x = size.width * fraction;
      final y = size.height * fraction;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ThirdsGridPainter oldDelegate) => false;
}
