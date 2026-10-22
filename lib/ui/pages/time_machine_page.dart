import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../adaptive_layout.dart';
import '../widgets/app_song_row.dart';
import '../player/song_tap_handler.dart';
import 'login_page.dart';

/// 听歌时光机：酷狗账号云端播放历史的按日期回顾（只读拉取）。
///
/// 数据来自官方 App 同源的账号级听歌记录（issue #2 一期）；
/// 上报（把时音的播放写回云端）是二期，本页不含任何写操作。
class TimeMachinePage extends StatefulWidget {
  const TimeMachinePage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  @override
  State<TimeMachinePage> createState() => _TimeMachinePageState();
}

class _TimeMachinePageState extends State<TimeMachinePage> {
  Future<CloudPlayHistory>? _future;

  @override
  void initState() {
    super.initState();
    if (widget.auth.isLoggedIn) {
      _reload();
    }
  }

  void _reload() {
    setState(() {
      _future = widget.api.cloudPlayHistory();
    });
  }

  Future<void> _goLogin() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoginPage(auth: widget.auth, api: widget.api),
      ),
    );
    if (!mounted) return;
    // 登录成功返回后立即拉取云端历史；LoginPage 成功时 pop(account)，
    // 返回值无需判内容，只看登录态（失败/取消返回则停留在引导页）。
    if (widget.auth.isLoggedIn) {
      _reload();
    }
  }

  void _play(CloudPlayRecord record, List<Song> queue) {
    if (openPlayerIfSameSong(
      context,
      player: widget.player,
      auth: widget.auth,
      song: record.song,
    )) {
      return;
    }
    widget.player.playSong(record.song, queue: queue);
  }

  String _formatDate(DateTime time) =>
      '${time.year}年${time.month}月${time.day}日';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌时光机'),
        actions: [
          if (_future != null)
            IconButton(
              tooltip: '刷新',
              // 错误态的重试按钮同用 refresh_rounded；AppBar 换 outlined
              // 变体，避免同屏两枚同形刷新图标（含语义混淆）。
              icon: const Icon(Icons.refresh_outlined),
              onPressed: _reload,
            ),
        ],
      ),
      body: AdaptiveContentPadding(
        child: !widget.auth.isLoggedIn
            ? _LoginGuideView(onLogin: _goLogin)
            : FutureBuilder<CloudPlayHistory>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _ErrorView(message: '${snapshot.error}', onRetry: _reload);
                  }
                  final history = snapshot.data ?? const CloudPlayHistory();
                  if (history.totalRecords == 0) {
                    return const _EmptyView();
                  }
                  return _TimeMachineContent(
                    history: history,
                    player: widget.player,
                    formatDate: _formatDate,
                    onPlay: _play,
                  );
                },
              ),
      ),
    );
  }
}

/// 登录引导：云端历史依赖酷狗账号，未登录时先引导登录。
class _LoginGuideView extends StatelessWidget {
  const _LoginGuideView({required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.hourglass_top_rounded,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 16),
            Text(
              '登录后查看你的听歌时光机',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '登录酷狗账号后，可回顾云端同步的听歌记录',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: onLogin,
              icon: const Icon(Icons.login_rounded),
              label: const Text('去登录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态：账号下还没有任何云端记录。
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 16),
            Text(
              '云端还没有听歌记录',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '用同一酷狗账号在官方 App 或时音听歌后，这里会出现你的听歌足迹',
              textAlign: TextAlign.center,
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

/// 错误态：拉取失败，展示原因并允许重试。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48),
            const SizedBox(height: 12),
            const Text('加载失败', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 内容主体：摘要卡片 + 按日分组的歌曲行列表。
class _TimeMachineContent extends StatelessWidget {
  const _TimeMachineContent({
    required this.history,
    required this.player,
    required this.formatDate,
    required this.onPlay,
  });

  final CloudPlayHistory history;
  final PlayerController player;
  final String Function(DateTime time) formatDate;
  final void Function(CloudPlayRecord record, List<Song> queue) onPlay;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final groups = history.groupByDay();
    // 全量队列：任意行起播时，随机/顺序队列都覆盖整份云端记录。
    final allSongs = [for (final record in history.records) record.song];
    final earliest = history.earliestPlayedAt;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Text(
              earliest == null
                  ? '共 ${history.totalRecords} 条云端记录'
                  : '共 ${history.totalRecords} 条云端记录'
                      ' · 最早可回到 ${formatDate(earliest)}',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        for (final group in groups) ...[
          const SizedBox(height: 24),
          _GroupHeader(label: group.label, count: group.records.length),
          const SizedBox(height: 8),
          for (final record in group.records)
            AppSongRow(
              song: record.song,
              player: player,
              subtitle: _formatTime(record.playedAt),
              onTap: () => onPlay(record, allSongs),
            ),
        ],
      ],
    );
  }

  /// 24 小时制的 HH:mm（如 14:05）；无时间时不传副标题、保持默认歌手名。
  String? _formatTime(DateTime? time) {
    if (time == null) return null;
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

/// 分组头：日期标签 + 当日条数（样式对齐统计页 _SectionHeader）。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ),
          Text(
            '$count 首',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
