import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../controllers/player_controller.dart';

/// 桌面沉浸式自定义标题栏。
///
/// 包含左侧品牌 Logo/标题、中间窗口拖拽/双击最大化区域与正在播放歌名、
/// 右侧标准 Windows 最小化/最大化（还原）/关闭按钮。
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key, required this.player});

  final PlayerController player;

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _checkMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _checkMaximized() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (mounted) {
        setState(() => _isMaximized = maximized);
      }
    } catch (_) {}
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 40,
      color: colorScheme.surface,
      child: Row(
        children: [
          // 左侧品牌区（与侧栏宽度 208 对齐）
          SizedBox(
            width: 208,
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.asset(
                        'lib/assets/logo.png',
                        width: 24,
                        height: 24,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '时音',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 中间拖拽与双击最大化/还原区域，居中展示正在播放信息
          Expanded(
            child: DragToMoveArea(
              child: GestureDetector(
                key: const ValueKey('desktop_title_bar_middle'),
                behavior: HitTestBehavior.translucent,
                onDoubleTap: () async {
                  try {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  } catch (_) {}
                },
                child: SizedBox.expand(
                  child: Center(
                    child: AnimatedBuilder(
                      animation: widget.player,
                      builder: (context, _) {
                        final song = widget.player.currentSong;
                        if (song == null) {
                          return const SizedBox.shrink();
                        }
                        return Text(
                          '${song.title} - ${song.artist}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant
                                .withValues(alpha: .65),
                            fontSize: 12,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 右侧窗口控制按钮区
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _WindowCaptionButton(
                icon: Icons.remove_rounded,
                tooltip: '最小化',
                onTap: () async {
                  try {
                    await windowManager.minimize();
                  } catch (_) {}
                },
              ),
              _WindowCaptionButton(
                icon: _isMaximized
                    ? Icons.filter_none_rounded
                    : Icons.crop_square_rounded,
                tooltip: _isMaximized ? '还原' : '最大化',
                onTap: () async {
                  try {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  } catch (_) {}
                },
              ),
              _WindowCaptionButton(
                icon: Icons.close_rounded,
                tooltip: '关闭',
                hoverColor: const Color(0xFFE81123),
                hoverIconColor: Colors.white,
                onTap: () async {
                  try {
                    await windowManager.close();
                  } catch (_) {}
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WindowCaptionButton extends StatefulWidget {
  const _WindowCaptionButton({
    required this.icon,
    required this.onTap,
    this.hoverColor,
    this.hoverIconColor,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color? hoverColor;
  final Color? hoverIconColor;
  final String? tooltip;

  @override
  State<_WindowCaptionButton> createState() => _WindowCaptionButtonState();
}

class _WindowCaptionButtonState extends State<_WindowCaptionButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final defaultIconColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final defaultHoverBg =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: .08);

    final bgColor = _isHovering
        ? (widget.hoverColor ?? defaultHoverBg)
        : Colors.transparent;
    final iconColor = _isHovering
        ? (widget.hoverIconColor ?? defaultIconColor)
        : defaultIconColor;

    Widget button = MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 40,
          color: bgColor,
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: 16,
            color: iconColor,
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      button = Tooltip(
        message: widget.tooltip!,
        waitDuration: const Duration(milliseconds: 600),
        child: button,
      );
    }

    return button;
  }
}
