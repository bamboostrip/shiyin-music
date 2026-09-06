import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../adaptive_layout.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../widgets/toast.dart';
import '../widgets/artwork.dart';
import '../widgets/now_playing_badge.dart';

class LocalSongsPage extends StatefulWidget {
  const LocalSongsPage({
    super.key,
    required this.player,
    required this.localMusic,
  });

  final PlayerController player;
  final LocalMusicController localMusic;

  @override
  State<LocalSongsPage> createState() => _LocalSongsPageState();
}

class _LocalSongsPageState extends State<LocalSongsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.trim().toLowerCase();
    });
  }

  Future<void> _requestPermission() async {
    final granted = await widget.localMusic.requestPermission();
    if (granted) {
      Toast.success('授权成功，正在扫描本地音乐');
    } else {
      Toast.error('未授予音频访问权限');
    }
  }

  // ---- 桌面（Windows/Linux）：目录添加 / 管理 ----

  bool get _isDesktop => LocalMusicController.isDesktopScanSupported;

  /// file_picker 选择目录加入扫描根（选择器打开较慢，先给 loading 提示）。
  Future<void> _pickAndAddDesktopRoot() async {
    Toast.info('请选择音乐文件夹...');
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择音乐文件夹',
      lockParentWindow: true,
    );
    if (directory == null) return;
    await widget.localMusic.addDesktopRoot(directory);
    Toast.success('已添加目录，正在扫描本地音乐');
  }

  /// 桌面目录管理：列出扫描根，可删除/继续添加。
  void _showDesktopRootsDialog() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AnimatedBuilder(
          animation: widget.localMusic,
          builder: (context, _) {
            final colorScheme = Theme.of(dialogContext).colorScheme;
            final roots = widget.localMusic.desktopRoots;
            return AlertDialog(
              title: const Text('音乐目录'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: SizedBox(
                  width: double.maxFinite,
                  child: roots.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            '尚未添加任何目录。添加后时会递归扫描目录内的音频文件。',
                            style: Theme.of(dialogContext).textTheme.bodyMedium
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: roots.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final root = roots[index];
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                Icons.folder_rounded,
                                color: colorScheme.primary.withValues(alpha: .8),
                              ),
                              title: Text(
                                root,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              trailing: IconButton(
                                tooltip: '移除目录',
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: colorScheme.error,
                                ),
                                onPressed: widget.localMusic.isScanning
                                    ? null
                                    : () => widget.localMusic
                                        .removeDesktopRoot(root),
                              ),
                            );
                          },
                        ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
                FilledButton.icon(
                  onPressed: widget.localMusic.isScanning
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                          _pickAndAddDesktopRoot();
                        },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('添加目录'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 打开「扫描目录设置」：勾选/取消勾选文件夹以排除录音等目录。
  void _showFolderFilterSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return AnimatedBuilder(
          animation: widget.localMusic,
          builder: (context, _) {
            final folders = widget.localMusic.availableFolders;
            final excludedCount = widget.localMusic.excludedFolders.length;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '扫描目录设置',
                              style: Theme.of(sheetContext).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                          ),
                          if (excludedCount > 0)
                            TextButton(
                              onPressed: () =>
                                  widget.localMusic.clearExcludedFolders(),
                              child: const Text('恢复全部'),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                      child: Text(
                        '取消勾选的文件夹将从本地音乐中排除（例如录音文件夹），'
                        '其子目录中的音频也不会显示。',
                        style: Theme.of(sheetContext).textTheme.bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                    Flexible(
                      child: folders.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(32),
                              child: Center(
                                child: Text(
                                  '未扫描到任何音频文件夹',
                                  style: Theme.of(sheetContext)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: folders.length,
                              separatorBuilder: (_, _) => Divider(
                                height: 1,
                                indent: 56,
                                color: colorScheme.outlineVariant.withValues(
                                  alpha: .3,
                                ),
                              ),
                              itemBuilder: (context, index) {
                                final entry = folders[index];
                                final folder = entry.folder;
                                final excluded = widget.localMusic
                                    .isFolderExcluded(folder);
                                return CheckboxListTile(
                                  value: !excluded,
                                  onChanged: (checked) =>
                                      widget.localMusic.setFolderExcluded(
                                        folder,
                                        checked != true,
                                      ),
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  secondary: Icon(
                                    excluded
                                        ? Icons.folder_off_rounded
                                        : Icons.folder_rounded,
                                    color: excluded
                                        ? colorScheme.outline
                                        : colorScheme.primary.withValues(
                                            alpha: .8,
                                          ),
                                  ),
                                  title: Text(
                                    _folderDisplayName(folder),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: excluded
                                          ? colorScheme.onSurfaceVariant
                                          : colorScheme.onSurface,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '$folder · ${entry.count} 首',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(sheetContext)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                );
                              },
                            ),
                    ),
                    if (excludedCount > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
                        child: Text(
                          '已排除 $excludedCount 个文件夹',
                          style: Theme.of(sheetContext).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.primary),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('本地音乐'),
        actions: [
          AnimatedBuilder(
            animation: widget.localMusic,
            builder: (context, _) {
              if (widget.localMusic.isScanning) {
                final progress = widget.localMusic.scanProgress;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: progress.total > 0
                            ? progress.done / progress.total
                            : null,
                      ),
                    ),
                  ),
                );
              }
              if (_isDesktop) {
                return Row(
                  children: [
                    IconButton(
                      tooltip: '音乐目录',
                      onPressed: _showDesktopRootsDialog,
                      icon: const Icon(Icons.folder_open_rounded),
                    ),
                    IconButton(
                      tooltip: '扫描目录设置',
                      onPressed:
                          widget.localMusic.songs.isEmpty ? null : _showFolderFilterSheet,
                      icon: const Icon(Icons.rule_folder_rounded),
                    ),
                    IconButton(
                      tooltip: '重新扫描',
                      onPressed:
                          widget.localMusic.desktopRoots.isEmpty
                              ? null
                              : () async {
                                  await widget.localMusic.scanLocalMusic();
                                  Toast.success('扫描完成');
                                },
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                );
              }
              if (!Platform.isAndroid || !widget.localMusic.hasPermission) {
                return const SizedBox.shrink();
              }
              return Row(
                children: [
                  IconButton(
                    tooltip: '扫描目录设置',
                    onPressed: _showFolderFilterSheet,
                    icon: const Icon(Icons.rule_folder_rounded),
                  ),
                  IconButton(
                    tooltip: '重新扫描',
                    onPressed: () async {
                      await widget.localMusic.scanLocalMusic();
                      Toast.success('扫描完成');
                    },
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: AdaptiveContentPadding(
        child: AnimatedBuilder(
          animation: Listenable.merge([widget.localMusic, widget.player]),
          builder: (context, _) {
            // 桌面（Windows/Linux）：无目录时引导添加；有目录走通用列表。
            if (_isDesktop) {
              if (widget.localMusic.desktopRoots.isEmpty) {
                return _buildEmptyState(
                  context,
                  colorScheme,
                  icon: Icons.library_music_rounded,
                  title: '添加本地音乐目录',
                  subtitle: '选择存放音乐文件的文件夹，会递归扫描其中的音频并读取标签信息',
                  action: FilledButton.icon(
                    onPressed: _pickAndAddDesktopRoot,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('添加音乐目录'),
                  ),
                );
              }
            } else if (!Platform.isAndroid) {
              // macOS：Rust 引擎未接入（见 form_factor.dart 的 macOS 适配清单）。
              return _buildEmptyState(
                context,
                colorScheme,
                icon: Icons.phone_android_rounded,
                title: '暂不支持当前平台',
                subtitle: '本地音乐功能支持 Android / Windows / Linux',
              );
            }

            // Android 未授权状态（桌面跳过）
            if (!_isDesktop && !widget.localMusic.hasPermission) {
              return _buildEmptyState(
                context,
                colorScheme,
                icon: Icons.lock_outline_rounded,
                title: '需要音频访问权限',
                subtitle: '授予音频访问权限后，即可扫描并播放设备上的本地音乐',
                action: FilledButton.icon(
                  onPressed: _requestPermission,
                  icon: const Icon(Icons.security_rounded),
                  label: const Text('授予权限'),
                ),
              );
            }

            final allSongs = widget.localMusic.songs;
            final filteredSongs = allSongs.where((song) {
              final titleMatch = song.title.toLowerCase().contains(
                _searchQuery,
              );
              final artistMatch = song.artist.toLowerCase().contains(
                _searchQuery,
              );
              return titleMatch || artistMatch;
            }).toList();

            return Column(
              children: [
                // 歌曲数显示
                if (allSongs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.music_note_rounded,
                            color: colorScheme.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '已扫描到本地音乐',
                              style: TextStyle(
                                fontSize: 13,
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Text(
                            '共 ${allSongs.length} 首',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // 搜索栏
                if (allSongs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: '检索本地音乐...',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                onPressed: () => _searchController.clear(),
                                icon: const Icon(Icons.clear_rounded),
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                // 歌曲列表
                Expanded(
                  child: widget.localMusic.isScanning
                      ? const Center(child: CircularProgressIndicator())
                      : filteredSongs.isEmpty
                      ? _buildEmptyState(
                          context,
                          colorScheme,
                          icon: Icons.library_music_rounded,
                          title: allSongs.isEmpty ? '未找到本地音乐' : '没有检索到匹配的歌曲',
                          subtitle: allSongs.isEmpty
                              ? (_isDesktop ? '所选目录中没有音频文件，可添加或更换目录' : '设备上没有可播放的音频文件')
                              : '尝试其他关键词搜索',
                          action: allSongs.isEmpty && _isDesktop
                              ? TextButton.icon(
                                  onPressed: _showDesktopRootsDialog,
                                  icon: const Icon(Icons.folder_open_rounded),
                                  label: const Text('管理音乐目录'),
                                )
                              : null,
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 120),
                          itemCount: filteredSongs.length,
                          itemBuilder: (context, index) {
                            final song = filteredSongs[index];
                            final isCurrent =
                                widget.player.currentSong?.hash == song.hash;
                            final isPlaying =
                                isCurrent && widget.player.isPlaying;

                            return ListTile(
                              leading: SizedBox(
                                width: 44,
                                height: 44,
                                child: Stack(
                                  children: [
                                    Artwork(url: song.coverUrl, size: 44),
                                    if (isCurrent)
                                      Container(
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.4,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Center(
                                          child: NowPlayingBadge(
                                            active: true,
                                            playing: isPlaying,
                                            color: Colors.white,
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isCurrent
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isCurrent
                                      ? colorScheme.primary
                                      : colorScheme.onSurface,
                                ),
                              ),
                              subtitle: Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isCurrent
                                      ? colorScheme.primary.withValues(
                                          alpha: .7,
                                        )
                                      : colorScheme.onSurfaceVariant,
                                ),
                              ),
                              onTap: () {
                                widget.player.playSong(
                                  song,
                                  queue: filteredSongs,
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    ColorScheme colorScheme, {
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 72,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action],
          ],
        ),
      ),
    );
  }
}

/// 取文件夹显示名：优先末级目录名，顶层存储目录（末级为 `0`）显示完整路径。
String _folderDisplayName(String folder) {
  final separator = folder.contains('\\') ? '\\' : '/';
  final segments = folder.split(separator).where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return folder;
  final last = segments.last;
  if (last == '0' || last == 'storage') return folder;
  return last;
}
