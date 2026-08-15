import 'package:flutter/material.dart';
import '../design_tokens.dart';

import '../../controllers/auth_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import 'toast.dart';

/// 弹出「歌单分享链接导入」面板。
Future<void> showImportPlaylistSheet({
  required BuildContext context,
  required MusicApi api,
  required AuthController auth,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => ImportPlaylistSheet(api: api, auth: auth),
  );
}

class ImportPlaylistSheet extends StatefulWidget {
  const ImportPlaylistSheet({super.key, required this.api, required this.auth});

  final MusicApi api;
  final AuthController auth;

  @override
  State<ImportPlaylistSheet> createState() => _ImportPlaylistSheetState();
}

enum _ImportStep { input, parsing, parsed, importing }

class _ImportPlaylistSheetState extends State<ImportPlaylistSheet> {
  final _controller = TextEditingController();

  _ImportStep _step = _ImportStep.input;
  ExternalPlaylistParseResult? _result;
  String? _error;
  String? _selectedListId;
  var _matched = 0;
  var _done = 0;
  var _total = 0;

  /// 可导入的目标歌单（仅用户自建歌单）。
  List<PlaylistSummary> get _targetPlaylists => widget.auth.playlists
      .where((p) => p.isCreatedPlaylist && p.listId?.isNotEmpty == true)
      .toList();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      Toast.info('请先粘贴网易云/QQ 音乐的歌单分享链接或文本');
      return;
    }
    setState(() {
      _step = _ImportStep.parsing;
      _error = null;
    });
    try {
      final result = await widget.api.parseExternalPlaylist(text);
      if (!mounted) return;
      if (result.songNames.isEmpty) {
        setState(() {
          _step = _ImportStep.input;
          _error = '未能从分享内容中解析出歌曲，请检查链接是否完整';
        });
        return;
      }
      final playlists = _targetPlaylists;
      setState(() {
        _result = result;
        _step = _ImportStep.parsed;
        _selectedListId = playlists.length == 1 ? playlists.first.listId : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _ImportStep.input;
        _error = '解析失败：$e';
      });
    }
  }

  Future<void> _import() async {
    final result = _result;
    final listId = _selectedListId;
    if (result == null || listId == null) return;

    setState(() {
      _step = _ImportStep.importing;
      _matched = 0;
      _done = 0;
      _total = result.songNames.length;
    });

    var matched = 0;
    var done = 0;
    try {
      for (final name in result.songNames) {
        if (!mounted) return;
        final song = await _matchSong(name);
        done++;
        if (song != null) {
          await widget.api.addSongsToPlaylist(listId, [song]);
          matched++;
        }
        if (mounted) {
          setState(() {
            _matched = matched;
            _done = done;
          });
        }
      }
      if (!mounted) return;
      Toast.success('导入完成：成功匹配 $matched 首歌曲');
      Navigator.of(context).pop();
      widget.auth.refreshProfile(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _ImportStep.parsed;
        _error = '导入出错：$e';
      });
      Toast.error('导入失败：$e');
    }
  }

  /// 搜索并返回与歌名最匹配的歌曲（取标题命中且 hash 非空的第一首）。
  Future<Song?> _matchSong(String name) async {
    final keyword = name.trim();
    if (keyword.isEmpty) return null;
    try {
      final songs = await widget.api.searchSongs(keyword, pageSize: 5);
      Song? fallback;
      for (final song in songs) {
        if (song.hash.isEmpty) continue;
        fallback ??= song;
        final title = song.title.toLowerCase();
        final target = keyword.toLowerCase();
        if (title.contains(target) || target.contains(title)) {
          return song;
        }
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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
            '导入歌单',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            '支持网易云 / QQ 音乐的歌单分享链接或分享文本',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (_step == _ImportStep.input || _step == _ImportStep.parsing) ...[
            TextField(
              controller: _controller,
              enabled: _step != _ImportStep.parsing,
              maxLines: 4,
              minLines: 3,
              decoration: InputDecoration(
                hintText:
                    '粘贴分享链接或文本，例如：\n分享歌单《xxx》… https://music.163.com/playlist?id=123',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
            ),
            if (_error case final message?) ...[
              const SizedBox(height: 10),
              Text(
                message,
                style: TextStyle(color: colorScheme.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _step == _ImportStep.parsing ? null : _parse,
              icon: _step == _ImportStep.parsing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : const Icon(Icons.link_rounded),
              label: Text(_step == _ImportStep.parsing ? '解析中…' : '解析歌单'),
            ),
          ] else if (_step == _ImportStep.parsed ||
              _step == _ImportStep.importing)
            _buildResult(colorScheme),
        ],
      ),
    );
  }

  Widget _buildResult(ColorScheme colorScheme) {
    final result = _result;
    if (result == null) return const SizedBox.shrink();
    final playlists = _targetPlaylists;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Icon(Icons.playlist_play_rounded, color: colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.playlistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${result.songNames.length} 首歌曲 · ${_platformLabel(result.sourcePlatform)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '导入到',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (playlists.isEmpty)
          Text(
            '暂无可导入的歌单，请先在「我的」页面创建歌单',
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final playlist in playlists)
                ChoiceChip(
                  label: Text(playlist.title, overflow: TextOverflow.ellipsis),
                  selected: _selectedListId == playlist.listId,
                  onSelected: _step == _ImportStep.importing
                      ? null
                      : (_) =>
                            setState(() => _selectedListId = playlist.listId),
                ),
            ],
          ),
        if (_error case final message?) ...[
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(color: colorScheme.error, fontSize: 13),
          ),
        ],
        const SizedBox(height: 18),
        if (_step == _ImportStep.importing) ...[
          LinearProgressIndicator(
            value: _total == 0 ? null : _done / _total,
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          const SizedBox(height: 8),
          Text(
            '正在匹配并添加歌曲 $_done/$_total（已匹配 $_matched 首）…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ] else
          FilledButton.icon(
            onPressed: _selectedListId == null ? null : _import,
            icon: const Icon(Icons.download_rounded),
            label: const Text('开始导入'),
          ),
      ],
    );
  }

  String _platformLabel(String platform) {
    if (platform.isEmpty) return '未知平台';
    if (platform.toLowerCase().contains('163') ||
        platform.toLowerCase().contains('netease')) {
      return '网易云音乐';
    }
    if (platform.toLowerCase().contains('qq')) {
      return 'QQ 音乐';
    }
    return platform;
  }
}
