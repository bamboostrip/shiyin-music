import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/local_audio_formats.dart';

void main() {
  group('平台 → 播放内核', () {
    test('桌面走 mpv，Android 走 ExoPlayer，Apple 走 AVFoundation', () {
      expect(
        localAudioEngineFor(TargetPlatform.windows),
        LocalAudioEngine.mpv,
      );
      expect(localAudioEngineFor(TargetPlatform.linux), LocalAudioEngine.mpv);
      expect(
        localAudioEngineFor(TargetPlatform.android),
        LocalAudioEngine.exoPlayer,
      );
      expect(
        localAudioEngineFor(TargetPlatform.iOS),
        LocalAudioEngine.avFoundation,
      );
      expect(
        localAudioEngineFor(TargetPlatform.macOS),
        LocalAudioEngine.avFoundation,
      );
      expect(
        localAudioEngineFor(TargetPlatform.fuchsia),
        LocalAudioEngine.unknown,
      );
    });
  });

  group('后缀解析', () {
    test('Windows 路径 / 正斜杠 / file URI 都取得到后缀', () {
      expect(localAudioExtensionOf(r'D:\Music\专辑\a.FLAC'), 'flac');
      expect(localAudioExtensionOf('/storage/emulated/0/Music/a.Mp3'), 'mp3');
      expect(localAudioExtensionOf('file:///music/a.ape'), 'ape');
    });

    test('无后缀、点开头、结尾点号都返回 null', () {
      expect(localAudioExtensionOf('/music/noext'), isNull);
      expect(localAudioExtensionOf('/music/.hidden'), isNull);
      expect(localAudioExtensionOf('/music/trailing.'), isNull);
    });

    test('目录名里的点号不算后缀', () {
      expect(localAudioExtensionOf(r'D:\2026.05\歌曲'), isNull);
      expect(localAudioExtensionOf(r'D:\2026.05\歌曲.mp3'), 'mp3');
    });
  });

  group('内核能力判定', () {
    test('mpv 认 APE/WMA/DSD，ExoPlayer 不认', () {
      for (final path in const [
        r'D:\m\a.ape',
        r'D:\m\a.wma',
        r'D:\m\a.dsf',
        r'D:\m\a.aiff',
      ]) {
        expect(
          isSupportedLocalAudio(path, engine: LocalAudioEngine.mpv),
          isTrue,
          reason: path,
        );
      }
      for (final path in const [
        r'D:\m\a.ape',
        r'D:\m\a.wma',
        r'D:\m\a.dsf',
        // ExoPlayer(media3) 没有 AIFF 解析器：本地扫描能列出、放不出来。
        r'D:\m\a.aiff',
      ]) {
        expect(
          isSupportedLocalAudio(path, engine: LocalAudioEngine.exoPlayer),
          isFalse,
          reason: path,
        );
      }
    });

    test('通用格式各内核都认', () {
      for (final engine in LocalAudioEngine.values) {
        if (engine == LocalAudioEngine.unknown) continue;
        for (final path in const [r'D:\m\a.mp3', r'D:\m\a.flac', r'D:\m\a.m4a']) {
          expect(isSupportedLocalAudio(path, engine: engine), isTrue);
        }
      }
    });

    test('未知后缀与未知平台一律放行，不凭一张表把文件判死', () {
      expect(
        isSupportedLocalAudio(r'D:\m\a.xyz', engine: LocalAudioEngine.exoPlayer),
        isTrue,
      );
      expect(
        isSupportedLocalAudio(r'D:\m\a.ape', engine: LocalAudioEngine.unknown),
        isTrue,
      );
      expect(isSupportedLocalAudio('/m/noext'), isTrue);
    });
  });

  group('失败原因文案', () {
    test('不支持时点名后缀并给出出路', () {
      final reason = unsupportedLocalAudioReason(
        '/storage/emulated/0/Music/a.APE',
        engine: LocalAudioEngine.exoPlayer,
      );
      expect(reason, isNotNull);
      expect(reason, contains('.ape'));
      expect(reason, contains('FLAC'));
    });

    test('支持时返回 null（调用方据此不提示）', () {
      expect(
        unsupportedLocalAudioReason(
          '/storage/emulated/0/Music/a.flac',
          engine: LocalAudioEngine.exoPlayer,
        ),
        isNull,
      );
    });
  });
}
