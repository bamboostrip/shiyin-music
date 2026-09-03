import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  group('cleanSongTitle', () {
    test('单歌手完全匹配前缀，剥离歌手名与分隔符', () {
      expect(
        cleanSongTitle('周杰伦 - 晴天', artist: '周杰伦'),
        '晴天',
      );
    });

    test('多歌手匹配（如斜杠或顿号分隔），正确剥离歌手名', () {
      expect(
        cleanSongTitle('周杰伦 / 阿信 - 说好不哭', artist: '周杰伦 / 阿信'),
        '说好不哭',
      );
      expect(
        cleanSongTitle('周杰伦、阿信 - 说好不哭', artist: '周杰伦 / 阿信'),
        '说好不哭',
      );
      expect(
        cleanSongTitle('周杰伦,阿信 - 说好不哭', artist: '周杰伦 / 阿信'),
        '说好不哭',
      );
    });

    test('支持多歌手引用列表 (artists)', () {
      expect(
        cleanSongTitle(
          '周杰伦 - 千里之外',
          artist: '周杰伦 / 费玉清',
          artists: const [
            ArtistRef(id: '1', name: '周杰伦'),
            ArtistRef(id: '2', name: '费玉清'),
          ],
        ),
        '千里之外',
      );
    });

    test('歌名带 Live 或版本后缀，正确保留后缀', () {
      expect(
        cleanSongTitle('告五人 - 唯一 (Live)', artist: '告五人'),
        '唯一 (Live)',
      );
    });

    test('不同类型的破折号（—, –）都能正确识别并剥离', () {
      expect(
        cleanSongTitle('林俊杰 — 修炼爱情', artist: '林俊杰'),
        '修炼爱情',
      );
      expect(
        cleanSongTitle('林俊杰 – 江南', artist: '林俊杰'),
        '江南',
      );
    });

    test('非歌手前缀的连字符歌名不误切', () {
      expect(
        cleanSongTitle('Part 1 - The Beginning', artist: 'Pink Floyd'),
        'Part 1 - The Beginning',
      );
      expect(
        cleanSongTitle('晴天 - 伴奏', artist: '周杰伦'),
        '晴天 - 伴奏',
      );
      expect(
        cleanSongTitle('Love-Song', artist: 'The Band'),
        'Love-Song',
      );
    });

    test('无艺人或未知艺人时，符合 A - B 规范格式时提取 B 为纯歌名', () {
      expect(
        cleanSongTitle('陈奕迅 - 十年', artist: '未知艺人'),
        '十年',
      );
      expect(
        cleanSongTitle('陈奕迅 - 十年', artist: null),
        '十年',
      );
    });

    test('空值与边界情况', () {
      expect(cleanSongTitle(null), '未知歌曲');
      expect(cleanSongTitle(''), '未知歌曲');
      expect(cleanSongTitle('   '), '未知歌曲');
      expect(cleanSongTitle('晴天', artist: '周杰伦'), '晴天');
    });
  });
}
