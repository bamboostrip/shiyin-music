// 每日推荐（/recommend/songs 类接口）单曲解析：
// 上游 3.3.0 #156 附带改动 backport——album_audio_id 优先于 mixsongid/songid，
// 时长回退链 topCardSeconds ?? seconds ?? timelen(ms) ?? timelength(ms)。
// 非空值路径必须与既有语义一致（id 取 mixsongid 优先、hash 多级兜底等）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  group('Song.fromDaily album_audio_id / 时长回退（3.3.0）', () {
    test('album_audio_id 优先于 mixsongid/songid，其余字段语义不变', () {
      final song = Song.fromDaily({
        'songname': '晴天',
        'author_name': '周杰伦',
        'hash': 'HASH_001',
        'songid': 1001,
        'mixsongid': '2002',
        'album_audio_id': 'AAID_9',
        'album_id': 'ALB_1',
        'album_name': '叶惠美',
        'sizable_cover': 'http://img.kugou.com/{size}/cover.jpg',
        'time_length': 259.16,
      });

      // 播放地址参数取 album_audio_id。
      expect(song.albumAudioId, 'AAID_9');
      // 既有语义不变：id 仍取 mixsongid 优先。
      expect(song.id, '2002');
      expect(song.hash, 'HASH_001');
      expect(song.title, '晴天');
      expect(song.rawTitle, '晴天');
      expect(song.artist, '周杰伦');
      expect(song.albumId, 'ALB_1');
      expect(song.albumName, '叶惠美');
      expect(song.coverUrl, 'http://img.kugou.com/480/cover.jpg');
      expect(song.duration, const Duration(milliseconds: 259160));
    });

    test('album_audio_id 缺失回退 mixsongid，再缺失回退 songid/audio_id', () {
      final byMix = Song.fromDaily({
        'songname': '晴天',
        'hash': 'HASH_001',
        'songid': 1001,
        'mixsongid': '2002',
      });
      expect(byMix.albumAudioId, '2002');

      final bySong = Song.fromDaily({
        'songname': '晴天',
        'hash': 'HASH_001',
        'songid': 3003,
      });
      expect(bySong.albumAudioId, '3003');

      // audio_id 是 songId 的备选字段，同样参与兜底。
      final byAudioId = Song.fromDaily({
        'songname': '晴天',
        'hash': 'HASH_001',
        'audio_id': '4004',
      });
      expect(byAudioId.albumAudioId, '4004');

      final none = Song.fromDaily({'songname': '晴天', 'hash': 'HASH_001'});
      expect(none.albumAudioId, isNull);
    });

    test('时长回退：小数秒 time_length 优先于 timelen 毫秒', () {
      final both = Song.fromDaily({
        'songname': '晴天',
        'hash': 'HASH_001',
        'time_length': 269.5,
        'timelen': 999999,
      });
      expect(both.duration, const Duration(milliseconds: 269500));
    });

    test('时长回退：time_length 缺失/异形时用 timelen（毫秒）', () {
      final ms = Song.fromDaily({
        'songname': '晴天',
        'hash': 'HASH_001',
        'timelen': 259160,
      });
      expect(ms.duration, const Duration(milliseconds: 259160));

      // 异形 time_length 不生效，继续回退 timelen，而不是被截成 0。
      final odd = Song.fromDaily({
        'songname': '晴天',
        'hash': 'HASH_001',
        'time_length': '--',
        'timelen': '87000',
      });
      expect(odd.duration, const Duration(milliseconds: 87000));
    });

    test('时长回退：timelen 缺失时最后一档 timelength（毫秒）', () {
      final song = Song.fromDaily({
        'songname': '晴天',
        'hash': 'HASH_001',
        'timelength': 326420,
      });
      expect(song.duration, const Duration(milliseconds: 326420));
    });

    test('时长全缺失/null 保持 null，不产生 0 时长', () {
      expect(
        Song.fromDaily({'songname': '晴天', 'hash': 'HASH_001'}).duration,
        isNull,
      );
      expect(
        Song.fromDaily({
          'songname': '晴天',
          'hash': 'HASH_001',
          'time_length': '',
          'timelen': null,
          'timelength': '',
        }).duration,
        isNull,
      );
    });
  });
}
