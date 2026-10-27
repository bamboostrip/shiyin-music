import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../../models/music_models.dart';
import 'toast.dart';

/// 歌曲分享文案（纯函数，便于单测）。
///
/// 统一格式：`🎵 推荐歌曲：《歌名》 - 歌手（专辑：xxx）\n来自 时音`；
/// 专辑为空（null / 空白）时不带括号段，避免出现「（专辑：）」空壳；
/// 歌手为空（空白）时整段「 - 歌手」省略、歌名空白时用「未知歌曲」占位，
/// 避免残缺文案（Song 各 factory 一般已有兜底，这里只做纯函数健壮性）。
String buildSongShareText(Song song) {
  final album = song.albumName?.trim() ?? '';
  final albumSegment = album.isEmpty ? '' : '（专辑：$album）';
  // 只用 trim 结果做空判定，非空字段按原样输出，保证正常文案逐字节不变。
  final hasTitle = song.title.trim().isNotEmpty;
  final hasArtist = song.artist.trim().isNotEmpty;
  final displayTitle = hasTitle ? song.title : '未知歌曲';
  final artistSegment = hasArtist ? ' - ${song.artist}' : '';
  return '🎵 推荐歌曲：《$displayTitle》$artistSegment$albumSegment\n来自 时音';
}

/// 复制歌曲分享文案到剪贴板，并给一致的 Toast 反馈。
///
/// 移动端底部弹窗 / 车机弹窗 / 桌面菜单头部共用本方法，
/// 保证三端文案与提示语完全一致（避免各自手拼字符串）。
///
/// 剪贴板平台通道极少数情况下会失败（系统剪贴板服务被占用/受限），
/// 这里兜底提示而不是把未捕获异常抛给 Zone——分享属于锦上添花操作，
/// 失败不能影响菜单关闭后的正常使用。
Future<void> copySongShareText(Song song) async {
  try {
    await Clipboard.setData(ClipboardData(text: buildSongShareText(song)));
  } catch (error) {
    debugPrint('[SongShare] 写入剪贴板失败: $error');
    Toast.error('复制失败，请稍后重试');
    return;
  }
  Toast.success('已复制歌曲分享信息到剪贴板');
}
