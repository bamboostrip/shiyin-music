import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/cache_service.dart';
import '../../services/image_disk_cache.dart';
import '../../services/lyric_cache_service.dart';
import '../widgets/toast.dart';

/// 缓存管理 BottomSheet。
class CacheManagementSheet extends StatefulWidget {
  const CacheManagementSheet({
    super.key,
    this.cache,
    this.downloads,
    this.player,
    this.isDialog = false,
  });

  final CacheService? cache;
  final DownloadController? downloads;
  final PlayerController? player;
  final bool isDialog;

  @override
  State<CacheManagementSheet> createState() => _CacheManagementSheetState();
}

class _CacheManagementSheetState extends State<CacheManagementSheet> {
  int? _dataCacheSize;
  int? _downloadSize;
  int? _playCacheSize;
  int? _imageCacheSize;
  bool _clearing = false;

  /// 「修复已下载文件」进行中（按钮置灰 + 进度条）。
  bool _repairing = false;

  /// 修复进度（已处理 / 总数），由控制器回调实时更新。
  int _repairProcessed = 0;
  int _repairTotal = 0;

  @override
  void initState() {
    super.initState();
    _loadSizes();
  }

  Future<void> _loadSizes() async {
    // 四路大小统计彼此独立，并行计算缩短"计算中…"窗口
    // （下载/播放缓存目录树遍历已在服务层移出主 isolate）。
    final results = await Future.wait<Map<String, int?>>([
      () async {
        if (widget.cache == null) return {'data': null};
        try {
          // 数据缓存 = prefs 里的 JSON 缓存 + 歌词文件缓存（后者已迁出
          // prefs，见 LyricCacheService）：两处都算"数据缓存"口径。
          final prefsBytes = await widget.cache!.getCacheSize();
          final lyricBytes = await LyricCacheService.instance.totalBytes();
          return {'data': prefsBytes + lyricBytes};
        } catch (_) {
          return {'data': null};
        }
      }(),
      () async {
        if (widget.downloads == null) return {'download': null};
        try {
          return {'download': await widget.downloads!.getDownloadDirSize()};
        } catch (_) {
          return {'download': null};
        }
      }(),
      () async {
        if (widget.downloads == null) return {'playCache': null};
        try {
          return {'playCache': await widget.downloads!.getPlayCacheDirSize()};
        } catch (_) {
          return {'playCache': null};
        }
      }(),
      () async {
        if (!ImageDiskCache.instance.enabled) return {'image': null};
        try {
          return {'image': await ImageDiskCache.instance.totalSize()};
        } catch (_) {
          return {'image': null};
        }
      }(),
    ]);
    if (mounted) {
      setState(() {
        _dataCacheSize = results[0]['data'];
        _downloadSize = results[1]['download'];
        _playCacheSize = results[2]['playCache'];
        _imageCacheSize = results[3]['image'];
      });
    }
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '计算中…';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatLimit(int? bytes) {
    if (bytes == null) return '300 MB';
    if (bytes < 0) return '无限制';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).round()} GB';
  }

  Future<void> _selectCacheLimit(BuildContext context) async {
    // 已有清理/修改操作进行中时忽略重复点击，避免并发操作。
    if (_clearing) return;
    final downloads = widget.downloads;
    if (downloads == null) return;

    final currentLimit = downloads.playCacheLimit;
    final options = [
      (label: '100 MB', value: 100 * 1024 * 1024),
      (label: '300 MB', value: 300 * 1024 * 1024),
      (label: '500 MB', value: 500 * 1024 * 1024),
      (label: '1 GB', value: 1024 * 1024 * 1024),
      (label: '2 GB', value: 2 * 1024 * 1024 * 1024),
      (label: '5 GB', value: 5 * 1024 * 1024 * 1024),
      (label: '无限制', value: -1),
    ];

    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('设置播放缓存上限'),
          content: SingleChildScrollView(
            child: RadioGroup<int>(
              groupValue: currentLimit,
              onChanged: (val) {
                Navigator.of(dialogContext).pop(val);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: options.map((opt) {
                  return RadioListTile<int>(
                    title: Text(opt.label),
                    value: opt.value,
                  );
                }).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );

    if (selected != null && mounted) {
      setState(() => _clearing = true);
      try {
        await downloads.setPlayCacheLimit(selected);
        await _loadSizes();
        Toast.success('已修改缓存上限');
      } catch (_) {
        Toast.error('修改失败');
      }
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  /// 「修复已下载文件」入口（旧库迁移/补扫）。
  ///
  /// 只做手动入口，不做首启静默迁移：整文件重写很吃 IO，用户能自己决定
  /// 什么时候跑，失败了还能重试。进度与结果都在本卡片上呈现。
  Widget _buildRepairTile(BuildContext context) {
    final downloads = widget.downloads;
    if (downloads == null) return const SizedBox.shrink();
    // 监听下载表：弹层打开期间下载完成/删除会改变条目数，按钮可用性跟着刷新。
    return AnimatedBuilder(
      animation: downloads,
      builder: (context, _) => _repairTileCard(context, downloads),
    );
  }

  Widget _repairTileCard(BuildContext context, DownloadController downloads) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final total = _repairTotal;
    final processed = _repairProcessed > total ? total : _repairProcessed;
    // 弹层被关掉又重开时本 State 是新的（进度计数丢了），但控制器可能还在
    // 跑：此时必须继续显示「修复中」并置灰按钮，否则用户会以为没在跑。
    final repairing = _repairing || downloads.isRepairing;
    // 没有已下载条目时按钮无意义（列表为空说明一首都没下过）。
    final hasDownloads = downloads.downloadEntries.any(
      (e) => e.status == DownloadStatus.downloaded,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: .10)
              : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: isDark ? .22 : .10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.build_circle_outlined,
              size: 20,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '修复已下载文件',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  repairing
                      ? (_repairing ? '正在修复 $processed/$total 首…' : '正在修复…')
                      : '为升级前下载的歌补写标签、按真实音频格式纠正扩展名',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                if (repairing) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      // 进度未知（刚重开弹层）或总数为 0 时给不确定态，
                      // 避免除零与假进度。
                      value: _repairing && total > 0 ? processed / total : null,
                      minHeight: 4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: repairing || _clearing || !hasDownloads
                ? null
                : _repairDownloads,
            child: Text(
              repairing ? '修复中' : '修复',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _repairDownloads() async {
    final downloads = widget.downloads;
    if (downloads == null || _repairing) return;
    setState(() {
      _repairing = true;
      _repairProcessed = 0;
      _repairTotal = downloads.downloadEntries
          .where((e) => e.status == DownloadStatus.downloaded)
          .length;
    });
    try {
      final result = await downloads.repairDownloadedFiles(
        onProgress: (processed, total) {
          if (!mounted) return;
          setState(() {
            _repairProcessed = processed;
            _repairTotal = total;
          });
        },
      );
      if (!mounted) return;
      if (result.total == 0) {
        Toast.show('还没有已下载的歌曲可以修复');
      } else {
        final parts = <String>[
          '${result.repaired} 首已更新标签',
          if (result.renamed > 0) '${result.renamed} 个扩展名已纠正',
          if (result.skipped > 0) '${result.skipped} 首跳过',
          if (result.failed > 0) '${result.failed} 首失败',
        ];
        // 失败多半是文件被占用/空间不足，提示用户可再次点修复重试。
        if (result.failed > 0) {
          Toast.error('修复完成：${parts.join('，')}');
        } else {
          Toast.success('修复完成：${parts.join('，')}');
        }
      }
      // 改名与写标签都会改变占用大小，顺手刷新统计。
      await _loadSizes();
    } catch (_) {
      if (mounted) Toast.error('修复失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final header = widget.isDialog
        ? Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '缓存管理',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          )
        : Text(
            '缓存管理',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: 16),
        CacheItem(
          icon: Icons.storage_rounded,
          title: '数据缓存',
          size: _formatSize(_dataCacheSize),
          onClear:
              widget.cache != null &&
                  _dataCacheSize != null &&
                  _dataCacheSize! > 0
              ? () async {
                  // 清理进行中忽略重复点击，避免并发清理。
                  if (_clearing) return;
                  setState(() => _clearing = true);
                  try {
                    await widget.cache!.clearAllCache();
                    // 歌词缓存已迁到独立文件，同样属于"数据缓存"。
                    await LyricCacheService.instance.clear();
                    await _loadSizes();
                    if (mounted) {
                      Toast.success('数据缓存已清理');
                    }
                  } catch (_) {
                    if (mounted) {
                      Toast.error('清理失败');
                    }
                  }
                  if (mounted) {
                    setState(() => _clearing = false);
                  }
                }
              : null,
        ),
        const SizedBox(height: 10),
        CacheItem(
          icon: Icons.download_rounded,
          title: '下载文件',
          size: _formatSize(_downloadSize),
          onClear: null, // 下载文件用户主动管理，不提供一键清理
        ),
        if (widget.downloads != null) ...[
          const SizedBox(height: 10),
          // 下载存储目录信息块：只展示路径 + 复制；「更改目录 / 恢复默认」
          // 不搬上游入口（fork 桌面设置已有等价项，避免双入口）。
          DownloadDirInfo(downloads: widget.downloads!),
          const SizedBox(height: 10),
          // 「同时保存 LRC 歌词」已移到设置页「存储与下载」分节：下载选项
          // 放缓存清理弹层里既不合语义，PC 用户也找不到（issue #29）。
          // 旧下载修复（升级前的文件不走新下载的收尾链路：扩展名可能撒谎、
          // 没有内嵌标签）。做成手动入口而不是首启静默迁移：整文件重写很
          // 吃 IO，出问题用户能重试，也能自己决定什么时候跑。
          _buildRepairTile(context),
        ],
        const SizedBox(height: 10),
        CacheItem(
          icon: Icons.cached_rounded,
          title: '播放缓存',
          size: _formatSize(_playCacheSize),
          onClear:
              widget.downloads != null &&
                  _playCacheSize != null &&
                  _playCacheSize! > 0
              ? () async {
                  // 清理进行中忽略重复点击，避免并发清理。
                  if (_clearing) return;
                  setState(() => _clearing = true);
                  try {
                    await widget.downloads!.clearPlayCache();
                    await _loadSizes();
                    if (mounted) {
                      Toast.success('播放缓存已清理');
                    }
                  } catch (_) {
                    if (mounted) {
                      Toast.error('清理失败');
                    }
                  }
                  if (mounted) {
                    setState(() => _clearing = false);
                  }
                }
              : null,
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: .10)
                  : Colors.white.withValues(alpha: .92),
              width: 1.1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? .18 : .04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(
                    alpha: isDark ? .22 : .10,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.rule_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '播放缓存上限',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      _formatLimit(widget.downloads?.playCacheLimit),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => _selectCacheLimit(context),
                child: const Text(
                  '修改',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        if (_imageCacheSize != null) ...[
          const SizedBox(height: 10),
          CacheItem(
            icon: Icons.image_rounded,
            title: '图片缓存',
            size: _formatSize(_imageCacheSize),
            onClear: _imageCacheSize! > 0
                ? () async {
                    // 清理进行中忽略重复点击，避免并发清理。
                    if (_clearing) return;
                    setState(() => _clearing = true);
                    try {
                      await ImageDiskCache.instance.clear();
                      await _loadSizes();
                      if (mounted) {
                        Toast.success('图片缓存已清理');
                      }
                    } catch (_) {
                      if (mounted) {
                        Toast.error('清理失败');
                      }
                    }
                    if (mounted) {
                      setState(() => _clearing = false);
                    }
                  }
                : null,
          ),
        ],
        if (widget.player != null &&
            widget.player!.isLoudnessAnalysisSupported) ...[
          const SizedBox(height: 10),
          CacheItem(
            icon: Icons.equalizer_rounded,
            title: '响度分析缓存',
            size: '${widget.player!.loudnessCacheCount} 首',
            onClear: widget.player!.loudnessCacheCount > 0
                ? () async {
                    // 清理进行中忽略重复点击，避免并发清理。
                    if (_clearing) return;
                    setState(() => _clearing = true);
                    try {
                      await widget.player!.clearLoudnessCache();
                      if (mounted) {
                        Toast.success('响度分析缓存已清理');
                      }
                    } catch (_) {
                      if (mounted) {
                        Toast.error('清理失败');
                      }
                    }
                    if (mounted) {
                      setState(() => _clearing = false);
                    }
                  }
                : null,
          ),
        ],
        const SizedBox(height: 20),
        if (_clearing) const Center(child: CircularProgressIndicator()),
      ],
    );

    if (widget.isDialog) {
      // 桌面居中 Dialog 形态：桌面窗口可缩到 360×520，新增「下载存储目录」
      // 信息块后内容可能超过可用高度。SingleChildScrollView 高约束下会
      // 收缩到内容高度、仅在超高时滚动——正常窗口视觉不变，小窗口不再
      // RenderFlex 溢出（弹层形态同样可滚动，两条路径口径一致）。
      return SingleChildScrollView(child: content);
    }

    // 底部弹窗形态：内容可达 500+ dp（四项缓存 + 上限行），横屏/小屏设备
    // 可用高度不足会 RenderFlex 溢出，改为可滚动（与 Dialog 形态同款兜底）。
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
        child: SingleChildScrollView(child: content),
      ),
    );
  }
}

/// 「下载存储目录」信息块。
///
/// 展示当前实际生效的下载目录绝对路径；用户自定义目录时加「(自定义)」
/// 标记；提供一键复制（剪贴板 + Toast）。路径解析失败静默降级为
/// 「暂不可用」，不影响弹层其余内容。
///
/// 抽成独立 StatefulWidget 便于单独单测（缓存管理弹层直接复用）；
/// [DownloadController.getDownloadDirPath] 会触发目录创建，因此只在
/// 本块挂载时解析一次，不在弹层主体里重复请求。
class DownloadDirInfo extends StatefulWidget {
  const DownloadDirInfo({super.key, required this.downloads});

  final DownloadController downloads;

  @override
  State<DownloadDirInfo> createState() => _DownloadDirInfoState();
}

class _DownloadDirInfoState extends State<DownloadDirInfo> {
  String? _path;
  String? _customDir;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? path;
    var failed = false;
    try {
      path = await widget.downloads.getDownloadDirPath();
    } catch (_) {
      // 目录不可用（卷未挂载、权限不足、path_provider 失败等）：静默占位。
      failed = true;
    }
    // 自定义目录配置单独读取：目录解析失败时也要保留，才能标注「未生效」。
    String? custom;
    try {
      custom = await widget.downloads.getCustomDownloadDir();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _path = path;
      _customDir = custom;
      _failed = failed;
    });
  }

  /// 自定义目录是否就是当前实际生效目录（空串/空白视为跟随默认）。
  ///
  /// 配置了自定义目录但当前没生效（Android「所有文件访问」被回收、外置
  /// 盘离线等）时不能标注「(自定义)」误导用户，单独提示未生效。
  bool get _isCustom =>
      (_customDir ?? '').trim().isNotEmpty && _customDir == _path;

  /// 配置了自定义目录但当前未生效（已回退默认目录）。
  bool get _customUnavailable =>
      (_customDir ?? '').trim().isNotEmpty && _customDir != _path;

  Future<void> _copyPath() async {
    final path = _path;
    if (path == null || path.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: path));
    } catch (error) {
      // 剪贴板平台通道极少数情况下会失败（系统剪贴板服务被占用/受限），
      // 兜底提示而不是把未捕获异常抛给 Zone；失败时不再提示「已复制」。
      debugPrint('[CacheManagement] 写入剪贴板失败: $error');
      Toast.error('复制失败，请稍后重试');
      return;
    }
    Toast.success('下载目录路径已复制');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final pathText = _failed ? '暂不可用' : (_path ?? '正在获取路径…');
    final canCopy = _path != null && _path!.isNotEmpty && !_failed;
    final badgeLabel = _isCustom
        ? '(自定义)'
        : (_customUnavailable ? '(自定义未生效)' : null);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: .10)
              : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: isDark ? .22 : .10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.folder_outlined,
              size: 20,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '下载存储目录',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (badgeLabel != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          badgeLabel,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                // 路径可长按选中（复制按钮兜底给不熟悉长按的用户）。
                SelectableText(
                  pathText,
                  maxLines: 2,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (canCopy)
            IconButton(
              tooltip: '复制路径',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .7),
              onPressed: _copyPath,
              icon: const Icon(Icons.copy_rounded),
            ),
        ],
      ),
    );
  }
}

/// 缓存管理中的单项条目。
class CacheItem extends StatelessWidget {
  const CacheItem({
    super.key,
    required this.icon,
    required this.title,
    required this.size,
    this.onClear,
  });

  final IconData icon;
  final String title;
  final String size;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: .10)
              : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: isDark ? .22 : .10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: colorScheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                Text(
                  size,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (onClear != null)
            TextButton(
              onPressed: onClear,
              child: Text(
                '清理',
                style: TextStyle(
                  color: colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
