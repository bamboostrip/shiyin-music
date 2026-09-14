import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_window_controls.dart';

/// 顶栏（自定义标题栏）总高。QQ 音乐 PC 同量级：40px 细条 + 30px 搜索胶囊。
/// 搜索浮层（shell）按此常量贴着顶栏下缘定位。
const double kDesktopTitleBarHeight = 40;

/// 桌面沉浸式自定义标题栏（QQ 音乐 PC 式）。
///
/// 左侧品牌 Logo/标题（与侧栏 208 对齐），中间居中搜索胶囊（可输入，
/// 聚焦时经 [onFocusChanged]/[onQueryChanged]/[onSubmitted] 交给
/// shell 展示热门/历史浮层并提交搜索），右侧标准 Windows
/// 最小化/最大化（还原）/关闭按钮。搜索框两侧保留拖拽区，保证空白处
/// 仍可拖动窗口、双击最大化；搜索框自身在拖拽区之外，可正常点按聚焦。
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({
    super.key,
    this.player,
    this.onSearch,
    this.controller,
    this.focusNode,
    this.onQueryChanged,
    this.onSubmitted,
    this.onFocusChanged,
    this.onEscape,
    this.onChromeTap,
    this.onOpenIdentify,
  });

  /// 保留参数兼容旧调用点：播放信息已由底部播放栏展示，标题栏不再重复显示。
  final Object? player;

  /// 搜索胶囊点击回调；为 null 时不展示搜索框（测试/旧调用兼容）。
  /// 未提供可输入相关回调时仍作只读按钮使用。
  final VoidCallback? onSearch;

  /// 顶栏搜索文本（桌面 shell 持有，便于提交后仍显示关键词）。
  final TextEditingController? controller;

  final FocusNode? focusNode;

  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<bool>? onFocusChanged;

  /// 搜索框内按下 Esc（收起浮层/清空焦点）。
  final VoidCallback? onEscape;

  /// 点击标题栏非搜索区（品牌/拖拽区/窗口按钮）时回调，用于收起搜索浮层。
  final VoidCallback? onChromeTap;

  /// 点击搜索胶囊右侧「听歌识曲」按钮时回调。
  final VoidCallback? onOpenIdentify;

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
      height: kDesktopTitleBarHeight,
      color: colorScheme.surface,
      child: Row(
        children: [
          // 左侧品牌区（与侧栏宽度 208 对齐）
          SizedBox(
            width: 208,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => widget.onChromeTap?.call(),
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
          ),

          // 中间：搜索胶囊居中（QQ 音乐 PC 式）。固定 420 宽，两侧拖拽区
          // 贴到胶囊边缘——若用 Flexible 撑开，胶囊左右会留下不可拖的死区。
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _TitleBarDragSpacer(
                    key: const ValueKey('desktop_title_bar_drag_left'),
                    onTap: widget.onChromeTap,
                  ),
                ),
                if (widget.onSearch != null || widget.controller != null)
                  SizedBox(
                    width: 420,
                    child: _TitleBarSearchField(
                      onTapLegacy: widget.onSearch,
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      onQueryChanged: widget.onQueryChanged,
                      onSubmitted: widget.onSubmitted,
                      onFocusChanged: widget.onFocusChanged,
                      onEscape: widget.onEscape,
                      onOpenIdentify: widget.onOpenIdentify,
                    ),
                  )
                else
                  Expanded(
                    child: _TitleBarDragSpacer(
                      key: const ValueKey('desktop_title_bar_middle'),
                      onTap: widget.onChromeTap,
                    ),
                  ),
                Expanded(
                  child: _TitleBarDragSpacer(
                    key: const ValueKey('desktop_title_bar_drag_right'),
                    onTap: widget.onChromeTap,
                  ),
                ),
              ],
            ),
          ),

          // 右侧窗口控制按钮区（与全屏页面浮层共用同一套按钮）。
          // 高度传标题栏全高：按钮贴窗口顶边，与原生 Windows 标题栏一致，
          // 否则按钮矮于顶栏垂直居中时会在顶部留出空白。
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DesktopWindowCaptionButton(
                icon: Icons.remove_rounded,
                tooltip: '最小化',
                height: kDesktopTitleBarHeight,
                onTap: () async {
                  widget.onChromeTap?.call();
                  try {
                    await windowManager.minimize();
                  } catch (_) {}
                },
              ),
              DesktopWindowCaptionButton(
                icon: _isMaximized
                    ? Icons.filter_none_rounded
                    : Icons.crop_square_rounded,
                tooltip: _isMaximized ? '还原' : '最大化',
                height: kDesktopTitleBarHeight,
                onTap: () async {
                  widget.onChromeTap?.call();
                  try {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  } catch (_) {}
                },
              ),
              DesktopWindowCaptionButton(
                icon: Icons.close_rounded,
                tooltip: '关闭',
                height: kDesktopTitleBarHeight,
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

/// 标题栏空白拖拽区：填充剩余空间保证可拖动，双击切换最大化/还原。
///
/// [onTap] 用 PointerDown 即刻触发（而非 GestureDetector.onTap）：
/// 手势竞技场会把 tap 推迟到与 DragToMoveArea 消歧之后，表现为
/// 「点顶栏收起搜索浮层卡一下」；pointer down 无延迟。
class _TitleBarDragSpacer extends StatelessWidget {
  const _TitleBarDragSpacer({super.key, this.onTap});

  final VoidCallback? onTap;

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onTap?.call(),
      child: DragToMoveArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTap: _toggleMaximize,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// 标题栏居中搜索胶囊。
///
/// 提供 [controller]/[focusNode] 时为可输入 TextField（QQ 音乐 PC 式）：
/// 聚焦展示浮层、Enter 提交。否则退回只读按钮（测试/旧调用兼容）。
class _TitleBarSearchField extends StatefulWidget {
  const _TitleBarSearchField({
    this.onTapLegacy,
    this.controller,
    this.focusNode,
    this.onQueryChanged,
    this.onSubmitted,
    this.onFocusChanged,
    this.onEscape,
    this.onOpenIdentify,
  });

  final VoidCallback? onTapLegacy;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<bool>? onFocusChanged;
  final VoidCallback? onEscape;
  final VoidCallback? onOpenIdentify;

  @override
  State<_TitleBarSearchField> createState() => _TitleBarSearchFieldState();
}

class _TitleBarSearchFieldState extends State<_TitleBarSearchField> {
  var _hovering = false;
  var _focused = false;

  bool get _interactive => widget.controller != null;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_handleFocus);
  }

  @override
  void didUpdateWidget(covariant _TitleBarSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_handleFocus);
      widget.focusNode?.addListener(_handleFocus);
    }
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_handleFocus);
    super.dispose();
  }

  void _handleFocus() {
    final focused = widget.focusNode?.hasFocus ?? false;
    if (focused != _focused) {
      setState(() => _focused = focused);
      widget.onFocusChanged?.call(focused);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 聚焦描边用中性深灰而非 primary：金色主题下 primary 边框会像
    // 「黄框」，与 QQ/网易云的灰底搜索胶囊观感不符。
    final borderColor = _focused
        ? colorScheme.onSurface.withValues(alpha: isDark ? .55 : .38)
        : colorScheme.outlineVariant.withValues(alpha: isDark ? .55 : .40);
    // 浅色：固定浅灰 #F3F4F6（与首页搜索胶囊一致）；深色用中性容器色。
    final bg = isDark
        ? colorScheme.surfaceContainerHighest
        : (_hovering ? const Color(0xFFECEEF1) : const Color(0xFFF3F4F6));
    final hintColor = colorScheme.onSurfaceVariant.withValues(
      alpha: isDark ? .7 : .6,
    );

    return SizedBox(
      width: double.infinity,
      child: MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 30,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: borderColor,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 16.5,
              color: colorScheme.onSurfaceVariant.withValues(
                alpha: isDark ? .65 : .5,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _interactive
                  ? Focus(
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.escape) {
                          widget.onEscape?.call();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                      key: const ValueKey('desktop_title_bar_search'),
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      textInputAction: TextInputAction.search,
                      onChanged: widget.onQueryChanged,
                      onSubmitted: widget.onSubmitted,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: colorScheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        // 全局 InputDecorationTheme 会填白底，盖住胶囊灰底，
                        // 必须显式关掉 filled。
                        filled: false,
                        fillColor: Colors.transparent,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: '搜索歌曲、歌手、专辑',
                        hintStyle: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w400,
                          color: hintColor,
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    )
                  : Semantics(
                      button: true,
                      label: '搜索音乐',
                      onTap: widget.onTapLegacy,
                      child: InkWell(
                        key: const ValueKey('desktop_title_bar_search'),
                        onTap: widget.onTapLegacy,
                        excludeFromSemantics: true,
                        borderRadius: BorderRadius.circular(12),
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                        mouseCursor: SystemMouseCursors.click,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '搜索音乐',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: hintColor,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            if (!_interactive) ...[
              const SizedBox(width: 6),
              Text(
                'Ctrl+F',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: .45),
                ),
              ),
            ],
            if (widget.onOpenIdentify != null) ...[
              const SizedBox(width: 4),
              _DesktopIdentifyButton(onTap: widget.onOpenIdentify!),
            ],
          ],
        ),
      ),
    ),
    );
  }
}

/// 顶栏搜索胶囊内部右侧「听歌识曲」按钮。
class _DesktopIdentifyButton extends StatefulWidget {
  const _DesktopIdentifyButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_DesktopIdentifyButton> createState() => _DesktopIdentifyButtonState();
}

class _DesktopIdentifyButtonState extends State<_DesktopIdentifyButton> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Tooltip(
          message: '听歌识曲',
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _hovering
                  ? colorScheme.onSurface.withValues(alpha: isDark ? .12 : .08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.graphic_eq_rounded,
              size: 15.5,
              color: _hovering
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant.withValues(
                      alpha: isDark ? .8 : .65,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
