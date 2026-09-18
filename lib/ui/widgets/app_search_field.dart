import 'package:flutter/material.dart';

import 'marquee_text.dart';

/// 移动端统一搜索胶囊（首页顶栏 / 搜索页 / 歌单内过滤 / 本地检索共用）。
///
/// 以首页 [HomeSearchBar] + 搜索页 AppBar 输入框为基准收敛：
/// - 高 36、整胶囊圆角（height / 2）；
/// - 浅色 `#F3F4F6`、深色白 `7%`，常态无边框无阴影；
/// - 聚焦时染一圈主色细边框（1.3px, primary 65%）；
/// - 左侧 16.5px 搜索图标 + 14px 提示，输入文本同字号；
/// - 提示文案不用 [InputDecoration.hintText]，而是与输入行同层叠放的
///  普通 Text（Windows 下 Microsoft YaHei UI 度量会让 hint 基线比输入
///  行低约 4px，搜索页原注释保留此规避手段）。
///
/// 两种形态：
/// - 可输入：传 [controller]（受控，父级持有并监听）；
/// - 纯入口：不传 [controller]，传 [onTap]，渲染居中提示的只读胶囊
///  （首页顶栏用，点击跳搜索页）。
class AppSearchField extends StatefulWidget {
  const AppSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction = TextInputAction.search,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.height = 36.0,
  }) : onTap = null;

  const AppSearchField.tap({
    super.key,
    required this.onTap,
    this.hintText = '搜索歌曲、歌手、专辑',
    this.height = 36.0,
  })  : controller = null,
        focusNode = null,
        autofocus = false,
        textInputAction = TextInputAction.search,
        onChanged = null,
        onSubmitted = null,
        enabled = true;

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hintText;
  final VoidCallback? onTap;
  final bool autofocus;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final double height;

  bool get isTapMode => controller == null;

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  /// 后缀槽（清除按钮；空态为等宽占位）的宽度。
  ///
  /// 输入区右边界 = Stack 右边界 − 本值。覆盖层（提示/跑马灯）必须按同样
  /// 宽度内缩，否则失焦态的跑马灯会把滚动中的文字画到 X 图标上。
  static const double _suffixSlotWidth = 32;

  FocusNode? _internalFocusNode;
  bool _focused = false;
  bool _hasText = false;

  FocusNode get _effectiveFocusNode =>
      widget.focusNode ?? _internalFocusNode!;

  TextEditingController? get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null && !widget.isTapMode) {
      _internalFocusNode = FocusNode();
    }
    if (!widget.isTapMode) {
      _effectiveFocusNode.addListener(_handleFocusChanged);
      _hasText = _controller!.text.isNotEmpty;
      _controller!.addListener(_handleTextChanged);
    }
  }

  @override
  void didUpdateWidget(covariant AppSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isTapMode) return;
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_handleFocusChanged);
      if (oldWidget.focusNode == null) {
        _internalFocusNode?.removeListener(_handleFocusChanged);
        _internalFocusNode?.dispose();
        _internalFocusNode = null;
      }
      if (widget.focusNode == null && _internalFocusNode == null) {
        _internalFocusNode = FocusNode();
      }
      _effectiveFocusNode.addListener(_handleFocusChanged);
      _focused = _effectiveFocusNode.hasFocus;
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_handleTextChanged);
      _controller?.addListener(_handleTextChanged);
      _handleTextChanged();
    }
  }

  @override
  void dispose() {
    if (!widget.isTapMode) {
      _effectiveFocusNode.removeListener(_handleFocusChanged);
      _controller?.removeListener(_handleTextChanged);
    }
    _internalFocusNode?.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    final focused = _effectiveFocusNode.hasFocus;
    if (focused != _focused && mounted) {
      setState(() => _focused = focused);
    }
  }

  void _handleTextChanged() {
    final hasText = (_controller?.text.isNotEmpty ?? false);
    if (hasText != _hasText && mounted) {
      setState(() => _hasText = hasText);
    }
  }

  void _handleClear() {
    _controller?.clear();
    // controller.clear() 会触发 listener（父级过滤/联想逻辑），
    // 这里额外直调一次，保证只依赖 onChanged 的父级也能即时收口。
    // 清除后保持聚焦（搜索页原逻辑：点 × 后光标仍在框内，可继续输入）。
    widget.onChanged?.call('');
    if (_effectiveFocusNode.canRequestFocus) {
      _effectiveFocusNode.requestFocus();
    }
    if (mounted) setState(() => _hasText = false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark
        ? Colors.white.withValues(alpha: 0.07)
        : const Color(0xFFF3F4F6);
    final iconColor =
        colorScheme.onSurfaceVariant.withValues(alpha: isDark ? 0.65 : 0.5);
    final hintColor =
        colorScheme.onSurfaceVariant.withValues(alpha: isDark ? 0.7 : 0.6);
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: isDark
              ? colorScheme.onSurface.withValues(alpha: 0.92)
              : colorScheme.onSurface,
          fontWeight: FontWeight.w400,
          fontSize: 14,
        );
    final hintStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: hintColor,
          fontWeight: FontWeight.w400,
          fontSize: 14,
        );

    final borderRadius = BorderRadius.circular(widget.height / 2);

    // 纯入口形态：居中图标 + 提示（首页顶栏同款）。
    if (widget.isTapMode) {
      return Container(
        height: widget.height,
        decoration: BoxDecoration(color: bg, borderRadius: borderRadius),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search_rounded, size: 16.5, color: iconColor),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      widget.hintText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: hintStyle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 可输入形态：与搜索页 AppBar 同款（左对齐图标 + 输入 + 清除）。
    // 常态透明边框占位，聚焦时染主色细边框，避免聚焦前后尺寸跳动。
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: borderRadius,
        border: _focused
            ? Border.all(
                color: colorScheme.primary.withValues(alpha: 0.65),
                width: 1.3,
              )
            : Border.all(color: Colors.transparent, width: 1),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.search_rounded, size: 16.5, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                TextField(
                  controller: _controller,
                  focusNode: _effectiveFocusNode,
                  autofocus: widget.autofocus,
                  enabled: widget.enabled,
                  textInputAction: widget.textInputAction,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  textAlignVertical: TextAlignVertical.center,
                  // 失焦且有文字时把原生文字置为透明，交由下方 MarqueeText
                  // 覆盖层渲染：TextField 失焦态只会把超长文本裁成省略号，
                  // 长歌名/歌手名看不到后半截。
                  style: (!_focused && _hasText)
                      ? (textStyle ?? const TextStyle()).copyWith(
                          color: Colors.transparent,
                        )
                      : textStyle,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    suffixIcon: _hasText
                        ? IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 28,
                              height: 28,
                            ),
                            icon: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: isDark
                                  ? colorScheme.onSurface
                                      .withValues(alpha: 0.86)
                                  : colorScheme.onSurfaceVariant,
                            ),
                            onPressed: _handleClear,
                          )
                        // 空态也占住后缀槽位：空态与输入态装饰器高度
                        // 一致，textAlignVertical.center 的垂直再分配才会
                        // 生效，光标与提示文字上下居中。
                        : const SizedBox(
                            width: _suffixSlotWidth,
                            height: _suffixSlotWidth,
                          ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: _suffixSlotWidth,
                      minHeight: _suffixSlotWidth,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (!_hasText)
                  Positioned.fill(
                    right: _suffixSlotWidth,
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.hintText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: hintStyle,
                        ),
                      ),
                    ),
                  ),
                // 超长文本跑马灯覆盖层（仅失焦态：聚焦时由 TextField 自己
                // 跟光标横向滚动）。必须用 ValueListenableBuilder 直接监听
                // controller —— 本组件的 _handleTextChanged 刻意只在
                // "空↔非空"边界 setState（增量优化），拿 _hasText 驱动的话
                // 覆盖层文字不会跟着输入更新。
                if (!_focused)
                  Positioned.fill(
                    // 右侧让出后缀槽：输入区右边界止于 X 之前，跑马灯必须
                    // 按同一边界裁剪，否则滚动中的文字会盖到 X 图标上。
                    right: _suffixSlotWidth,
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _controller!,
                          builder: (context, value, _) {
                            if (value.text.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return MarqueeText.text(
                              value.text,
                              style: textStyle,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 无文字时补右内边距：有清除按钮时按钮自带边距，无按钮时
          // TextField 会贴到容器右边缘、压住外圈边框。
          if (!_hasText) const SizedBox(width: 12),
        ],
      ),
    );
  }
}
