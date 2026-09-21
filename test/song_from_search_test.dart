import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  /// 构造酷狗 /search 形态的歌曲数据（字段按需裁剪，覆盖有/无 OriSongName）。
  Map<String, dynamic> searchSong({
    String fileHash = 'HASH123',
    String? fileName = '汪峰 - 春天里',
    String? songname,
    String singerName = '汪峰',
    List<Map<String, dynamic>>? singers,
    String? oriSongName = '春天里',
    String suffix = '',
  }) {
    final result = <String, dynamic>{
      'FileHash': fileHash,
      'MixSongID': '32217207',
      'SingerName': singerName,
      'Suffix': suffix,
      'Duration': 279,
    };
    if (fileName != null) result['FileName'] = fileName;
    if (songname != null) result['songname'] = songname;
    if (singers != null) result['Singers'] = singers;
    if (oriSongName != null) result['OriSongName'] = oriSongName;
    return result;
  }

  group('Song.fromSearch（OriSongName 首选）', () {
    test('OriSongName + Suffix 拼出完整歌名', () {
      final song = Song.fromSearch(
        searchSong(
          fileName: 'G.E.M.邓紫棋、方大同 - 春天里 (Live)',
          singerName: 'G.E.M.邓紫棋、方大同',
          singers: [
            {'id': '4490', 'name': 'G.E.M.邓紫棋'},
            {'id': '877', 'name': '方大同'},
          ],
          suffix: '(Live)',
        ),
      );
      expect(song.title, '春天里 (Live)');
      expect(song.rawTitle, '春天里 (Live)');
      expect(song.artist, 'G.E.M.邓紫棋 / 方大同');
    });

    test('Suffix 为空时歌名无多余空格', () {
      final song = Song.fromSearch(searchSong());
      expect(song.title, '春天里');
    });

    test('缺失 OriSongName 时回退备选字段并剥离歌手前缀', () {
      final song = Song.fromSearch(
        searchSong(oriSongName: null),
      );
      expect(song.title, '春天里');
    });

    test('无 OriSongName 且无 songname 时从 FileName 剥离', () {
      final song = Song.fromSearch(
        searchSong(
          oriSongName: null,
          fileName: '周杰伦 - 晴天',
          singerName: '周杰伦',
        ),
      );
      expect(song.title, '晴天');
    });

    test('兜底剥离不误伤歌名本身含连字符的内容', () {
      final song = Song.fromSearch(
        searchSong(
          fileName: '汪峰 - 爱情 - Live版',
          oriSongName: null,
        ),
      );
      expect(song.title, '爱情 - Live版');
    });

    test('前缀与歌手名不一致时不剥离', () {
      final song = Song.fromSearch(
        searchSong(
          fileName: '旭日阳刚 - 春天里',
          singerName: '汪峰',
          oriSongName: null,
        ),
      );
      expect(song.title, '旭日阳刚 - 春天里');
    });

    test('所有歌名字段缺失时回退「未知歌曲」', () {
      final song = Song.fromSearch(
        searchSong(oriSongName: null, fileName: null),
      );
      expect(song.title, '未知歌曲');
    });
  });
}
