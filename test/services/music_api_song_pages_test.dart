// 歌单/专辑曲目分页的「原始条数」口径（issue #6-1）：
// 上游会下发无 hash（下架/无版权）曲目，playlistSongPage/albumSongPage 的
// songs 只保留可播放曲目，但：
//   - rawItemCount 必须保留原始条数（分页判末页不能按过滤后长度，
//     否则满页无 hash 会提前截断）；
//   - allSongs 必须保留原始顺序（设置开启时列表可置灰展示下架曲目）；
//   - 歌单详情页用「累计原始条数 - 可播放条数」向用户解释元信息 count 差。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 播放列表原始条目：前 [hashlessCount] 条无 hash（模拟下架/无版权）。
List<Map<String, dynamic>> _playlistItems(int total, {int hashlessCount = 0}) {
  return List.generate(total, (index) {
    final hasHash = index >= hashlessCount;
    return <String, dynamic>{
      'name': '歌曲$index',
      'fileid': index,
      'timelen': 180000,
      if (hasHash) 'hash': 'hash_$index',
    };
  });
}

/// 专辑原始条目：前 [hashlessCount] 条无 hash。
List<Map<String, dynamic>> _albumItems(int total, {int hashlessCount = 0}) {
  return List.generate(total, (index) {
    final hasHash = index >= hashlessCount;
    return <String, dynamic>{
      'base': {
        'audio_name': '歌曲$index',
        'author_name': '歌手',
        'album_id': 'album_1',
      },
      'audio_info': {
        if (hasHash) 'hash': 'hash_$index',
        'duration': 180000,
      },
      'album_info': {'album_name': '专辑', 'cover': 'https://example.com/c.jpg'},
    };
  });
}

class _FakeSongPageApiClient implements ApiClientInterface {
  _FakeSongPageApiClient({required this.playlistItems, required this.albumItems});

  final List<Map<String, dynamic>> playlistItems;
  final List<Map<String, dynamic>> albumItems;

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(
    String path, [
    Map<String, Object?> query = const {},
  ]) async {
    final page = (query['page'] as int?) ?? 1;
    final pageSize = (query['pagesize'] as int?) ?? 80;
    final start = (page - 1) * pageSize;
    switch (path) {
      case '/playlist/track/all':
        return <String, dynamic>{
          'songs': playlistItems.skip(start).take(pageSize).toList(),
        };
      case '/playlist/track/all/new':
        // cloudlist：已下架曲仍保留用户收藏时的文件名（形如「歌手 - 歌名.mp3」）。
        final info = playlistItems
            .map(
              (item) => <String, dynamic>{
                'fileid': item['fileid'],
                'name': '歌手 - ${item['name']}.mp3',
                'singerinfo': [
                  {'id': 0, 'name': ''},
                ],
                'timelen': item['timelen'],
              },
            )
            .toList();
        return <String, dynamic>{
          'count': info.length,
          'info': info.skip(start).take(pageSize).toList(),
        };
      case '/album/songs':
        return albumItems.skip(start).take(pageSize).toList();
      default:
        throw ArgumentError('Unexpected path: $path');
    }
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

void main() {
  group('歌单曲目分页的原始条数口径', () {
    late MusicApi api;

    setUp(() {
      api = MusicApi(
        _FakeSongPageApiClient(
          // 530 首原始曲目，其中前 9 首无 hash（模拟下架/无版权）。
          playlistItems: _playlistItems(530, hashlessCount: 9),
          // 120 首专辑曲目，其中前 3 首无 hash。
          albumItems: _albumItems(120, hashlessCount: 3),
        ),
      );
    });

    test('playlistSongPage：songs 过滤无 hash，allSongs 保留原始顺序', () async {
      final page = await api.playlistSongPage('pl_1', page: 1, pageSize: 50);

      expect(page.rawItemCount, 50);
      expect(page.songs.length, 41);
      expect(page.songs.every((song) => song.hash.isNotEmpty), isTrue);
      expect(page.unavailableCount, 9);

      // 展示层依赖的原始顺序：前 9 条是无 hash 下架曲，不能被挪到末尾。
      expect(page.orderedSongs.length, 50);
      expect(
        page.orderedSongs.take(9).every((song) => song.hash.isEmpty),
        isTrue,
      );
      expect(page.orderedSongs[9].hash, 'hash_9');
      expect(page.orderedSongs.first.title, '歌曲0');
    });

    test('playlistSongsPageAll：翻满所有页并累计原始条数', () async {
      final page = await api.playlistSongsPageAll('pl_1');

      expect(page.rawItemCount, 530);
      expect(page.songs.length, 521);
      expect(page.orderedSongs.length, 530);
      expect(
        page.orderedSongs.where((song) => song.hash.isEmpty).length,
        9,
      );
    });

    test('playlistSongs(fetchAll:true) 行为不变：返回全部可播放曲目', () async {
      final songs = await api.playlistSongs('pl_1', fetchAll: true);

      expect(songs.length, 521);
    });

    test('albumSongsPageAll：songs 过滤无 hash，allSongs 保留原始顺序', () async {
      final page = await api.albumSongsPageAll('album_1');

      expect(page.rawItemCount, 120);
      expect(page.songs.length, 117);
      expect(page.orderedSongs.length, 120);
      expect(
        page.orderedSongs.take(3).every((song) => song.hash.isEmpty),
        isTrue,
      );
      expect(page.orderedSongs[3].hash, 'hash_3');
    });

    test('albumSongs：翻满所有页返回可播放曲目', () async {
      final songs = await api.albumSongs('album_1');

      expect(songs.length, 117);
    });

    test('includeShieldedMeta：下架曲用 cloudlist 文件名补全歌名/歌手，hash 仍为空', () async {
      final page = await api.playlistSongPage(
        'collection_3_1_99_0',
        page: 1,
        pageSize: 50,
        includeShieldedMeta: true,
        listId: '99',
      );

      expect(page.rawItemCount, 50);
      expect(page.songs.length, 41);
      // 前 9 条原始为「歌曲0..8」的无 hash 占位；补全后应显示文件名里的
      // 歌名与歌手前缀，而不是「未知歌曲 / 未知艺人」，且仍不可播放。
      expect(page.orderedSongs.length, 50);
      final first = page.orderedSongs.first;
      expect(first.hash, isEmpty);
      expect(first.title, '歌曲0');
      expect(first.artist, '歌手');
      expect(page.orderedSongs[9].hash, 'hash_9');
    });

    test('playlistSongsPageAll(includeShieldedMeta)：全量下架曲均补全名称', () async {
      final page = await api.playlistSongsPageAll(
        'collection_3_1_99_0',
        includeShieldedMeta: true,
      );

      expect(page.rawItemCount, 530);
      expect(page.songs.length, 521);
      expect(page.orderedSongs.length, 530);
      expect(
        page.orderedSongs.where((song) => song.hash.isEmpty).length,
        9,
      );
      expect(
        page.orderedSongs
            .where((song) => song.hash.isEmpty)
            .every((song) => song.title != '未知歌曲' && song.artist == '歌手'),
        isTrue,
      );
    });
  });
}
