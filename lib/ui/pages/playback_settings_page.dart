import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/music_api.dart';
import '../settings/playback_settings_section.dart';
import '../widgets/audio_quality_sheet.dart';

/// 「播放设置」二级页。
///
/// 主设置页只保留入口，本页承载音质/音效、播放行为、后台与网络、歌词与设备、
/// 内容与数据五组选项。设置页主体保持单列滚动，桌面端加最大宽度避免卡片
/// 横跨整个窗口。
class PlaybackSettingsPage extends StatelessWidget {
  const PlaybackSettingsPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.showLyricPageSkipButtons,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  /// 由入口页按形态/车机模式计算后传入，见 [PlaybackSettingsSection]。
  final bool showLyricPageSkipButtons;

  Future<void> _selectDefaultAudioQuality(BuildContext context) async {
    final quality = await showAudioQualitySheet(
      context: context,
      selected: player.audioQuality,
      title: '默认音质',
      subtitle: '新播放的歌曲会使用这个音质',
    );
    if (quality == null) return;
    await player.setAudioQuality(quality);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('播放设置')),
      body: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 32),
                children: [
                  PlaybackSettingsSection(
                    api: api,
                    auth: auth,
                    player: player,
                    showLyricPageSkipButtons: showLyricPageSkipButtons,
                    onSelectDefaultAudioQuality: () =>
                        _selectDefaultAudioQuality(context),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
