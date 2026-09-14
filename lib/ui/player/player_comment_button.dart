import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../desktop/player_bar_widgets.dart';
import '../pages/comment_page.dart';

/// 格式化评论数字：
/// - count <= 0：显示 0
/// - 1 ~ 999：显示真实数字（如 12、88、999）
/// - 1000 ~ 9999：显示 999+
/// - 1万 ~ 99万：显示 xxw+（如 1w+、16w+）
/// - >= 99万：封顶 99w+
String formatCommentCount(int count) {
  if (count <= 0) return '0';
  if (count >= 990000) {
    return '99w+';
  }
  if (count >= 10000) {
    return '${count ~/ 10000}w+';
  }
  if (count >= 1000) {
    return '999+';
  }
  return '$count';
}

/// 评论数角标会话内缓存（mixsongid → 条数）：PC 底栏、移动端海报页与歌词页共用，
/// 切回已拉取过的歌曲不重复请求。
final Map<String, int> _commentCountCache = {};

/// 正在拉取评论数的 mixsongid，防止同一首歌被不同位置重复请求。
final Set<String> _commentCountInFlight = {};

/// 供测试环境重置缓存
@visibleForTesting
void clearCommentCountCacheForTest() {
  _commentCountCache.clear();
  _commentCountInFlight.clear();
}

dynamic _safeApi(PlayerController player) {
  try {
    return player.api;
  } catch (_) {
    return null;
  }
}

/// 通用评论气泡按钮（PC 与移动端统一规范）：
/// 圆角气泡 + 内部双点眼睛 + 底部小尾巴，右上角描边缺口处嵌评论数角标。
///
/// 评论数来自 `api.musicComments(pageSize: 1)` 的 `count`，会话内缓存；
/// 无接口/拉取失败时静默退化为无角标气泡，不影响点击进评论页。
class PlayerCommentButton extends StatefulWidget {
  const PlayerCommentButton({
    super.key,
    required this.player,
    required this.song,
    this.iconSize = 20.0,
    this.iconColor = Colors.white,
    this.onOpenComment,
  });

  final PlayerController? player;
  final Song? song;
  final double iconSize;
  final Color iconColor;
  final ValueChanged<String>? onOpenComment;

  @override
  State<PlayerCommentButton> createState() => _PlayerCommentButtonState();
}

class _PlayerCommentButtonState extends State<PlayerCommentButton> {
  String? get _mixsongid {
    final song = widget.song;
    if (song == null) return null;
    final id = song.albumAudioId ?? song.id;
    return id.isEmpty ? null : id;
  }

  Future<void> _fetchCount(dynamic api, String mixsongid) async {
    if (_commentCountInFlight.contains(mixsongid)) return;
    _commentCountInFlight.add(mixsongid);
    try {
      final response = await api.musicComments(mixsongid, page: 1, pageSize: 1);
      final count = response.count as int?;
      if (count != null && count > 0) {
        _commentCountCache[mixsongid] = count;
        if (mounted) setState(() {});
      }
    } catch (_) {
      // 拉取失败本次不显示角标，不打扰播放；下次重建再试。
    } finally {
      _commentCountInFlight.remove(mixsongid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.player == null ? null : _safeApi(widget.player!);
    final mixsongid = _mixsongid;
    final enabled =
        widget.song != null &&
        widget.song!.source == SongSource.kugou &&
        mixsongid != null &&
        (api != null || widget.onOpenComment != null);

    int? count;
    if (enabled && api != null) {
      count = _commentCountCache[mixsongid];
      if (count == null) {
        _fetchCount(api, mixsongid);
      }
    }
    final badge = count == null ? null : formatCommentCount(count);
    final effectiveColor = enabled
        ? widget.iconColor
        : widget.iconColor.withValues(alpha: 0.38);

    final size = widget.iconSize;

    return IconButton(
      tooltip: enabled ? '评论' : '暂无评论',
      onPressed: !enabled
          ? null
          : () {
              final id = mixsongid;
              final openComment = widget.onOpenComment;
              if (openComment != null) {
                openComment(id);
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CommentPage(api: api, mixsongid: id),
                ),
              );
            },
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          CommentBubbleIcon(
            size: size,
            color: effectiveColor,
            showBadgeGap: badge != null,
          ),
          if (badge != null)
            Positioned(
              left: size - 7,
              top: -3,
              child: Text(
                badge,
                style: TextStyle(
                  fontSize: 8.5,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                  color: effectiveColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
