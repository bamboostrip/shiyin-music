import 'package:flutter/material.dart';

import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/cache_service.dart';
import '../../services/image_disk_cache.dart';
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
          return {'data': await widget.cache!.getCacheSize()};
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
      return content;
    }

    // 底部弹窗形态：内容可达 500+ dp（四项缓存 + 上限行），横屏/小屏设备
    // 可用高度不足会 RenderFlex 溢出，改为可滚动（对话框形态高度不受限，
    // 维持原布局）。
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
        child: SingleChildScrollView(child: content),
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
