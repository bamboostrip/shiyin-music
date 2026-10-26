import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';

import '../../controllers/auth_controller.dart';
import '../../core/api_client.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../../services/playlist_import_service.dart';
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

/// 导入流程：输入 → 解析中 → 已解析（选目标歌单）→ 导入中（可停止）→ 完成。
enum _ImportStep { input, parsing, parsed, importing, complete }

class _ImportPlaylistSheetState extends State<ImportPlaylistSheet> {
  static const _newPlaylist = '__new__';
  final _controller = TextEditingController();
  final _nameController = TextEditingController();

  _ImportStep _step = _ImportStep.input;
  ExternalPlaylistParseResult? _result;
  String? _error;
  String _selectedListId = _newPlaylist;
  bool _cancelRequested = false;
  PlaylistImportProgress _progress = const PlaylistImportProgress();

  /// 可导入的目标歌单（仅用户自建歌单）。
  List<PlaylistSummary> get _targetPlaylists => widget.auth.playlists
      .where((p) => p.isCreatedPlaylist && p.listId?.isNotEmpty == true)
      .toList();

  List<ExternalPlaylistTrack> get _tracks =>
      _result?.importTracks ?? const <ExternalPlaylistTrack>[];

  bool get _busy => _step == _ImportStep.importing;

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      Toast.info('请先粘贴 QQ 音乐 / 网易云歌单分享链接或分享文本');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _step = _ImportStep.parsing;
      _error = null;
    });
    try {
      final result = await widget.api
          .parseExternalPlaylist(text)
          .timeout(const Duration(minutes: 2));
      if (!mounted) return;
      if (result.importTracks.isEmpty) {
        throw const FormatException('歌单为空或不可见，请确认歌单已公开');
      }
      setState(() {
        _result = result;
        _nameController.text = result.playlistName.trim().isEmpty
            ? '导入的歌单'
            : result.playlistName;
        _selectedListId = _newPlaylist;
        _step = _ImportStep.parsed;
      });
    } catch (e) {
      if (!mounted) return;
      // 保留输入内容，用户改完链接可直接重试。
      setState(() {
        _step = _ImportStep.input;
        _error = '解析失败：${_errorText(e)}';
      });
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    final result = _result;
    if (result == null) return;
    if (!widget.auth.isLoggedIn) {
      setState(() => _error = '请先登录酷狗账号后再导入歌单');
      return;
    }
    final creatingNew = _selectedListId == _newPlaylist;
    final newName = _nameController.text.trim();
    if (creatingNew && newName.isEmpty) {
      setState(() => _error = '请输入新歌单名称');
      return;
    }
    setState(() {
      _step = _ImportStep.importing;
      _error = null;
      _cancelRequested = false;
      _progress = const PlaylistImportProgress();
    });
    PlaylistSummary? target;
    try {
      if (creatingNew) {
        // 创建前先记下已有 listId，创建成功后按歌单名（找不到则取新增项）
        // 定位刚建好的歌单。
        final previousIds = _targetPlaylists
            .map((playlist) => playlist.listId)
            .whereType<String>()
            .toSet();
        await widget.auth.createPlaylist(newName);
        if (!mounted) return;
        target = _findCreatedPlaylist(newName, previousIds);
        if (target == null) {
          throw StateError(widget.auth.errorMessage ?? '新建歌单失败，请稍后重试');
        }
        _selectedListId = target.listId!;
      } else {
        for (final playlist in _targetPlaylists) {
          if (playlist.listId == _selectedListId) target = playlist;
        }
        if (target == null) {
          throw StateError('未找到目标歌单，请刷新后重新选择');
        }
      }
      // 目标歌单已有歌曲 hash（大小写不敏感），导入时跳过；「重新导入」也依赖
      // 它保证不会重复添加已成功的部分。
      final existing = await widget.api
          .playlistSongs(target.id, fetchAll: true)
          .timeout(const Duration(seconds: 30));
      final progress = await PlaylistImportService(widget.api).import(
        listId: target.listId!,
        tracks: result.importTracks,
        existingHashes: existing
            .map((song) => song.hash)
            .where((hash) => hash.isNotEmpty)
            .toSet(),
        shouldCancel: () => !mounted || _cancelRequested,
        onProgress: (snapshot) {
          if (mounted) setState(() => _progress = snapshot);
        },
      );
      try {
        await widget.auth
            .refreshProfile(silent: true)
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        // 歌曲已经写入：刷新歌单列表失败不能把成功的导入展示成失败。
        debugPrint('导入完成后刷新歌单失败: $e');
      }
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _step = _ImportStep.complete;
      });
    } catch (e) {
      if (!mounted) return;
      // 已成功写入的部分不清空：大歌单中途异常/刷新失败时保留进度与统计。
      final hasPartial = _progress.added > 0 || _progress.processed > 0;
      final message = '导入出错：${_errorText(e)}';
      setState(() {
        _error = message;
        _step = hasPartial ? _ImportStep.complete : _ImportStep.parsed;
      });
      Toast.error(message);
    }
  }

  PlaylistSummary? _findCreatedPlaylist(String name, Set<String> previousIds) {
    final created = _targetPlaylists
        .where((playlist) => !previousIds.contains(playlist.listId))
        .toList();
    if (created.isEmpty) return null;
    final matched = created.where((playlist) => playlist.title.trim() == name);
    final target = matched.isNotEmpty ? matched.first : created.first;
    return target.listId?.isNotEmpty == true ? target : null;
  }

  /// 后端异常统一转成简短中文：`ApiException` 取 message，其余去掉异常类前缀。
  String _errorText(Object error) {
    if (error is ApiException) return error.message;
    return error.toString().replaceFirst(
      RegExp(r'^(?:FormatException|Exception|StateError):\s*'),
      '',
    );
  }

  Future<void> _copyUnmatched() async {
    if (_progress.unmatched.isEmpty) return;
    try {
      await Clipboard.setData(
        ClipboardData(text: _progress.unmatched.join('\n')),
      );
      if (mounted) Toast.success('未匹配歌曲清单已复制');
    } catch (_) {
      if (mounted) Toast.error('复制失败');
    }
  }

  void _backToInput() {
    setState(() {
      _step = _ImportStep.input;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final result = _result;
    return PopScope(
      // 导入中禁止返回，避免写操作在后台继续但界面已经关闭。
      canPop: !_busy,
      child: SafeArea(
        child: SingleChildScrollView(
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
                '支持 QQ 音乐 / 网易云歌单分享链接或分享文本',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              if (_step == _ImportStep.input || _step == _ImportStep.parsing)
                ..._buildInput(colors)
              else if (result != null)
                _buildResult(colors, result),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildInput(ColorScheme colors) {
    return [
      TextField(
        controller: _controller,
        enabled: _step != _ImportStep.parsing,
        maxLines: 4,
        minLines: 3,
        decoration: InputDecoration(
          hintText:
              '粘贴分享链接或文本，例如：\n共享歌单《xxx》https://y.qq.com/n/ryqq/playlist/123',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
      if (_error case final message?) ...[
        const SizedBox(height: 10),
        Text(
          message,
          style: TextStyle(color: colors.error, fontSize: 13),
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
    ];
  }

  Widget _buildResult(ColorScheme colors, ExternalPlaylistParseResult result) {
    final tracks = _tracks;
    final total = result.totalSongCount ?? tracks.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 歌单信息卡：平台 / 歌单名 / 曲目数。
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Icon(Icons.playlist_play_rounded, color: colors.primary),
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
                      '${tracks.length} 首曲目 · ${_platformLabel(result.sourcePlatform)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (total > tracks.length) ...[
                      const SizedBox(height: 2),
                      Text(
                        '原歌单共 $total 首，其中部分歌曲不可读取',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_step == _ImportStep.parsed) ...[
          const SizedBox(height: 14),
          Text(
            '按歌名、歌手和时长匹配酷狗曲库，跳过目标歌单已有歌曲',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('新建歌单'),
                selected: _selectedListId == _newPlaylist,
                onSelected: (_) =>
                    setState(() => _selectedListId = _newPlaylist),
              ),
              for (final playlist in _targetPlaylists)
                ChoiceChip(
                  label: Text(playlist.title, overflow: TextOverflow.ellipsis),
                  selected: _selectedListId == playlist.listId,
                  onSelected: (_) => setState(
                    () => _selectedListId = playlist.listId ?? _newPlaylist,
                  ),
                ),
            ],
          ),
          if (_targetPlaylists.isEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '暂无自建歌单，将导入到新建歌单',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          if (_selectedListId == _newPlaylist) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: '新歌单名称',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
            ),
          ],
          if (!widget.auth.isLoggedIn) ...[
            const SizedBox(height: 12),
            Text(
              '尚未登录酷狗账号，请先登录后再导入；登录前不会执行任何写入。',
              style: TextStyle(color: colors.error, fontSize: 13),
            ),
          ],
          if (_error case final message?) ...[
            const SizedBox(height: 10),
            Text(
              message,
              style: TextStyle(color: colors.error, fontSize: 13),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: widget.auth.isLoggedIn ? _import : null,
            icon: const Icon(Icons.download_rounded),
            label: const Text('开始导入'),
          ),
          TextButton(
            onPressed: _backToInput,
            child: const Text('更换分享链接'),
          ),
        ],
        if (_step == _ImportStep.importing ||
            _step == _ImportStep.complete) ...[
          const SizedBox(height: 16),
          if (_step == _ImportStep.importing)
            LinearProgressIndicator(
              value: tracks.isEmpty
                  ? null
                  : _progress.processed / tracks.length,
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
          if (_step == _ImportStep.importing) ...[
            const SizedBox(height: 8),
            Text(
              '正在匹配并添加歌曲 ${_progress.processed}/${tracks.length}'
              '（新增 ${_progress.added} 首）…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            TextButton(
              onPressed: _cancelRequested
                  ? null
                  : () => setState(() => _cancelRequested = true),
              child: Text(
                _cancelRequested ? '当前请求结束后停止…' : '停止导入',
              ),
            ),
          ],
          if (_step == _ImportStep.complete) ...[
            Text(
              _cancelRequested ? '已停止导入' : '导入完成',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '已处理 ${_progress.processed}/${tracks.length} 首',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '新增 ${_progress.added} · 已存在 ${_progress.duplicates} · '
              '未匹配 ${_progress.unmatched.length} · '
              '失败 ${_progress.failed.length}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (_error case final message?) ...[
              const SizedBox(height: 8),
              Text(
                message,
                style: TextStyle(color: colors.error, fontSize: 13),
              ),
            ],
            if (_progress.unmatched.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildTrackList(
                title: '未匹配的歌曲',
                tracks: _progress.unmatched,
                actions: [
                  TextButton.icon(
                    onPressed: _copyUnmatched,
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('复制清单'),
                  ),
                ],
              ),
            ],
            if (_progress.failed.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildTrackList(
                title: '请求失败的歌曲（可重新导入）',
                tracks: _progress.failed,
              ),
            ],
            const SizedBox(height: 16),
            if (_progress.failed.isNotEmpty || _cancelRequested)
              TextButton(
                onPressed: _import,
                child: const Text('重新导入（跳过已有歌曲）'),
              ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildTrackList({
    required String title,
    required List<String> tracks,
    List<Widget> actions = const [],
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: ExpansionTile(
        title: Text(
          '$title（${tracks.length}）',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        shape: const Border(),
        collapsedShape: const Border(),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        children: [
          SelectableText(
            tracks.join('\n'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (actions.isNotEmpty)
            Align(alignment: Alignment.centerRight, child: Row(
              mainAxisSize: MainAxisSize.min,
              children: actions,
            )),
        ],
      ),
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
