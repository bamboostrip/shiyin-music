import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../core/pinyin_utils.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/toast.dart';
import 'cloud_drive_page.dart';
import 'downloaded_songs_page.dart';
import 'playback_history_page.dart';
import 'playlist_detail_page.dart';
import 'settings_page.dart';
import 'local_songs_page.dart';
import '../../controllers/local_music_controller.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
    required this.theme,
    required this.localMusic,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _openPlaylist(PlaylistSummary playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: playlist,
        ),
      ),
    );
  }

  bool _isLandscape(BuildContext ctx) {
    final size = MediaQuery.sizeOf(ctx);
    return size.width > size.height;
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          theme: widget.theme,
          downloads: widget.downloads,
          cache: widget.player.cacheService,
          localMusic: widget.localMusic,
        ),
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => _CreatePlaylistSheet(),
    );
    if (name == null) return;

    await widget.auth.createPlaylist(name);
    if (!mounted) return;
    if (widget.auth.errorMessage != null) {
      Toast.error('创建失败：${widget.auth.errorMessage}');
    } else {
      Toast.success('歌单已创建');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        // 顶部渐变背景（仅顶部区域，淡淡过渡到透明）
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 280,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? const [
                        Color(0xFF10233A),
                        Color(0xFF0B1828),
                        Color(0x0006070A),
                      ]
                    : const [
                        Color(0xFFEAF3FF),
                        Color(0xFFF2F7FD),
                        Color(0x00FFFFFF),
                      ],
                stops: const [0, .6, 1],
              ),
            ),
          ),
        ),
        // 内容层
        SafeArea(
          bottom: false,
          child: AnimatedBuilder(
            animation: widget.auth,
            builder: (context, _) {
              final created = widget.auth.createdPlaylists;
              final collected = widget.auth.collectedPlaylists;
              final albums = widget.auth.collectedAlbums;

              return CustomScrollView(
                slivers: [
                  // Header
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 12, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '我的',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 22,
                                  ),
                            ),
                          ),
                          IconButton(
                            tooltip: '创建歌单',
                            onPressed: _showCreatePlaylistDialog,
                            icon: const Icon(Icons.add_rounded),
                          ),
                          // 车机模式顶栏已有设置按钮，隐藏此处重复按钮
                          if (!(_isLandscape(context) && widget.theme.carModeEnabled))
                            IconButton(
                              tooltip: '设置',
                              onPressed: _openSettings,
                              icon: const Icon(Icons.settings_rounded),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // Account info
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                      child: _AccountRow(auth: widget.auth),
                    ),
                  ),
                  // Quick action cards (horizontal scrollable)
                  SliverToBoxAdapter(
                    child: _QuickActionRow(
                      auth: widget.auth,
                      downloads: widget.downloads,
                      player: widget.player,
                      localMusic: widget.localMusic,
                      api: widget.api,
                      onOpenLiked: widget.auth.likedPlaylist == null
                          ? null
                          : () => _openPlaylist(widget.auth.likedPlaylist!),
                      onOpenDownloads: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DownloadedSongsPage(
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            downloads: widget.downloads,
                          ),
                        ),
                      ),
                      onOpenCloudDrive: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CloudDrivePage(
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Tab 标签栏：创建 / 收藏 / 专辑
                  SliverToBoxAdapter(
                    child: _PlaylistTabBar(
                      controller: _tabController,
                      createdCount: created.length,
                      collectedCount: collected.length,
                      albumCount: albums.length,
                    ),
                  ),
                  // 当前 Tab 对应的歌单列表
                  SliverToBoxAdapter(
                    child: _PlaylistTabView(
                      controller: _tabController,
                      created: created,
                      collected: collected,
                      albums: albums,
                      auth: widget.auth,
                      onOpen: _openPlaylist,
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 160)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// --- Account row (no card background) ---

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final profile = auth.profile;
    final vipInfo = auth.vipInfo;
    final vipText = vipInfo?.expiryDisplay;
    final isVip = vipInfo?.hasVip ?? false;

    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          child: profile?.avatarUrl == null
              ? Icon(Icons.person_rounded, color: colorScheme.primary)
              : Image.network(profile!.avatarUrl!, fit: BoxFit.cover, cacheWidth: 100, cacheHeight: 100),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      profile?.nickname ?? '${AppConfig.appName}用户',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (isVip) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFFD54F), Color(0xFFFFB300)],
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'VIP',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF5D4037),
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                vipText ?? '已登录',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// --- Quick action row (horizontal scrollable cards) ---

class _QuickActionRow extends StatelessWidget {
  const _QuickActionRow({
    required this.auth,
    required this.downloads,
    required this.player,
    required this.localMusic,
    required this.api,
    required this.onOpenLiked,
    required this.onOpenDownloads,
    required this.onOpenCloudDrive,
  });

  final AuthController auth;
  final DownloadController downloads;
  final PlayerController player;
  final LocalMusicController localMusic;
  final MusicApi api;
  final VoidCallback? onOpenLiked;
  final VoidCallback onOpenDownloads;
  final VoidCallback onOpenCloudDrive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 0, 0),
      child: SizedBox(
        height: 120,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(right: 18),
          children: [
            _QuickActionCard(
              icon: Icons.favorite_rounded,
              iconColor: const Color.fromARGB(176, 255, 99, 151),
              subtitle: '${auth.likedCount} 首歌曲',
              title: '我喜欢',
              onTap: onOpenLiked,
            ),
            const SizedBox(width: 10),
            _QuickActionCard(
              icon: Icons.cloud_rounded,
              iconColor: const Color.fromARGB(200, 88, 156, 245),
              subtitle: '云盘音乐',
              title: '云盘',
              onTap: onOpenCloudDrive,
            ),
            const SizedBox(width: 10),
            AnimatedBuilder(
              animation: downloads,
              builder: (context, _) {
                return _QuickActionCard(
                  icon: Icons.download_rounded,
                  iconColor: Theme.of(context).colorScheme.primary,
                  subtitle: '${downloads.downloadedSongs.length} 首歌曲',
                  title: '已下载',
                  onTap: onOpenDownloads,
                );
              },
            ),
            const SizedBox(width: 10),
            AnimatedBuilder(
              animation: localMusic,
              builder: (context, _) {
                return _QuickActionCard(
                  icon: Icons.computer_rounded,
                  iconColor: const Color.fromARGB(200, 76, 175, 80),
                  subtitle: '${localMusic.songs.length} 首歌曲',
                  title: '本地',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LocalSongsPage(
                        player: player,
                        localMusic: localMusic,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(width: 10),
            _QuickActionCard(
              icon: Icons.history_rounded,
              iconColor: const Color.fromARGB(200, 255, 167, 38),
              subtitle: '最近播放',
              title: '历史',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlaybackHistoryPage(
                    api: api,
                    auth: auth,
                    player: player,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
    required this.icon,
    required this.iconColor,
    required this.subtitle,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String subtitle;
  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: 93,
      margin: const EdgeInsets.only(right: 0),
      child: Material(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: iconColor,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- Tab 标签栏 ---

class _PlaylistTabBar extends StatelessWidget {
  const _PlaylistTabBar({
    required this.controller,
    required this.createdCount,
    required this.collectedCount,
    required this.albumCount,
  });

  final TabController controller;
  final int createdCount;
  final int collectedCount;
  final int albumCount;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 0),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            return Row(
              children: [
                Expanded(
                  child: _TabItem(
                    label: '创建',
                    count: createdCount,
                    selected: controller.index == 0,
                    onTap: () => controller.animateTo(0),
                  ),
                ),
                Expanded(
                  child: _TabItem(
                    label: '收藏',
                    count: collectedCount,
                    selected: controller.index == 1,
                    onTap: () => controller.animateTo(1),
                  ),
                ),
                Expanded(
                  child: _TabItem(
                    label: '专辑',
                    count: albumCount,
                    selected: controller.index == 2,
                    onTap: () => controller.animateTo(2),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: label),
              if (count > 0) ...[
                const TextSpan(text: ' '),
                TextSpan(
                  text: '$count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? colorScheme.onPrimary.withValues(alpha: .78)
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: selected ? colorScheme.onPrimary : colorScheme.onSurface,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// --- Tab 内容视图 ---

/// 歌单排序模式。
enum _PlaylistSortMode { defaultOrder, byName, bySongCount, byCreatedTime }

class _PlaylistTabView extends StatefulWidget {
  const _PlaylistTabView({
    required this.controller,
    required this.created,
    required this.collected,
    required this.albums,
    required this.auth,
    required this.onOpen,
  });

  final TabController controller;
  final List<PlaylistSummary> created;
  final List<PlaylistSummary> collected;
  final List<PlaylistSummary> albums;
  final AuthController auth;
  final void Function(PlaylistSummary) onOpen;

  @override
  State<_PlaylistTabView> createState() => _PlaylistTabViewState();
}

class _PlaylistTabViewState extends State<_PlaylistTabView> {
  _PlaylistSortMode _sortMode = _PlaylistSortMode.defaultOrder;

  /// 多选模式状态：选中的歌单。
  final Set<int> _selectedIndices = {};
  bool _multiSelectMode = false;

  List<PlaylistSummary> get _currentList {
    final lists = [widget.created, widget.collected, widget.albums];
    return lists[widget.controller.index.clamp(0, 2)];
  }

  /// 按当前排序模式返回新列表（不修改原列表）。
  List<PlaylistSummary> _sortedPlaylists(List<PlaylistSummary> playlists) {
    switch (_sortMode) {
      case _PlaylistSortMode.byName:
        final sorted = List<PlaylistSummary>.of(playlists);
        sorted.sort((a, b) => PinyinUtils.comparePinyin(a.title, b.title));
        return sorted;
      case _PlaylistSortMode.bySongCount:
        final sorted = List<PlaylistSummary>.of(playlists);
        sorted.sort((a, b) => (b.songCount ?? 0).compareTo(a.songCount ?? 0));
        return sorted;
      case _PlaylistSortMode.byCreatedTime:
      case _PlaylistSortMode.defaultOrder:
        return playlists;
    }
  }

  String get _sortModeLabel {
    return switch (_sortMode) {
      _PlaylistSortMode.defaultOrder => '默认排序',
      _PlaylistSortMode.byName => '按名称',
      _PlaylistSortMode.bySongCount => '按歌曲数',
      _PlaylistSortMode.byCreatedTime => '按创建时间',
    };
  }

  Future<void> _showSortSheet(BuildContext context) async {
    final selected = await showModalBottomSheet<_PlaylistSortMode>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final options = [
          (_PlaylistSortMode.defaultOrder, '默认排序'),
          (_PlaylistSortMode.byName, '按名称'),
          (_PlaylistSortMode.bySongCount, '按歌曲数'),
          (_PlaylistSortMode.byCreatedTime, '按创建时间'),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '排序方式',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 12),
                Material(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        _SortOptionTile(
                          label: options[i].$2,
                          selected: _sortMode == options[i].$1,
                          onTap: () =>
                              Navigator.of(sheetContext).pop(options[i].$1),
                        ),
                        if (i < options.length - 1)
                          Divider(
                            height: 1,
                            indent: 16,
                            color: colorScheme.outlineVariant
                                .withValues(alpha: .3),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null && selected != _sortMode) {
      setState(() => _sortMode = selected);
    }
  }

  void _enterMultiSelect(int index) {
    setState(() {
      _multiSelectMode = true;
      _selectedIndices
        ..clear()
        ..add(index);
    });
  }

  void _toggleSelected(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
        if (_selectedIndices.isEmpty) {
          _multiSelectMode = false;
        }
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelectMode = false;
      _selectedIndices.clear();
    });
  }

  Future<void> _deleteSelected() async {
    final playlists = _currentList;
    final targets = _selectedIndices
        .where((i) => i >= 0 && i < playlists.length)
        .map((i) => playlists[i])
        .toList();
    if (targets.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定要删除选中的 ${targets.length} 个歌单吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    var ok = 0;
    String? lastError;
    for (final playlist in targets) {
      if (playlist.isSystemDefaultCollect || playlist.isLikedPlaylist) {
        lastError = playlist.isSystemDefaultCollect
            ? '「默认收藏」为系统歌单，无法删除'
            : '「我喜欢」无法删除';
        continue;
      }
      try {
        await widget.auth.deleteOrUncollectPlaylist(playlist);
        ok++;
      } catch (e) {
        lastError = e.toString();
      }
    }
    if (!mounted) return;
    if (ok == 0) {
      Toast.error(lastError ?? widget.auth.errorMessage ?? '删除失败');
    } else if (ok < targets.length) {
      Toast.info('已删除 $ok 个，部分失败：${lastError ?? widget.auth.errorMessage ?? ''}');
    } else {
      Toast.success('已删除 $ok 个歌单');
    }
    _exitMultiSelect();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final current = _currentList;
          final sorted = _sortedPlaylists(current);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 多选模式下的操作栏
              if (_multiSelectMode)
                _MultiSelectBar(
                  selectedCount: _selectedIndices.length,
                  onCancel: _exitMultiSelect,
                  onDelete: _deleteSelected,
                ),
              // 排序行（仅在有歌单且非多选模式时显示）
              if (current.isNotEmpty && !_multiSelectMode)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8, top: 2),
                  child: Row(
                    children: [
                      Text(
                        '共 ${current.length} 个',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _showSortSheet(context),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.sort_rounded,
                              size: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _sortModeLabel,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: sorted.isEmpty
                    ? _EmptyGroup(key: ValueKey('empty_${widget.controller.index}'))
                    : _PlaylistGroup(
                        key: ValueKey('group_${widget.controller.index}'),
                        playlists: sorted,
                        multiSelectMode: _multiSelectMode,
                        selectedIndices: _selectedIndices,
                        onOpen: widget.onOpen,
                        onLongPress: _enterMultiSelect,
                        onTapInMultiSelect: _toggleSelected,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 排序选项条目。
class _SortOptionTile extends StatelessWidget {
  const _SortOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: selected ? colorScheme.primary : null,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ),
            if (selected)
              Icon(
                Icons.check_rounded,
                size: 20,
                color: colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}

/// 多选模式操作栏。
class _MultiSelectBar extends StatelessWidget {
  const _MultiSelectBar({
    required this.selectedCount,
    required this.onCancel,
    required this.onDelete,
  });

  final int selectedCount;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '取消',
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
          Expanded(
            child: Text(
              '已选中 $selectedCount 项',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: selectedCount > 0 ? onDelete : null,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('删除'),
            style: FilledButton.styleFrom(
              foregroundColor: colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyGroup extends StatelessWidget {
  const _EmptyGroup({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 48,
              color: colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              '这里还没有内容',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Playlist group with dividers (no card background) ---

class _PlaylistGroup extends StatelessWidget {
  const _PlaylistGroup({
    super.key,
    required this.playlists,
    required this.onOpen,
    this.multiSelectMode = false,
    this.selectedIndices = const {},
    this.onLongPress,
    this.onTapInMultiSelect,
  });

  final List<PlaylistSummary> playlists;
  final void Function(PlaylistSummary) onOpen;
  final bool multiSelectMode;
  final Set<int> selectedIndices;
  final void Function(int index)? onLongPress;
  final void Function(int index)? onTapInMultiSelect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final isWide = size.width >= 720;
    final isUltraWide = size.width >= 1200;

    if (isWide) {
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: isUltraWide ? 280 : 340,
          mainAxisExtent: 72,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: playlists.length,
        itemBuilder: (context, i) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: _PlaylistRow(
                playlist: playlists[i],
                selected: multiSelectMode && selectedIndices.contains(i),
                multiSelectMode: multiSelectMode,
                onTap: multiSelectMode
                    ? () => onTapInMultiSelect?.call(i)
                    : () => onOpen(playlists[i]),
                onLongPress: () => onLongPress?.call(i),
              ),
            ),
          );
        },
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          children: [
            for (var i = 0; i < playlists.length; i++) ...[
              _PlaylistRow(
                playlist: playlists[i],
                selected: multiSelectMode && selectedIndices.contains(i),
                multiSelectMode: multiSelectMode,
                onTap: multiSelectMode
                    ? () => onTapInMultiSelect?.call(i)
                    : () => onOpen(playlists[i]),
                onLongPress: () => onLongPress?.call(i),
              ),
              if (i < playlists.length - 1)
                Divider(
                  height: 1,
                  indent: 62,
                  color: colorScheme.outlineVariant.withValues(alpha: .3),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// --- Playlist row ---

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.multiSelectMode = false,
  });

  final PlaylistSummary playlist;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool multiSelectMode;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            // 多选模式下显示勾选标记，否则显示封面
            if (multiSelectMode)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: selected
                      ? Icon(
                          Icons.check_circle_rounded,
                          key: const ValueKey('checked'),
                          size: 26,
                          color: colorScheme.primary,
                        )
                      : Icon(
                          Icons.radio_button_unchecked_rounded,
                          key: const ValueKey('unchecked'),
                          size: 26,
                          color: colorScheme.outline,
                        ),
                ),
              )
            else
              Artwork(url: playlist.coverUrl, size: 44, borderRadius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    playlist.songCount == null
                        ? (playlist.subtitle ?? '歌单')
                        : '${playlist.songCount} 首歌',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (!multiSelectMode)
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colorScheme.outline,
              ),
          ],
        ),
      ),
    );
  }
}

/// 创建歌单 BottomSheet。
///
/// 作为独立 StatefulWidget，让 [TextField]、[FocusNode]、
/// [TextEditingController] 的生命周期与 BottomSheet 内容一致，
/// 由 Flutter 框架在卸载时统一清理依赖关系。
class _CreatePlaylistSheet extends StatefulWidget {
  @override
  State<_CreatePlaylistSheet> createState() => _CreatePlaylistSheetState();
}

class _CreatePlaylistSheetState extends State<_CreatePlaylistSheet> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 进入动画结束后再请求焦点，避免动画期间建立 TextInputConnection
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? value]) {
    final trimmed = (value ?? _controller.text).trim();
    Navigator.of(context).pop(trimmed.isEmpty ? null : trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '创建歌单',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            maxLength: 40,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: '请输入歌单名称',
              counterText: '',
              border: OutlineInputBorder(),
            ),
            onSubmitted: _submit,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _submit(),
                child: const Text('创建'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
