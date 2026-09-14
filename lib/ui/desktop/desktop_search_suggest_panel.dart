import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import '../../services/identify_service.dart';
import '../../services/music_api.dart';
import '../../services/search_history_service.dart';

/// 顶栏搜索聚焦时的 QQ 音乐式下拉：左侧热门搜索，右侧历史 + 清空。
///
/// 仅桌面端使用；移动端继续走 [SearchPage] 全页。
/// 顶部第一行是"听歌识曲"入口（仅支持识曲的平台渲染，
/// 见 [IdentifyService.isSupported]；macOS 桌面等不支持即整行隐藏）。
class DesktopSearchSuggestPanel extends StatefulWidget {
  const DesktopSearchSuggestPanel({
    super.key,
    required this.api,
    required this.onKeywordTap,
    required this.onOpenIdentify,
    this.maxHotCount = 10,
  });

  final MusicApi api;
  final ValueChanged<String> onKeywordTap;

  /// "听歌识曲"入口回调：shell 负责收起浮层并整屏推入识曲页
  /// （与移动端搜索页同款 fullscreenDialog 路由）。
  final VoidCallback onOpenIdentify;

  final int maxHotCount;

  @override
  State<DesktopSearchSuggestPanel> createState() =>
      _DesktopSearchSuggestPanelState();
}

class _DesktopSearchSuggestPanelState extends State<DesktopSearchSuggestPanel> {
  final _historyService = SearchHistoryService();

  List<SearchHotKeyword> _hotKeywords = const [];
  List<String> _history = const [];
  var _hotLoading = true;
  var _hotFailed = false;

  @override
  void initState() {
    super.initState();
    _loadHot();
    _loadHistory();
  }

  Future<void> _loadHot() async {
    setState(() {
      _hotLoading = true;
      _hotFailed = false;
    });
    try {
      final categories = await widget.api.searchHotKeywords();
      final keywords = categories
          .expand((c) => c.keywords)
          .where((k) => k.keyword.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _hotKeywords = keywords.length > widget.maxHotCount
            ? keywords.sublist(0, widget.maxHotCount)
            : keywords;
        _hotLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _hotLoading = false;
          _hotFailed = true;
        });
      }
    }
  }

  Future<void> _loadHistory() async {
    try {
      final history = await _historyService.getHistory();
      if (mounted) setState(() => _history = history);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: isDark ? .45 : .18),
      color: isDark ? colorScheme.surfaceContainerHigh : Colors.white,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 360),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        // 外层 Column 容纳顶部的识曲入口行；两栏区包 Flexible：
        // 入口行占掉一截高度后，热门/历史列表仍被 360 总高钳制不溢出。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 识曲入口行:isSupported 闸门——不支持平台整行不渲染,
            // 浮层保持原两栏布局不变。
            if (IdentifyService.isSupported) ...[
              _IdentifyEntryRow(onTap: widget.onOpenIdentify),
              const SizedBox(height: 10),
            ],
            Flexible(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildHotColumn(context)),
                  Container(
                    width: 1,
                    height: 280,
                    margin: const EdgeInsets.symmetric(horizontal: 14),
                    color: colorScheme.outlineVariant.withValues(
                      alpha: isDark ? .35 : .55,
                    ),
                  ),
                  Expanded(child: _buildHistoryColumn(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHotColumn(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '热门搜索',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        if (_hotLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_hotFailed)
          TextButton.icon(
            onPressed: _loadHot,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('重试'),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _hotKeywords.length,
              itemBuilder: (context, index) {
                final keyword = _hotKeywords[index].keyword;
                return _SuggestRow(
                  rank: index + 1,
                  label: keyword,
                  onTap: () => widget.onKeywordTap(keyword),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildHistoryColumn(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '搜索历史',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (_history.isNotEmpty)
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () async {
                  await _historyService.clear();
                  if (mounted) setState(() => _history = const []);
                },
                child: Text(
                  '清空',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_history.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '暂无搜索历史',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: .7),
              ),
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _history.length,
              itemBuilder: (context, index) {
                final keyword = _history[index];
                return _SuggestRow(
                  label: keyword,
                  trailing: IconButton(
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: .65),
                    ),
                    onPressed: () async {
                      await _historyService.remove(keyword);
                      if (mounted) {
                        setState(() => _history = [..._history]..remove(keyword));
                      }
                    },
                  ),
                  onTap: () => widget.onKeywordTap(keyword),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _SuggestRow extends StatefulWidget {
  const _SuggestRow({
    required this.label,
    required this.onTap,
    this.rank,
    this.trailing,
  });

  final String label;
  final VoidCallback onTap;
  final int? rank;
  final Widget? trailing;

  @override
  State<_SuggestRow> createState() => _SuggestRowState();
}

class _SuggestRowState extends State<_SuggestRow> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final rank = widget.rank;
    final rankColor = rank == null || rank > 3
        ? colorScheme.onSurfaceVariant
        : (rank == 1
            ? const Color(0xFFE34D59)
            : rank == 2
                ? const Color(0xFFF0883A)
                : const Color(0xFFF2C14E));

    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: widget.onTap,
      onHover: (h) => setState(() => _hovering = h),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: _hovering
              ? colorScheme.onSurface.withValues(alpha: .06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            if (rank != null) ...[
              SizedBox(
                width: 18,
                child: Text(
                  '$rank',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: rankColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13.5),
              ),
            ),
            if (widget.trailing != null) widget.trailing!,
          ],
        ),
      ),
    );
  }
}

/// 浮层顶部"听歌识曲"入口行：与建议行同款 hover 高亮;
/// 左侧 tonal 图标 + 文案,右侧"播放中的歌也能识别"提示小字。
class _IdentifyEntryRow extends StatefulWidget {
  const _IdentifyEntryRow({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_IdentifyEntryRow> createState() => _IdentifyEntryRowState();
}

class _IdentifyEntryRowState extends State<_IdentifyEntryRow> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      onTap: widget.onTap,
      onHover: (h) => setState(() => _hovering = h),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: _hovering
              ? colorScheme.onSurface.withValues(alpha: .06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.graphic_eq_rounded,
                size: 16,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '听歌识曲',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
            const Spacer(),
            Text(
              '播放中的歌也能识别',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: .7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
