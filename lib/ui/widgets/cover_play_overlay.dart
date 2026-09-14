import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'now_playing_badge.dart';

/// 封面悬停播放蒙层的浮现动画时长（桌面 hover 反馈，轻快不拖沓）。
const Duration kCoverPlayOverlayDuration = Duration(milliseconds: 150);

/// 封面悬停播放蒙层（PC 惯例：Spotify / 网易云）。
///
/// hover 时封面浮现半透明蒙层 + 居中圆形播放按钮，点击按钮 = 直接播放；
/// 蒙层为纯视觉层（永不参与命中测试），播放按钮仅在浮现后拦截点击，
/// 未 hover 时不遮挡卡片本体，卡片单击行为保持不变。
///
/// [enabled] 为 false（移动端 / 车机端）时直接返回 [cover] 本体，
/// 不注册任何 hover / 手势逻辑，行为与接入前逐字节一致。
class CoverPlayOverlay extends StatefulWidget {
  const CoverPlayOverlay({
    super.key,
    required this.cover,
    required this.onPlay,
    this.enabled = true,
    this.isCurrent = false,
    this.isPlaying = false,
    this.onPause,
    this.onResume,
    this.borderRadius = AppRadius.lg,
    this.tooltip = '播放',
    this.alignment = Alignment.center,
    this.isHovered,
    this.buttonSize,
    this.iconSize = 26,
    this.buttonColor,
    this.iconColor,
    this.margin,
    this.darkenOnHover = true,
  });

  /// 封面本体（含圆角 / 描边等装饰）。
  final Widget cover;

  /// 点击悬浮播放按钮时触发（直接播放，不跳页）。
  final VoidCallback onPlay;

  /// 是否启用悬浮蒙层（首页共享卡片按 isDesktopFormFactor 门控）。
  final bool enabled;

  /// 是否为当前曲目。
  final bool isCurrent;

  /// 是否正在播放。
  final bool isPlaying;

  /// 当前曲目正在播放时点击触发（默认回退到 onPlay）。
  final VoidCallback? onPause;

  /// 当前曲目处于暂停状态时点击触发（默认回退到 onPlay）。
  final VoidCallback? onResume;

  /// 蒙层圆角，与封面圆角一致。
  final double borderRadius;

  /// 播放按钮的语义 / tooltip 文案。
  final String? tooltip;

  /// 播放按钮对齐方式（居中或右下角）。
  final AlignmentGeometry alignment;

  /// 外部驱动的 hover 状态（如父级表格行或卡片 hover 时联动触发）。
  /// 若为 null，则由自身内部 MouseRegion 驱动。
  final bool? isHovered;

  /// 播放按钮的宽高尺寸（若指定则使用 SizedBox.square，否则使用 padding）。
  final double? buttonSize;

  /// 播放按钮内部图标大小。
  final double iconSize;

  /// 播放按钮底色（默认 Theme.primary）。
  final Color? buttonColor;

  /// 播放按钮图标颜色（默认 Theme.onPrimary）。
  final Color? iconColor;

  /// 播放按钮的外边距（例如右下角对齐时距边缘的留白）。
  final EdgeInsetsGeometry? margin;

  /// hover 时是否在封面叠加半透明暗层。
  final bool darkenOnHover;

  @override
  State<CoverPlayOverlay> createState() => _CoverPlayOverlayState();
}

class _CoverPlayOverlayState extends State<CoverPlayOverlay> {
  bool _internalHovered = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.cover;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final shown = widget.isHovered ?? _internalHovered;

    final isPlayingNow = widget.isCurrent && widget.isPlaying;
    final isPausedNow = widget.isCurrent && !widget.isPlaying;

    final btnColor = widget.buttonColor ?? colorScheme.primary;
    final icnColor = widget.iconColor ?? colorScheme.onPrimary;
    final effectiveButtonSize = widget.buttonSize;

    final Widget centerControl;

    if (isPlayingNow) {
      final badgeSize = effectiveButtonSize != null
          ? (effectiveButtonSize * 0.6).clamp(14.0, 20.0)
          : 16.0;

      final badgeWidget = NowPlayingBadge(
        active: true,
        playing: true,
        color: Colors.white,
        size: badgeSize,
        barCount: 4,
      );

      final badgeButton = Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          onTap: widget.onPause ?? widget.onPlay,
          child: effectiveButtonSize != null
              ? SizedBox.square(
                  dimension: effectiveButtonSize,
                  child: Center(child: badgeWidget),
                )
              : Padding(
                  padding: const EdgeInsets.all(8),
                  child: badgeWidget,
                ),
        ),
      );

      centerControl = Tooltip(
        message: '暂停',
        child: badgeButton,
      );
    } else {
      final playIcon = Icon(
        Icons.play_arrow_rounded,
        color: icnColor,
        size: widget.iconSize,
      );

      final playButton = Material(
        color: btnColor,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          // 单击即播放 → 手型。InkWell 默认（adaptiveClickable）在 Windows/
          // macOS 原生上解析为 basic 箭头而非 click，会把外层的手型区域
          // 顶成箭头，必须显式声明。
          mouseCursor: SystemMouseCursors.click,
          onTap: isPausedNow
              ? (widget.onResume ?? widget.onPlay)
              : widget.onPlay,
          child: effectiveButtonSize != null
              ? SizedBox.square(
                  dimension: effectiveButtonSize,
                  child: Center(child: playIcon),
                )
              : Padding(
                  padding: const EdgeInsets.all(8),
                  child: playIcon,
                ),
        ),
      );

      final standardTooltip = isPausedNow ? '继续播放' : widget.tooltip;
      centerControl = standardTooltip == null
          ? playButton
          : Tooltip(
              message: standardTooltip,
              child: playButton,
            );
    }

    final positionedControl = Align(
      alignment: widget.alignment,
      child: Padding(
        padding: widget.margin ??
            (widget.alignment == Alignment.bottomRight
                ? const EdgeInsets.all(8)
                : EdgeInsets.zero),
        child: IgnorePointer(
          ignoring: isPlayingNow ? false : !shown,
          child: AnimatedOpacity(
            opacity: (isPlayingNow || shown) ? 1 : 0,
            duration: kCoverPlayOverlayDuration,
            child: AnimatedScale(
              scale: (isPlayingNow || shown) ? 1 : 0.7,
              duration: kCoverPlayOverlayDuration,
              curve: Curves.easeOutCubic,
              child: centerControl,
            ),
          ),
        ),
      ),
    );

    final showMask = (widget.darkenOnHover && shown) || isPlayingNow;

    return MouseRegion(
      onEnter: (_) => setState(() => _internalHovered = true),
      onExit: (_) => setState(() => _internalHovered = false),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 封面本体：非 positioned 子级，决定 Stack 尺寸（可在纵向
          // 无界约束的 Column 里使用）。约束有限时撑满可用空间，保证
          // 无固有尺寸的封面也不会把 Stack 缩成 0 大小；存在无界方向
          // （如卡片 Column 里的封面）时退回封面自适配尺寸。
          final Widget base = constraints.maxWidth.isFinite &&
                  constraints.maxHeight.isFinite
              ? SizedBox.expand(child: widget.cover)
              : widget.cover;
          return Stack(
            fit: StackFit.loose,
            children: [
              base,
              // 蒙层：播放中常驻显示，悬浮时按需显示。
              if (showMask)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(widget.borderRadius),
                      child: const ColoredBox(color: Colors.black38),
                    ),
                  ),
                ),
              // 居中控制组件：播放中为跳动音波，非播放中为悬浮圆形播放按钮。
              Positioned.fill(child: positionedControl),
            ],
          );
        },
      ),
    );
  }
}
