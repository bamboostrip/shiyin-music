import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_log_service.dart';
import '../adaptive_layout.dart';
import '../widgets/toast.dart';

/// 运行日志与诊断页面。
///
/// 数据源是 [AppLogService] 的内存环形缓存 + 实时广播流；磁盘上的历史归档
/// 通过「导出全部日志」取出（导出/复制前统一脱敏）。本页只做查看、筛选、
/// 复制、导出与清空，不改日志配置，也不影响播放主流程。
class DiagnosticsLogPage extends StatefulWidget {
  const DiagnosticsLogPage({super.key});

  /// 日志筛选（纯函数，便于单测）：级别 + 关键词（消息或通道 tag 命中）。
  static List<LogEntry> filterEntries(
    List<LogEntry> entries, {
    String keyword = '',
    LogLevel? level,
  }) {
    final normalizedKeyword = keyword.trim().toLowerCase();
    if (normalizedKeyword.isEmpty && level == null) {
      return List<LogEntry>.of(entries);
    }
    return entries
        .where((entry) {
          if (level != null && entry.level != level) return false;
          if (normalizedKeyword.isEmpty) return true;
          if (entry.message.toLowerCase().contains(normalizedKeyword)) {
            return true;
          }
          final tag = entry.tag?.toLowerCase();
          return tag != null && tag.contains(normalizedKeyword);
        })
        .toList(growable: false);
  }

  @override
  State<DiagnosticsLogPage> createState() => _DiagnosticsLogPageState();
}

class _DiagnosticsLogPageState extends State<DiagnosticsLogPage> {
  /// 页面最多保留的条数（日志服务环形缓存 1000，这里留一倍余量防长会话）。
  static const int _kMaxViewEntries = 2000;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final List<LogEntry> _entries = [];

  StreamSubscription<LogEntry>? _logSub;
  LogStats? _stats;
  String _keyword = '';
  LogLevel? _selectedLevel;
  bool _autoScroll = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _entries.addAll(AppLogService.instance.recentEntries);
    _logSub = AppLogService.instance.logStream.listen(_onNewEntry);
    _reloadStats();
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onNewEntry(LogEntry entry) {
    if (!mounted) return;
    setState(() {
      _entries.add(entry);
      if (_entries.length > _kMaxViewEntries) {
        _entries.removeRange(0, _entries.length - _kMaxViewEntries);
      }
    });
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  Future<void> _reloadStats() async {
    final stats = await AppLogService.instance.getLogStats();
    if (!mounted) return;
    setState(() => _stats = stats);
  }

  Future<void> _refresh() async {
    setState(() {
      _entries
        ..clear()
        ..addAll(AppLogService.instance.recentEntries);
    });
    await _reloadStats();
    if (!mounted) return;
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
  }

  List<LogEntry> get _filteredEntries => DiagnosticsLogPage.filterEntries(
    _entries,
    keyword: _keyword,
    level: _selectedLevel,
  );

  bool get _hasFilter => _keyword.isNotEmpty || _selectedLevel != null;

  String _filteredText() =>
      _filteredEntries.map((entry) => entry.format()).join('\n');

  Future<void> _handleCopy({required bool filteredOnly}) async {
    final success = filteredOnly
        ? await AppLogService.instance.copyLogsToClipboard(
            customContent: _filteredText(),
          )
        : await AppLogService.instance.copyLogsToClipboard();
    if (!mounted) return;
    if (!success) {
      Toast.error('复制日志失败');
      return;
    }
    Toast.success(
      filteredOnly
          ? '已复制当前筛选的 ${_filteredEntries.length} 条日志'
          : '已复制最近 2000 行日志到剪贴板',
    );
  }

  Future<void> _handleExport({required bool filteredOnly}) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final path = await AppLogService.instance.exportLogsToFile(
        fullLogs: !filteredOnly,
        customContent: filteredOnly ? _filteredText() : null,
      );
      if (!mounted) return;
      if (path == null) {
        Toast.error('导出日志失败');
        return;
      }
      await _reloadStats();
      if (!mounted) return;
      await _showExportResult(path, filteredOnly: filteredOnly);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _showExportResult(
    String path, {
    required bool filteredOnly,
  }) async {
    final stats = _stats;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Color(0xFF24C768)),
            const SizedBox(width: 8),
            Expanded(child: Text(filteredOnly ? '筛选日志导出成功' : '全量日志导出成功')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              filteredOnly
                  ? '已导出当前筛选的 ${_filteredEntries.length} 条日志：'
                  : '已导出本地全部日志（含历史归档）：',
            ),
            if (!filteredOnly && stats != null) ...[
              const SizedBox(height: 6),
              Text(
                '共 ${stats.fileCount} 个文件 · ${stats.formattedSize}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.maxFinite,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                path,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: path));
              if (!dialogContext.mounted) return;
              Toast.success('路径已复制到剪贴板');
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制路径'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空本地日志'),
        content: const Text(
          '确定要删除本地全部日志文件与当前会话缓存吗？\n'
          '此操作不可恢复，建议先把需要排查的日志导出留存。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await AppLogService.instance.clearLogs();
    if (!mounted) return;
    setState(() => _entries.clear());
    await _reloadStats();
    if (!mounted) return;
    Toast.success('本地日志已清空');
  }

  Future<void> _copyLogPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    Toast.success('日志路径已复制');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final entries = _filteredEntries;

    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志与诊断'),
        actions: [
          IconButton(
            tooltip: _autoScroll ? '自动滚动已开启' : '自动滚动已暂停',
            icon: Icon(
              _autoScroll
                  ? Icons.vertical_align_bottom_rounded
                  : Icons.pause_circle_outline_rounded,
              color: _autoScroll ? colorScheme.primary : null,
            ),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            tooltip: '刷新日志与统计',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: '清空日志',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _handleClear,
          ),
        ],
      ),
      body: AdaptiveContentPadding(
        child: Column(
          children: [
            _StatsHeader(
              stats: _stats,
              logPath: AppLogService.instance.logFilePath,
              onCopyPath: _copyLogPath,
            ),
            _buildFilterBar(colorScheme),
            _buildPrivacyHint(colorScheme),
            Expanded(child: _buildLogList(entries, colorScheme)),
            _buildActionBar(entries, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜索日志关键词（消息或通道 tag）...',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _keyword.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      icon: const Icon(Icons.clear_rounded, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _keyword = '');
                      },
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest.withValues(
                alpha: .55,
              ),
            ),
            onChanged: (value) => setState(() => _keyword = value.trim()),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildLevelChip(null, '全部 (${_entries.length})'),
                _buildLevelChip(LogLevel.error, '错误'),
                _buildLevelChip(LogLevel.warning, '警告'),
                _buildLevelChip(LogLevel.info, '信息'),
                _buildLevelChip(LogLevel.debug, '调试'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelChip(LogLevel? level, String label) {
    final selected = _selectedLevel == level;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        selected: selected,
        selectedColor: colorScheme.primaryContainer,
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        onSelected: (_) => setState(() => _selectedLevel = level),
      ),
    );
  }

  Widget _buildPrivacyHint(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.shield_outlined,
            size: 14,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '日志可能包含歌名/歌手等收听信息，公开分享前请自行检查'
              '（导出/复制前已自动脱敏 token 等敏感值）。',
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogList(List<LogEntry> entries, ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: .25),
        ),
      ),
      child: entries.isEmpty
          ? Center(
              child: Text(
                '暂无匹配的日志记录',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : SelectionArea(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                itemCount: entries.length,
                itemBuilder: (context, index) =>
                    _buildLogRow(entries[index], colorScheme),
              ),
            ),
    );
  }

  Widget _buildLogRow(LogEntry entry, ColorScheme colorScheme) {
    final color = switch (entry.level) {
      LogLevel.error => colorScheme.error,
      LogLevel.warning => Colors.amber.shade700,
      LogLevel.debug => colorScheme.outline,
      LogLevel.info => colorScheme.onSurface,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        entry.format(),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          height: 1.45,
          color: color,
        ),
      ),
    );
  }

  Widget _buildActionBar(List<LogEntry> entries, ColorScheme colorScheme) {
    final hasFilter = _hasFilter;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '已显示 ${entries.length} / 共 ${_entries.length} 条',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (_exporting)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _handleCopy(filteredOnly: false),
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制全部'),
              ),
              OutlinedButton.icon(
                onPressed: hasFilter
                    ? () => _handleCopy(filteredOnly: true)
                    : null,
                icon: const Icon(Icons.filter_alt_outlined, size: 16),
                label: Text(hasFilter ? '复制筛选 (${entries.length})' : '复制筛选'),
              ),
              FilledButton.icon(
                onPressed: _exporting
                    ? null
                    : () => _handleExport(filteredOnly: false),
                icon: const Icon(Icons.file_download_outlined, size: 16),
                label: const Text('导出全部'),
              ),
              OutlinedButton.icon(
                onPressed: (!_exporting && hasFilter)
                    ? () => _handleExport(filteredOnly: true)
                    : null,
                icon: const Icon(Icons.filter_alt_rounded, size: 16),
                label: const Text('导出筛选'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 统计头：文件数/总体积/内存条数/文件时间范围/当前日志路径（可复制）。
class _StatsHeader extends StatelessWidget {
  const _StatsHeader({
    required this.stats,
    required this.logPath,
    required this.onCopyPath,
  });

  final LogStats? stats;
  final String? logPath;
  final Future<void> Function(String path) onCopyPath;

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _formatDateTime(DateTime dateTime) =>
      '${dateTime.year}-${_two(dateTime.month)}-${_two(dateTime.day)} '
      '${_two(dateTime.hour)}:${_two(dateTime.minute)}';

  String _timeRangeText(LogStats? currentStats) {
    final earliest = currentStats?.earliestDate;
    final latest = currentStats?.latestDate;
    if (earliest == null || latest == null) return '日志时间范围 —';
    return '日志时间范围 ${_formatDateTime(earliest)} ~ '
        '${_formatDateTime(latest)}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentStats = stats;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _statItem(
                colorScheme,
                Icons.description_outlined,
                '文件 ${currentStats?.fileCount ?? 0} 个',
              ),
              _statItem(
                colorScheme,
                Icons.sd_storage_outlined,
                currentStats?.formattedSize ?? '—',
              ),
              _statItem(
                colorScheme,
                Icons.list_alt_rounded,
                '内存 ${currentStats?.entryCount ?? 0} 条',
              ),
            ],
          ),
          const SizedBox(height: 6),
          _statItem(
            colorScheme,
            Icons.schedule_rounded,
            _timeRangeText(currentStats),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  logPath ?? '日志落盘未启用（路径解析失败）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (logPath != null)
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => onCopyPath(logPath!),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.copy_rounded,
                      size: 15,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statItem(ColorScheme colorScheme, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
