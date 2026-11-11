import 'package:flutter/material.dart';

/// 可折叠长文本卡片（歌手简介 / 专辑简介）。
///
/// 默认收起为 [collapsedMaxLines] 行，只有实际超出时才显示「详细」按钮；
/// 展开后按钮变「收起」。用 [TextPainter] 预判是否溢出，避免短简介也挂一个
/// 无意义的展开按钮。
class ExpandableIntro extends StatefulWidget {
  const ExpandableIntro({
    super.key,
    required this.text,
    this.title,
    this.collapsedMaxLines = 3,
    this.padding = const EdgeInsets.all(16),
  });

  final String text;
  final String? title;
  final int collapsedMaxLines;
  final EdgeInsetsGeometry padding;

  @override
  State<ExpandableIntro> createState() => _ExpandableIntroState();
}

class _ExpandableIntroState extends State<ExpandableIntro> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text.trim();
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.onSurfaceVariant,
      height: 1.6,
      fontSize: 13.5,
    );

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: .10)
              : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: widget.padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: bodyStyle),
            maxLines: widget.collapsedMaxLines,
            textDirection: Directionality.of(context),
          )..layout(maxWidth: constraints.maxWidth);
          final overflows = painter.didExceedMaxLines;
          painter.dispose();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.title case final title?) ...[
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                alignment: Alignment.topCenter,
                child: Text(
                  text,
                  maxLines: _expanded ? null : widget.collapsedMaxLines,
                  overflow: _expanded
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                  style: bodyStyle,
                ),
              ),
              if (overflows || _expanded)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(_expanded ? '收起' : '详细'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
