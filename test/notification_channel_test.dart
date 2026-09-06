import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

void main() {
  group('resolvePlaybackNotificationChannel', () {
    test('普通手机环境（非车机设备且未开启车机模式）使用标准手机媒体渠道', () {
      final config = resolvePlaybackNotificationChannel(
        isCarMode: false,
        isAutomotiveDevice: false,
      );

      expect(config.channelId, 'kgka_music_hl.playback_phone');
      expect(config.channelName, '时音 播放控制');
    });

    test('原生车机设备（isAutomotiveDevice 为 true）使用车机专属静默渠道', () {
      final config = resolvePlaybackNotificationChannel(
        isCarMode: false,
        isAutomotiveDevice: true,
      );

      expect(config.channelId, 'kgka_music_hl.playback_car');
      expect(config.channelName, '时音 车机播放控制');
    });

    test('用户手动开启车机模式（isCarMode 为 true）使用车机专属静默渠道', () {
      final config = resolvePlaybackNotificationChannel(
        isCarMode: true,
        isAutomotiveDevice: false,
      );

      expect(config.channelId, 'kgka_music_hl.playback_car');
      expect(config.channelName, '时音 车机播放控制');
    });

    test('两者皆为 true 时使用车机专属静默渠道', () {
      final config = resolvePlaybackNotificationChannel(
        isCarMode: true,
        isAutomotiveDevice: true,
      );

      expect(config.channelId, 'kgka_music_hl.playback_car');
      expect(config.channelName, '时音 车机播放控制');
    });
  });

  group('MusicAudioHandler.contentTypeForPath（本地文件代理 Content-Type）', () {
    test('按扩展名映射，未知回退 audio/mpeg', () {
      expect(MusicAudioHandler.contentTypeForPath('song.mp3'), 'audio/mpeg');
      expect(MusicAudioHandler.contentTypeForPath('song.flac'.toLowerCase()),
          'audio/flac');
      expect(MusicAudioHandler.contentTypeForPath('D:\\音乐\\无损.FLAC'),
          'audio/flac');
      expect(MusicAudioHandler.contentTypeForPath('song.wav'), 'audio/wav');
      expect(MusicAudioHandler.contentTypeForPath('song.ogg'), 'audio/ogg');
      expect(MusicAudioHandler.contentTypeForPath('song.m4a'), 'audio/mp4');
      expect(MusicAudioHandler.contentTypeForPath('song.aac'), 'audio/aac');
      expect(MusicAudioHandler.contentTypeForPath('song.unknown'),
          'audio/mpeg');
      expect(MusicAudioHandler.contentTypeForPath('无扩展名'), 'audio/mpeg');
    });
  });
}
