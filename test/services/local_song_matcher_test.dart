import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/local_song_matcher.dart';

/// 移植自上游 kgka_Music_hl 3.2.0（`87c35a1` / `dc92cfd`）。
///
/// 覆盖本地歌曲元数据清洗与酷狗同名歌曲打分匹配的硬性规则：
/// 未知值归空、文件名拆分、「歌手 - 」前缀剥离、标题严格相等、
/// 未知歌手需时长接近（≤3s）、已知歌手时长差 >8s 丢弃、按时长差排序、
/// 非酷狗/空 hash 过滤，以及 Live/伴奏/Remix 等版本词不被吞掉。
Song kugou({
  String id = 'online-id',
  required String title,
  required String artist,
  String hash = 'ONLINE_HASH',
  Duration? duration,
}) => Song(
  id: id,
  title: title,
  artist: artist,
  hash: hash,
  duration: duration,
);

Song local({
  String id = '/Music/Test Artist - Test Song.mp3',
  required String title,
  required String artist,
  Duration? duration,
  String hash = 'local-hash',
}) => Song(
  id: id,
  title: title,
  artist: artist,
  hash: hash,
  duration: duration,
  source: SongSource.local,
);

void main() {
  group('LocalSongIdentity.fromSong', () {
    test('未知歌手归空，已知标题保持', () {
      final identity = LocalSongIdentity.fromSong(
        local(title: 'Test Song', artist: '未知艺人'),
      );
      expect(identity.title, 'Test Song');
      expect(identity.artist, '');
      expect(identity.query, 'Test Song');
    });

    test('未知标题退化为文件名并按「歌手 - 歌名」拆分', () {
      final identity = LocalSongIdentity.fromSong(
        local(
          id: '/Music/Test Artist - Test Song.flac',
          title: '未知歌曲',
          artist: '<unknown>',
        ),
      );
      expect(identity.title, 'Test Song');
      expect(identity.artist, 'Test Artist');
      expect(identity.query, 'Test Artist Test Song');
      expect(identity.isSearchable, isTrue);
    });

    test('标题中的「歌手 - 」前缀被剥离', () {
      final identity = LocalSongIdentity.fromSong(
        local(title: 'Test Artist - Test Song', artist: 'Test Artist'),
      );
      expect(identity.title, 'Test Song');
      expect(identity.artist, 'Test Artist');
    });

    test('多歌手前缀可被剥离', () {
      final identity = LocalSongIdentity.fromSong(
        local(title: 'A / B - Test Song', artist: 'A / B'),
      );
      expect(identity.title, 'Test Song');
    });

    test('文件名扩展名不参与匹配', () {
      final identity = LocalSongIdentity.fromSong(
        local(
          id: '/Music/Test Artist - Test Song.MP3',
          title: '未知歌曲',
          artist: '未知歌手',
        ),
      );
      expect(identity.title, 'Test Song');
      expect(identity.query, 'Test Artist Test Song');
    });

    test('「歌手 - 歌名」型标题且无歌手信息时拆分', () {
      final identity = LocalSongIdentity.fromSong(
        local(title: 'Test Artist - Test Song', artist: ''),
      );
      expect(identity.title, 'Test Song');
      expect(identity.artist, 'Test Artist');
    });

    test('纯文件名（无分隔符）保持整名', () {
      final identity = LocalSongIdentity.fromSong(
        local(
          id: '/Music/Test Song.mp3',
          title: '未知歌曲',
          artist: '',
        ),
      );
      expect(identity.title, 'Test Song');
      expect(identity.artist, '');
    });
  });

  group('LocalSongIdentity.matchCandidates', () {
    final identity = LocalSongIdentity(
      'Test Song',
      'Test Artist',
      const Duration(seconds: 180),
    );

    test('标题 normalize 后完全相等才匹配', () {
      expect(
        identity.matchCandidates([
          kugou(title: 'Test Song', artist: 'Test Artist'),
        ]),
        hasLength(1),
      );
      expect(
        identity.matchCandidates([
          kugou(title: 'Test Song (Live)', artist: 'Test Artist'),
        ]),
        isEmpty,
      );
      expect(
        identity.matchCandidates([
          kugou(title: 'Test Song 2', artist: 'Test Artist'),
        ]),
        isEmpty,
      );
    });

    test('标点/空白差异不影响标题匹配', () {
      expect(
        identity.matchCandidates([
          kugou(title: 'Test-Song', artist: 'Test Artist'),
        ]),
        hasLength(1),
      );
    });

    test('Live/伴奏/Remix 等版本词保留（不与原版互相匹配）', () {
      for (final suffix in ['Live', '伴奏', 'Remix']) {
        expect(
          identity.matchCandidates([
            kugou(title: 'Test Song ($suffix)', artist: 'Test Artist'),
          ]),
          isEmpty,
          reason: '版本词 $suffix 应保留',
        );
      }
    });

    test('候选歌手需包含全部期望歌手', () {
      expect(
        identity.matchCandidates([
          kugou(title: 'Test Song', artist: 'Other Artist'),
        ]),
        isEmpty,
      );
      expect(
        identity.matchCandidates([
          kugou(title: 'Test Song', artist: 'Test Artist / Other Artist'),
        ]),
        hasLength(1),
      );
    });

    test('非酷狗来源与空 hash 一律过滤', () {
      expect(
        identity.matchCandidates([
          Song(
            id: 'ne',
            title: 'Test Song',
            artist: 'Test Artist',
            hash: 'ne_1',
            source: SongSource.netease,
          ),
          kugou(title: 'Test Song', artist: 'Test Artist', hash: ''),
        ]),
        isEmpty,
      );
    });

    test('重复 hash 只保留一条', () {
      final matches = identity.matchCandidates([
        kugou(title: 'Test Song', artist: 'Test Artist'),
        kugou(id: 'dup', title: 'Test Song', artist: 'Test Artist'),
      ]);
      expect(matches, hasLength(1));
    });

    test('已知歌手：时长差 >8s 丢弃，≤8s 保留', () {
      final close = kugou(
        id: 'close',
        hash: 'HASH_CLOSE',
        title: 'Test Song',
        artist: 'Test Artist',
        duration: const Duration(seconds: 185),
      );
      final far = kugou(
        id: 'far',
        hash: 'HASH_FAR',
        title: 'Test Song',
        artist: 'Test Artist',
        duration: const Duration(seconds: 200),
      );
      expect(identity.matchCandidates([far, close]), [close]);
    });

    test('未知歌手：无时长或时长差 >3s 丢弃', () {
      const unknown = LocalSongIdentity('Test Song', '', null);
      expect(
        unknown.matchCandidates([kugou(title: 'Test Song', artist: 'A')]),
        isEmpty,
      );
      expect(
        LocalSongIdentity(
          'Test Song',
          '',
          const Duration(seconds: 180),
        ).matchCandidates([
          kugou(
            title: 'Test Song',
            artist: 'A',
            duration: const Duration(seconds: 184),
          ),
        ]),
        isEmpty,
      );
      final matched = kugou(
        title: 'Test Song',
        artist: 'A',
        duration: const Duration(seconds: 183),
      );
      expect(
        LocalSongIdentity(
          'Test Song',
          '',
          const Duration(seconds: 180),
        ).matchCandidates([matched]),
        [matched],
      );
    });

    test('按时长差升序返回', () {
      final second = kugou(
        id: 'second',
        hash: 'HASH_SECOND',
        title: 'Test Song',
        artist: 'Test Artist',
        duration: const Duration(seconds: 183),
      );
      final first = kugou(
        id: 'first',
        hash: 'HASH_FIRST',
        title: 'Test Song',
        artist: 'Test Artist',
        duration: const Duration(seconds: 180),
      );
      final third = kugou(
        id: 'third',
        hash: 'HASH_THIRD',
        title: 'Test Song',
        artist: 'Test Artist',
        duration: const Duration(seconds: 187),
      );
      final matches = identity.matchCandidates([third, second, first]);
      expect(matches.map((song) => song.id), ['first', 'second', 'third']);
    });

    test('未知标题不可搜索', () {
      const identity = LocalSongIdentity('未知歌曲', '', null);
      expect(identity.isSearchable, isFalse);
      expect(identity.matchCandidates([kugou(title: '未知歌曲', artist: 'A')]),
          isEmpty);
    });
  });

  group('stripArtistNamePrefix', () {
    test('单歌手', () {
      expect(stripArtistNamePrefix('A - Song', 'A'), 'Song');
    });
    test('多歌手写法', () {
      expect(stripArtistNamePrefix('A / B - Song', 'A / B'), 'Song');
      expect(stripArtistNamePrefix('A、B - Song', 'A / B'), 'Song');
    });
    test('无前缀时原样返回', () {
      expect(stripArtistNamePrefix('Song', 'A'), 'Song');
      expect(stripArtistNamePrefix('A - Song', ''), 'A - Song');
    });
    test('前缀后为空时不剥离', () {
      expect(stripArtistNamePrefix('A - ', 'A'), 'A - ');
    });
  });
}
