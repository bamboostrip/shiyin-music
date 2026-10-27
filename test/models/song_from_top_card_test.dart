// 首页「推荐歌曲」（/top/card）单曲解析：
// - 字段形态来自上游 3.2.0 f230444（songname / author_name / hash /
//   time_length / album_id / songid / mixsongid / sizable_cover）；
// - time_length 是带小数的秒数（上游 62ae541 修复），需按毫秒解析；
// - 本 fork 无 releaseDate 字段，故不解析该字段。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  group('Song.fromTopCard', () {
    test('解析完整字段：mixsongid 优先 id、小数秒时长、封面归一化', () {
      final song = Song.fromTopCard({
        'songname': '晴天',
        'author_name': '周杰伦',
        'hash': 'HASH_001',
        'time_length': 259.16,
        'album_id': 'ALB_1',
        'album_name': '叶惠美',
        'songid': 1001,
        'mixsongid': '2002',
        'sizable_cover': 'http://img.kugou.com/{size}/cover.jpg',
        'singerinfo': [
          {'singerid': '9001', 'singername': '周杰伦'},
        ],
      });

      // id 取 mixsongid 优先，albumAudioId 同源（播放兜底）。
      expect(song.id, '2002');
      expect(song.albumAudioId, '2002');
      expect(song.title, '晴天');
      expect(song.rawTitle, '晴天');
      expect(song.artist, '周杰伦');
      expect(song.hash, 'HASH_001');
      expect(song.albumId, 'ALB_1');
      expect(song.albumName, '叶惠美');
      // 259.16 秒 → 259160 毫秒（小数秒不能被截成整数分钟）。
      expect(song.duration, const Duration(milliseconds: 259160));
      expect(song.coverUrl, 'http://img.kugou.com/480/cover.jpg');
      expect(song.artists.single.id, '9001');
      expect(song.artists.single.name, '周杰伦');
    });

    test('多歌手：singerinfo 用「 / 」连接，id 回退 songid', () {
      final song = Song.fromTopCard({
        'songname': '北京欢迎你',
        'hash': 'HASH_002',
        'songid': 3003,
        'singerinfo': [
          {'singerid': '1', 'singername': '刘欢'},
          {'singerid': '2', 'singername': '韩红'},
        ],
      });

      expect(song.id, '3003');
      expect(song.albumAudioId, '3003');
      expect(song.artist, '刘欢 / 韩红');
      expect(song.artists.length, 2);
    });

    test('字段缺失时降级：id 回退 hash、时长/封面为空、歌名兜底', () {
      final song = Song.fromTopCard({'hash': 'HASH_ONLY'});

      expect(song.id, 'HASH_ONLY');
      expect(song.hash, 'HASH_ONLY');
      expect(song.title, '未知歌曲');
      expect(song.artist, '未知艺人');
      expect(song.duration, isNull);
      expect(song.coverUrl, isNull);
    });

    test('标题清洗：剥离歌手名前缀，非歌手前缀安全保留', () {
      final stripped = Song.fromTopCard({
        'songname': '周杰伦 - 晴天',
        'author_name': '周杰伦',
        'hash': 'HASH_003',
      });
      expect(stripped.title, '晴天');
      // 原始标题保留，避免二次清洗时信息丢失。
      expect(stripped.rawTitle, '周杰伦 - 晴天');

      final kept = Song.fromTopCard({
        'songname': 'Part 1 - The Beginning',
        'author_name': '某人',
        'hash': 'HASH_004',
      });
      expect(kept.title, 'Part 1 - The Beginning');
    });
  });

  group('durationFromTopCardSeconds', () {
    test('小数秒 → 毫秒（62ae541 修复的行为）', () {
      expect(
        durationFromTopCardSeconds(259.16),
        const Duration(milliseconds: 259160),
      );
      expect(
        durationFromTopCardSeconds('259.16'),
        const Duration(milliseconds: 259160),
      );
      expect(
        durationFromTopCardSeconds(0.5),
        const Duration(milliseconds: 500),
      );
    });

    test('整数秒按毫秒保留精度', () {
      expect(
        durationFromTopCardSeconds(259),
        const Duration(milliseconds: 259000),
      );
    });

    test('空值/非法值返回 null', () {
      expect(durationFromTopCardSeconds(null), isNull);
      expect(durationFromTopCardSeconds(''), isNull);
      expect(durationFromTopCardSeconds('abc'), isNull);
    });
  });

  group('RecommendedSongCard.fromJson', () {
    test('过滤空 hash 歌曲，取首曲封面与 rec_desc', () {
      final card = RecommendedSongCard.fromJson(
        cardId: 3,
        title: '热门好歌精选',
        json: {
          'rec_desc': '根据你的口味精选',
          'song_list': [
            {'songname': '无 hash 的坏数据', 'hash': ''},
            {
              'songname': '晴天',
              'hash': 'HASH_101',
              'sizable_cover': 'http://img.kugou.com/{size}/a.jpg',
            },
            {'songname': '七里香', 'hash': 'HASH_102'},
          ],
        },
      );

      expect(card.cardId, 3);
      expect(card.title, '热门好歌精选');
      expect(card.description, '根据你的口味精选');
      expect(card.songs.map((song) => song.hash), ['HASH_101', 'HASH_102']);
      // 卡片不发封面，取组内第一首有效歌曲的封面。
      expect(card.coverUrl, 'http://img.kugou.com/480/a.jpg');
      expect(card.songSummary, '晴天 · 未知艺人');
    });

    test('空 song_list：歌曲为空、封面为空、songSummary 兜底', () {
      final card = RecommendedSongCard.fromJson(
        cardId: 5,
        title: '潮流尝鲜',
        json: {'song_list': <dynamic>[]},
      );

      expect(card.songs, isEmpty);
      expect(card.coverUrl, isNull);
      expect(card.description, isNull);
      expect(card.songSummary, '推荐歌曲');
    });
  });

  group('RecommendedSongCard 缓存 roundtrip', () {
    test('toCache/fromCache 保留卡片与歌曲字段', () {
      final original = RecommendedSongCard.fromJson(
        cardId: 2,
        title: '经典怀旧金曲',
        json: {
          'rec_desc': '经典老歌',
          'song_list': [
            {
              'songname': '海阔天空',
              'author_name': 'Beyond',
              'hash': 'HASH_201',
              'time_length': 326.42,
              'sizable_cover': 'http://img.kugou.com/{size}/b.jpg',
            },
          ],
        },
      );

      final restored = RecommendedSongCard.fromCache(original.toCache());

      expect(restored.cardId, 2);
      expect(restored.title, '经典怀旧金曲');
      expect(restored.description, '经典老歌');
      expect(restored.coverUrl, 'http://img.kugou.com/480/b.jpg');
      expect(restored.songs.single.hash, 'HASH_201');
      expect(restored.songs.single.title, '海阔天空');
      expect(
        restored.songs.single.duration,
        const Duration(milliseconds: 326420),
      );
    });
  });

  // 上游 3.3.0 #156 附带：album_audio_id 优先 + 时长回退链（本 fork backport）。
  group('Song.fromTopCard album_audio_id / 时长回退（3.3.0）', () {
    test('album_audio_id 优先于 mixsongid/songid；id 语义不变', () {
      final song = Song.fromTopCard({
        'songname': '晴天',
        'hash': 'HASH_001',
        'songid': 1001,
        'mixsongid': '2002',
        'album_audio_id': 'AAID_9',
      });

      // 播放地址参数用 album_audio_id；歌曲身份 id 仍保持 mixsongid 优先。
      expect(song.albumAudioId, 'AAID_9');
      expect(song.id, '2002');
    });

    test('album_audio_id 缺失回退 mixsongid，再缺失回退 songid', () {
      final byMix = Song.fromTopCard({
        'songname': '晴天',
        'hash': 'HASH_001',
        'songid': 1001,
        'mixsongid': '2002',
      });
      expect(byMix.albumAudioId, '2002');

      final bySong = Song.fromTopCard({
        'songname': '晴天',
        'hash': 'HASH_001',
        'songid': 3003,
      });
      expect(bySong.albumAudioId, '3003');

      // 三个字段全缺失时保持 null（不得写成空串，music_api 依赖 null 省略参数）。
      final none = Song.fromTopCard({'songname': '晴天', 'hash': 'HASH_001'});
      expect(none.albumAudioId, isNull);
    });

    test('album_audio_id 为空串视为缺失', () {
      final song = Song.fromTopCard({
        'songname': '晴天',
        'hash': 'HASH_001',
        'songid': 1001,
        'mixsongid': '2002',
        'album_audio_id': '   ',
      });

      expect(song.albumAudioId, '2002');
    });

    test('时长回退：time_length 优先，其次 timelen 毫秒', () {
      // 两者都有时 time_length（小数秒）优先。
      final both = Song.fromTopCard({
        'songname': '晴天',
        'hash': 'HASH_001',
        'time_length': 259.16,
        'timelen': 999999,
      });
      expect(both.duration, const Duration(milliseconds: 259160));

      // time_length 缺失时用 timelen（毫秒，不是秒）。
      final ms = Song.fromTopCard({
        'songname': '晴天',
        'hash': 'HASH_001',
        'timelen': 199000,
      });
      expect(ms.duration, const Duration(seconds: 199));

      // 全缺失/null 时保持 null。
      expect(
        Song.fromTopCard({'songname': '晴天', 'hash': 'HASH_001'}).duration,
        isNull,
      );
    });

    test('时长容错：time_length 为整数或数字字符串仍按毫秒精度解析', () {
      expect(
        Song.fromTopCard({'hash': 'H1', 'time_length': 259}).duration,
        const Duration(milliseconds: 259000),
      );
      expect(
        Song.fromTopCard({'hash': 'H2', 'time_length': '259.16'}).duration,
        const Duration(milliseconds: 259160),
      );
      // time_length 异形（非数字）时回退 timelen。
      expect(
        Song.fromTopCard({
          'hash': 'H3',
          'time_length': '--',
          'timelen': 87000,
        }).duration,
        const Duration(milliseconds: 87000),
      );
    });
  });
}
