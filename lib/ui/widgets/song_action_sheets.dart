import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import 'artwork.dart';
import 'toast.dart';

class SongSheetAction {
  const SongSheetAction({
    required this.icon,
    required this.title,
    this.subtitle,
    this.danger = false,
    this.isGrid = false,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool danger;
  final bool isGrid;
  final FutureOr<void> Function() onTap;
}

Future<void> showSongActionSheet({
  required BuildContext context,
  required Song song,
  required List<SongSheetAction> actions,
}) {
  if (isDesktopFormFactor) {
    return _showDesktopSongActionMenu(
      context: context,
      song: song,
      actions: actions,
    );
  }

  final isLandscape = MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
  // 左侧滑入弹窗是车机专属交互，普通横屏用标准底部弹窗。
  final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

  if (isCarMode) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(left: 24, top: 24, bottom: 24),
            width: 320,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 15,
                  offset: const Offset(5, 5),
                ),
              ],
            ),
            child: _buildCarActionDialogContent(context, song, actions),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-1.0, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
    );
  }

  final gridActions = actions.where((a) => a.isGrid).toList();
  final listActions = actions.where((a) => !a.isGrid).toList();

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) {
      final colorScheme = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Song info
                Row(
                  children: [
                    Artwork(url: song.coverUrl, size: 52, borderRadius: 10),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(sheetContext).textTheme.bodyMedium
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // Actions card (grid + list in one unified card)
                if (gridActions.isNotEmpty || listActions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Material(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Grid actions (icon + text, 3-column grid)
                        if (gridActions.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 12,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (var row = 0;
                                    row * 3 < gridActions.length;
                                    row++)
                                  Row(
                                    children: [
                                      for (var col = 0; col < 3; col++)
                                        Expanded(
                                          child: row * 3 + col < gridActions.length
                                              ? _GridItem(
                                                  action: gridActions[row * 3 + col],
                                                )
                                              : const SizedBox.shrink(),
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        // Divider between grid and list
                        if (gridActions.isNotEmpty && listActions.isNotEmpty)
                          const Divider(height: 1, indent: 16, endIndent: 16),
                        // List actions
                        for (var index = 0;
                            index < listActions.length;
                            index++) ...[
                          _SongActionTile(action: listActions[index]),
                          if (index != listActions.length - 1)
                            const Divider(height: 1, indent: 58),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _GridItem extends StatelessWidget {
  const _GridItem({required this.action});

  final SongSheetAction action;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = action.danger ? colorScheme.error : colorScheme.onSurface;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Navigator.of(context).pop();
        Future<void>.delayed(
          const Duration(milliseconds: 120),
          () => action.onTap(),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(action.icon, color: color, size: 21),
          ),
          const SizedBox(height: 5),
          Text(
            action.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            if (action.subtitle != null)
              Text(
                action.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
          ],
        ),
    );
  }
}

Future<bool> showAddToPlaylistSheet({
  required BuildContext context,
  required AuthController auth,
  required Song song,
}) {
  return showAddSongsToPlaylistSheet(
    context: context,
    auth: auth,
    songs: [song],
  );
}

/// 返回是否添加成功。
Future<bool> showAddSongsToPlaylistSheet({
  required BuildContext context,
  required AuthController auth,
  required List<Song> songs,
}) async {
  if (songs.isEmpty) return false;
  final playlists = auth.createdPlaylists
      .where((playlist) => playlist.listId?.isNotEmpty == true)
      .toList();
  final picked = await showModalBottomSheet<PlaylistSummary>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) {
      final colorScheme = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                songs.length == 1
                    ? '添加到歌单'
                    : '添加 ${songs.length} 首到歌单',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              if (playlists.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '还没有可添加的歌单',
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                )
              else
                Flexible(
                  child: Material(
                    color: Colors.transparent,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: playlists.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        return ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          leading: Artwork(
                            url: playlist.coverUrl,
                            size: 46,
                            borderRadius: 9,
                          ),
                          title: Text(
                            playlist.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${playlist.songCount ?? 0} 首歌'),
                          onTap: () => Navigator.of(context).pop(playlist),
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  if (picked == null || !context.mounted) return false;

  try {
    await auth.addSongsToPlaylist(picked, songs);
    if (auth.errorMessage != null) {
      throw Exception(auth.errorMessage);
    }
    Toast.success(
      songs.length == 1
          ? '已添加到 ${picked.title}'
          : '已添加 ${songs.length} 首到 ${picked.title}',
    );
    return true;
  } catch (error) {
    Toast.error('添加失败：$error');
    return false;
  }
}

Future<void> addSongToQueueWithFeedback({
  required BuildContext context,
  required PlayerController player,
  required Song song,
}) async {
  try {
    final added = await player.addToQueue(song);
    Toast.show(added ? '已设为下一首播放' : '当前歌曲已在播放中');
  } catch (error) {
    Toast.error('添加失败：$error');
  }
}

class _SongActionTile extends StatelessWidget {
  const _SongActionTile({required this.action});

  final SongSheetAction action;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = action.danger ? colorScheme.error : colorScheme.onSurface;
    return ListTile(
      leading: Icon(action.icon, color: color),
      title: Text(action.title, style: TextStyle(color: color)),
      subtitle: action.subtitle == null ? null : Text(action.subtitle!),
      onTap: () {
        Navigator.of(context).pop();
        Future<void>.delayed(
          const Duration(milliseconds: 120),
          () => action.onTap(),
        );
      },
    );
  }
}

Widget _buildCarActionDialogContent(
  BuildContext context,
  Song song,
  List<SongSheetAction> actions,
) {
  final colorScheme = Theme.of(context).colorScheme;
  return Material(
    color: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
                style: IconButton.styleFrom(
                  backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Flexible(
            child: GridView.builder(
              shrinkWrap: true,
              itemCount: actions.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.35,
              ),
              itemBuilder: (context, index) {
                final action = actions[index];
                return _CarGridActionItem(action: action);
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class _CarGridActionItem extends StatelessWidget {
  const _CarGridActionItem({required this.action});

  final SongSheetAction action;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = action.danger ? colorScheme.error : colorScheme.onSurface;

    return Material(
      color: colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          Future<void>.delayed(
            const Duration(milliseconds: 120),
            () => action.onTap(),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(action.icon, color: color, size: 22),
              const SizedBox(height: 6),
              Text(
                action.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              if (action.subtitle != null)
                Text(
                  action.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 9,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showDesktopSongActionMenu({
  required BuildContext context,
  required Song song,
  required List<SongSheetAction> actions,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    builder: (dialogContext) {
      return _DesktopSongActionMenuDialog(
        song: song,
        actions: actions,
      );
    },
  );
}

class _DesktopSongActionMenuDialog extends StatelessWidget {
  const _DesktopSongActionMenuDialog({
    required this.song,
    required this.actions,
  });

  final Song song;
  final List<SongSheetAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isDark
        ? const Color(0xFF1E212B)
        : colorScheme.surface;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : colorScheme.outlineVariant.withValues(alpha: 0.8);
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : colorScheme.outlineVariant.withValues(alpha: 0.6);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Center(
        child: Container(
          width: 236,
          constraints: const BoxConstraints(maxHeight: 460),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 顶部紧凑歌曲信息
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                  child: Row(
                    children: [
                      Artwork(url: song.coverUrl, size: 32, borderRadius: 6),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 11,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                        iconSize: 16,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                        splashRadius: 14,
                        tooltip: '关闭',
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: dividerColor,
                ),
                // 菜单项垂直排列
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final action in actions)
                          _DesktopSongActionItem(action: action),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopSongActionItem extends StatefulWidget {
  const _DesktopSongActionItem({required this.action});

  final SongSheetAction action;

  @override
  State<_DesktopSongActionItem> createState() => _DesktopSongActionItemState();
}

class _DesktopSongActionItemState extends State<_DesktopSongActionItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hoverColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : colorScheme.surfaceContainerHigh;
    final color = widget.action.danger ? colorScheme.error : colorScheme.onSurface;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Semantics(
        button: true,
        label: widget.action.title,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Navigator.of(context).pop();
            Future<void>.delayed(
              const Duration(milliseconds: 100),
              () => widget.action.onTap(),
            );
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 38,
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: _hovering ? hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  widget.action.icon,
                  size: 18,
                  color: color,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.action.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
                if (widget.action.subtitle != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    widget.action.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
