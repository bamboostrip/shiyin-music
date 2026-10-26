// 歌单/专辑曲目分页的「原始条数」口径（issue #6-1）：
// 上游会下发无 hash（下架/无版权）曲目，playlistSongPage/albumSongPage 会
// 过滤掉它们，但 rawItemCount 必须保留原始条数：
//   - 分页判末页不能按过滤后长度（否则满页无 hash 会提前截断）；
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

    test('playlistSongPage：过滤无 hash 曲目但保留原始条数', () async {
      final page = await api.playlistSongPage('pl_1', page: 1, pageSize: 50);

      expect(page.rawItemCount, 50);
      expect(page.songs.length, 41);
      expect(page.songs.every((song) => song.hash.isNotEmpty), isTrue);
    });

    test('playlistSongsPageAll：翻满所有页并累计原始条数', () async {
      final page = await api.playlistSongsPageAll('pl_1');

      expect(page.rawItemCount, 530);
      expect(page.songs.length, 521);
    });

    test('playlistSongs(fetchAll:true) 行为不变：返回全部可播放曲目', () async {
      final songs = await api.playlistSongs('pl_1', fetchAll: true);

      expect(songs.length, 521);
    });

    test('albumSongsPageAll：过滤无 hash 曲目但累计原始条数', () async {
      final page = await api.albumSongsPageAll('album_1');

      expect(page.rawItemCount, 120);
      expect(page.songs.length, 117);
    });

    test('albumSongs：翻满所有页返回可播放曲目', () async {
      final songs = await api.albumSongs('album_1');

      expect(songs.length, 117);
    });
  });
}
