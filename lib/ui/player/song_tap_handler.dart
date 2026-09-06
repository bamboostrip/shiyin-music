import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import 'player_route.dart';

/// 移动端歌曲列表行点击统一入口（对齐 QQ/网易云/酷狗移动端行为）。
///
/// - 点到**当前正在播的那首**：绝不重头播放；暂停中则原位继续，
///   并打开播放页（无 auth 时退化为“恢复播放/无反应”，同样不重启）。
/// - 点到其他歌曲：返回 false，调用方继续走 `playSong` 切歌。
/// - 桌面端保持原行为（返回 false），单击选中/双击重播等 PC 交互不受影响。
bool openPlayerIfSameSong(
  BuildContext context, {
  required PlayerController player,
  AuthController? auth,
  required Song song,
}) {
  if (isDesktopFormFactor) return false;
  if (!isSameSong(player.currentSong, song)) return false;
  if (!player.isPlaying) {
    // 暂停中点回当前：原位继续。idle 冷启动恢复场景下 togglePlay 内部
    // 会走完整加载流程，无需调用方额外处理。
    unawaited(player.togglePlay());
  }
  final a = auth;
  if (a != null && context.mounted) {
    PlayerPageRoute.open(context, player: player, auth: a);
  }
  return true;
}

/// 当前歌曲同一性判断（hash 为空时退化用 id，避免空 hash 全等误伤）。
bool isSameSong(Song? current, Song song) {
  if (current == null) return false;
  if (song.hash.isNotEmpty && current.hash.isNotEmpty) {
    return current.hash == song.hash;
  }
  return song.id.isNotEmpty && current.id == song.id;
}
