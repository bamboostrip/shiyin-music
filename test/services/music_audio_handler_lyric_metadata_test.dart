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
}) {
  return MusicAudioHandler.buildLyricMediaExtras(
    song: song ?? _song(),
    lyricText: lyricText,
    translationText: translationText,
    romanizationText: romanizationText,
    fullLyricLrc: fullLyricLrc,
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
  });
}
