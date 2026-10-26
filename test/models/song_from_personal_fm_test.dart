// 私人 FM（酷狗官方「猜你喜欢」）单曲解析：字段来自上游 .NET 后端
// PersonalFmSong（见 api.json），本 fork 由 Rust 引擎透传同形 data。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  group('Song.fromPersonalFm', () {
    test('解析完整字段：hash/songid/mixsongid/时长/封面/歌手', () {
      final song = Song.fromPersonalFm({
        'songname': '晴天',
        'author_name': '周杰伦',
        'hash': 'HASH_001',
        'time_length': 269,
        'album_id': 'ALB_1',
        'songid': 1001,
        'mixsongid': '2002',
        'trans_param': {'union_cover': 'http://img.kugou.com/{size}/cover.jpg'},
        'singerinfo': [
          {'id': '9001', 'name': '周杰伦'},
        ],
      });

      expect(song.id, '1001');
      expect(song.title, '晴天');
      expect(song.rawTitle, '晴天');
      expect(song.artist, '周杰伦');
      expect(song.hash, 'HASH_001');
      expect(song.albumId, 'ALB_1');
      expect(song.albumAudioId, '2002');
      expect(song.duration, const Duration(seconds: 269));
      expect(song.coverUrl, 'http://img.kugou.com/480/cover.jpg');
      expect(song.artists.single.id, '9001');
      expect(song.artists.single.name, '周杰伦');
    });

    test('字段缺失时降级：id 回退 hash，时长/封面为空，歌名兜底', () {
      final song = Song.fromPersonalFm({'hash': 'HASH_ONLY'});

      expect(song.id, 'HASH_ONLY');
      expect(song.hash, 'HASH_ONLY');
      expect(song.title, '未知歌曲');
      expect(song.artist, '未知艺人');
      expect(song.duration, isNull);
      expect(song.coverUrl, isNull);
    });

    test('作者名作为歌手兜底；封面优先 union_cover', () {
      final song = Song.fromPersonalFm({
        'songname': '海阔天空',
        'author_name': 'Beyond',
        'hash': 'HASH_002',
        'trans_param': {'union_cover': 'http://img.kugou.com/{size}/union.jpg'},
        'sizable_cover': 'http://img.kugou.com/{size}/other.jpg',
      });

      expect(song.artist, 'Beyond');
      expect(song.coverUrl, 'http://img.kugou.com/480/union.jpg');
    });
  });
}
