import 'package:flutter/material.dart';

import '../design_tokens.dart';

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
    this.borderRadius = AppRadius.lg,
    this.tooltip = '播放',
  });

  /// 封面本体（含圆角 / 描边等装饰）。
  final Widget cover;

  /// 点击悬浮播放按钮时触发（直接播放，不跳页）。
  final VoidCallback onPlay;

  /// 是否启用悬浮蒙层（首页共享卡片按 isDesktopFormFactor 门控）。
  final bool enabled;

  /// 蒙层圆角，与封面圆角一致。
  final double borderRadius;

  /// 播放按钮的语义 / tooltip 文案。
  final String? tooltip;

  @override
  State<CoverPlayOverlay> createState() => _CoverPlayOverlayState();
}

class _CoverPlayOverlayState extends State<CoverPlayOverlay> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.cover;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final shown = _hovered;
    final playButton = Material(
      color: colorScheme.primary,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.onPlay,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.play_arrow_rounded,
            color: colorScheme.onPrimary,
            size: 26,
          ),
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
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
              // 蒙层：纯视觉，永不拦截点击（卡片本体点击保持可达）。
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                    child: AnimatedOpacity(
                      opacity: shown ? 1 : 0,
                      duration: kCoverPlayOverlayDuration,
                      child: const ColoredBox(color: Colors.black38),
                    ),
                  ),
                ),
              ),
              // 居中播放按钮：未浮现时不参与命中测试，浮现后才拦截点击。
              Positioned.fill(
                child: Center(
                  child: IgnorePointer(
                    ignoring: !shown,
                    child: AnimatedOpacity(
                      opacity: shown ? 1 : 0,
                      duration: kCoverPlayOverlayDuration,
                      child: AnimatedScale(
                        scale: shown ? 1 : 0.7,
                        duration: kCoverPlayOverlayDuration,
                        curve: Curves.easeOutCubic,
                        child: widget.tooltip == null
                            ? playButton
                            : Tooltip(
                                message: widget.tooltip!,
                                child: playButton,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
