// MediaSession 歌词元数据构建（上游 3.3.0 LyricInfo 协议）的纯函数单测：
//   1. extras 写入当前行/翻译/音译/整首 LRC + org.akanework.lyricinfo 协议别名；
//   2. lyricInfo JSON 字段（songName/artist/album/songId/lyric/translation/roma）
//      与缺省裁剪（album 空省略、songId 回退 hash、空翻译/音译省略）；
//   3. 手环/AVRCP 标题覆盖开关只影响 title，不动 artist/album；
//   4. 清空语义（全 null）：extras 只剩 hash/songId，不再残留歌词字段。
//
// 注意：这些是 MusicAudioHandler 上的 static 纯构建函数，单测不创建
// MusicAudioHandler（其字段初始化会 new 真实 AudioPlayer，仓库明令禁止）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/local_artwork_service.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

Song _song({
  String id = 'id_1',
  String title = '晴天',
  String artist = '周杰伦',
  String hash = 'hash_1',
  String? albumName = '叶惠美',
  String? coverUrl,
  Duration? duration,
}) {
  return Song(
    id: id,
    title: title,
    artist: artist,
    hash: hash,
    albumName: albumName,
    coverUrl: coverUrl,
    duration: duration,
  );
}

Map<String, dynamic> _extras({
  Song? song,
  String? lyricText,
  String? translationText,
  String? romanizationText,
  String? fullLyricLrc,
  int? positionMs,
  int? durationMs,
  bool? playing,
}) {
  return MusicAudioHandler.buildLyricMediaExtras(
    song: song ?? _song(),
    lyricText: lyricText,
    translationText: translationText,
    romanizationText: romanizationText,
    fullLyricLrc: fullLyricLrc,
    positionMs: positionMs,
    durationMs: durationMs,
    playing: playing,
  );
}

void main() {
  group('MusicAudioHandler.buildLyricMediaExtras', () {
    test('当前行/翻译/音译/整首 LRC 与 LyricInfo 协议别名齐全', () {
      const fullLrc = '[00:00.00]第一句\n[00:05.00]第二句';
      final extras = _extras(
        lyricText: '第一句',
        translationText: 'first line',
        romanizationText: 'dai yi ju',
        fullLyricLrc: fullLrc,
      );

      expect(extras['hash'], 'hash_1');
      expect(extras['songId'], 'id_1');
      expect(extras['lyric'], '第一句');
      expect(extras['currentLyric'], '第一句');
      expect(extras['translationLyric'], 'first line');
      expect(extras['romanLyric'], 'dai yi ju');
      expect(extras['full_lrc'], fullLrc);
      expect(extras['org.akanework.lyricinfo.FULL_LYRICS'], fullLrc);
      expect(extras['org.akanework.lyricinfo.CURRENT_LYRIC'], '第一句');
      expect(extras.containsKey('lyricInfo'), isTrue);
    });

    test('lyricInfo JSON：字段、整首 LRC 优先、翻译/音译只在非空时带', () {
      const fullLrc = '[00:00.00]第一句\n[00:05.00]第二句';
      final extras = _extras(
        lyricText: '第一句',
        translationText: 'first line',
        romanizationText: 'dai yi ju',
        fullLyricLrc: fullLrc,
      );
      final info =
          jsonDecode(extras['lyricInfo'] as String) as Map<String, dynamic>;

      expect(info['songName'], '晴天');
      expect(info['artist'], '周杰伦');
      expect(info['album'], '叶惠美');
      expect(info['songId'], 'id_1');
      expect(info['lyric'], fullLrc, reason: 'LyricInfo 的 lyric 优先整首 LRC');
      expect(info['translation'], 'first line');
      expect(info['roma'], 'dai yi ju');
      expect(
        info.keys.last,
        'lyric',
        reason: 'lyric 必须是末位字段：车机傻瓜解析只会多带出固定长度的 "}"',
      );
    });

    test('lyricInfo JSON：album 为空不带，songId 回退 hash，无翻译/音译不带键', () {
      final extras = _extras(
        song: _song(id: '', albumName: ''),
        lyricText: '第一句',
      );
      final info =
          jsonDecode(extras['lyricInfo'] as String) as Map<String, dynamic>;

      expect(info.containsKey('album'), isFalse);
      expect(info['songId'], 'hash_1', reason: 'id 为空时 LyricInfo 用 hash 兜底');
      expect(info.containsKey('translation'), isFalse);
      expect(info.containsKey('roma'), isFalse);
      expect(info['lyric'], '第一句', reason: '没有整首 LRC 时退回当前行');
    });

    test('清空（全 null）：只剩 hash/songId，歌词与 lyricInfo 全部消失', () {
      final extras = _extras();
      expect(extras, {'hash': 'hash_1', 'songId': 'id_1'});
    });

    test('空串歌词归一化为「无内容」：不写 lyric 字段与 lyricInfo', () {
      final extras = _extras(
        lyricText: '',
        translationText: '',
        romanizationText: '',
      );
      expect(extras.containsKey('lyric'), isFalse);
      expect(extras.containsKey('currentLyric'), isFalse);
      expect(extras.containsKey('translationLyric'), isFalse);
      expect(extras.containsKey('romanLyric'), isFalse);
      expect(extras.containsKey('lyricInfo'), isFalse);
    });

    test('只有整首 LRC（间奏空行）时仍生成 lyricInfo，保留滚动歌词', () {
      const fullLrc = '[00:00.00]第一句\n[00:05.00]\n[00:10.00]第三句';
      final extras = _extras(fullLyricLrc: fullLrc);

      expect(extras.containsKey('lyric'), isFalse, reason: '没有当前行');
      expect(extras.containsKey('currentLyric'), isFalse);
      expect(
        extras.containsKey('org.akanework.lyricinfo.CURRENT_LYRIC'),
        isFalse,
      );
      expect(extras['full_lrc'], fullLrc);
      final info =
          jsonDecode(extras['lyricInfo'] as String) as Map<String, dynamic>;
      expect(info['lyric'], fullLrc);
    });

    test('fullLrc 为空串视同没有：不写 full_lrc 协议字段', () {
      final extras = _extras(lyricText: '第一句', fullLyricLrc: '');
      expect(extras.containsKey('full_lrc'), isFalse);
      expect(
        extras.containsKey('org.akanework.lyricinfo.FULL_LYRICS'),
        isFalse,
      );
      expect(extras['lyricInfo'], isNotNull);
    });

    // issue #22 二次排查：车机歌词槽只认纯文本、且要自己按进度滚动，
    // 因此 extras 需要「去时间标签的整首纯文本」+ 播放进度快照。
    test('整首 LRC 同时派发纯文本 lyrics（车机只认纯文本时不显示标签乱码）', () {
      const fullLrc = '[00:00.00]第一句\n[00:05.00]\n[00:10.00]第三句';
      final extras = _extras(lyricText: '第一句', fullLyricLrc: fullLrc);

      expect(extras['full_lrc'], fullLrc, reason: '带标签的整首 LRC 仍保留');
      expect(
        extras['lyrics'],
        '第一句\n\n第三句',
        reason: '纯文本版保留间奏空行，行序与 LRC 对齐',
      );
    });

    test('播放进度快照写进 extras：position/duration/playing', () {
      final extras = _extras(
        lyricText: '第一句',
        fullLyricLrc: '[00:00.00]第一句',
        positionMs: 12345,
        durationMs: 269000,
        playing: true,
      );

      expect(extras['position'], 12345);
      expect(extras['duration'], 269000);
      expect(extras['playing'], isTrue);
    });

    test('未提供进度快照时不写进度字段（清空/暂停不残留旧位置）', () {
      final extras = _extras(lyricText: '第一句');
      expect(extras.containsKey('position'), isFalse);
      expect(extras.containsKey('duration'), isFalse);
      expect(extras.containsKey('playing'), isFalse);
    });
  });

  group('MusicAudioHandler.buildLyricMediaTitle', () {
    test('开关关闭：title 恒为歌名', () {
      expect(
        MusicAudioHandler.buildLyricMediaTitle(song: _song(), lyricText: '第一句'),
        '晴天',
      );
    });

    test('开关开启且当前行非空：title = 当前歌词行', () {
      expect(
        MusicAudioHandler.buildLyricMediaTitle(
          song: _song(),
          lyricText: '第一句',
          bluetoothLyricsTitleSync: true,
        ),
        '第一句',
      );
    });

    test('开关开启但当前行为空/null：回落歌名（暂停/清空/间奏）', () {
      expect(
        MusicAudioHandler.buildLyricMediaTitle(
          song: _song(),
          lyricText: '',
          bluetoothLyricsTitleSync: true,
        ),
        '晴天',
      );
      expect(
        MusicAudioHandler.buildLyricMediaTitle(
          song: _song(),
          bluetoothLyricsTitleSync: true,
        ),
        '晴天',
      );
    });
  });

  group('MusicAudioHandler.buildLyricMediaItem', () {
    test('id/封面/时长与歌曲一致，extras 走歌词构建', () {
      final item = MusicAudioHandler.buildLyricMediaItem(
        song: _song(
          coverUrl: 'https://example.com/cover.jpg',
          duration: const Duration(seconds: 269),
        ),
        lyricText: '第一句',
        fullLyricLrc: '[00:00.00]第一句',
      );

      expect(item.id, 'hash_1');
      expect(item.album, '叶惠美');
      expect(item.title, '晴天');
      expect(item.artist, '周杰伦');
      expect(item.duration, const Duration(seconds: 269));
      expect(item.artUri, Uri.parse('https://example.com/cover.jpg'));
      expect(item.extras!['lyric'], '第一句');
      expect(item.extras!['full_lrc'], '[00:00.00]第一句');
    });

    test('hash 为空时 id 回退歌曲 id（云盘/边缘接口歌曲）', () {
      final item = MusicAudioHandler.buildLyricMediaItem(
        song: _song(hash: ''),
        lyricText: '第一句',
      );
      expect(item.id, 'id_1');
    });

    test('无封面时 artUri 为 null，标题覆盖随开关生效', () {
      final item = MusicAudioHandler.buildLyricMediaItem(
        song: _song(),
        lyricText: '第一句',
        bluetoothLyricsTitleSync: true,
      );
      expect(item.artUri, isNull);
      expect(item.title, '第一句');
    });

    test('本地内嵌封面：未给出落盘 URI 时伪 URL 不下发', () {
      // `localart://` 只在本进程内有效，系统媒体会话解析不了。
      final song = _song(
        coverUrl: LocalArtworkService.artworkUrlFor('/m/a.flac'),
      );
      final item = MusicAudioHandler.buildLyricMediaItem(
        song: song,
        lyricText: '第一句',
      );

      expect(item.artUri, isNull);
      expect(MusicAudioHandler.systemArtUriFallback(song), isNull);
      // 在线封面走同一条兜底规则时原样透传。
      expect(
        MusicAudioHandler.systemArtUriFallback(
          _song(coverUrl: 'https://example.com/c.jpg'),
        ),
        Uri.parse('https://example.com/c.jpg'),
      );
    });

    test('本地封面落盘后：显式传入的 file URI 原样下发（issue #34）', () {
      final song = _song(
        coverUrl: LocalArtworkService.artworkUrlFor('/m/a.flac'),
      );
      final fileUri = Uri.file('/cache/a.jpg');

      final item = MusicAudioHandler.buildLyricMediaItem(
        song: song,
        lyricText: '第一句',
        artUri: fileUri,
      );

      expect(item.artUri, fileUri);
      expect(item.title, '晴天');
    });
  });
}
