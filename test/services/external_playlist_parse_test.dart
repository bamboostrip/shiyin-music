// 外部歌单解析结果的兼容性与分流：
// - 旧 Rust `/playlist/external/parse` 只返回 songNames 时，importTracks 回退为
//   纯标题曲目（无歌手/时长，导入侧按标题完全相等匹配）；
// - fromJson 解析可选的 tracks/totalSongCount，缺失不影响旧字段；
// - 非 QQ 链接（如网易云）继续走 Rust `/playlist/external/parse`，不触发 QQ 直连。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';

class _FakeExternalParseClient implements ApiClientInterface {
  String? lastPath;
  Map<String, Object?>? lastBody;

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
  ]) async => throw ArgumentError('Unexpected get: $path');

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async {
    lastPath = path;
    lastBody = body;
    return {
      'sourcePlatform': '网易云音乐',
      'playlistName': '旧解析歌单',
      'songNames': ['只有歌名的歌'],
    };
  }

  @override
  void close() {}
}

void main() {
  test('旧 Rust 返回只有 songNames 时 importTracks 回退为纯标题', () {
    final result = ExternalPlaylistParseResult.fromJson({
      'sourcePlatform': '网易云音乐',
      'playlistName': '旧解析歌单',
      'songNames': ['只有歌名的歌'],
    });
    expect(result.tracks, isEmpty);
    expect(result.totalSongCount, isNull);
    expect(result.importTracks.single.title, '只有歌名的歌');
    expect(result.importTracks.single.artist, '');
    expect(result.importTracks.single.duration, isNull);
    expect(result.importTracks.single.displayName, '只有歌名的歌');
  });

  test('fromJson 解析可选 tracks / totalSongCount，字段缺失容错', () {
    final result = ExternalPlaylistParseResult.fromJson({
      'sourcePlatform': 'QQ音乐',
      'playlistName': '带元数据的歌单',
      'songNames': ['歌一'],
      'tracks': [
        {'title': '歌一', 'artist': '歌手一', 'duration': 180},
        {'name': '歌二', 'singer': '歌手二', 'durationMs': 200000},
        {'title': '歌三'},
      ],
      'totalSongCount': 3,
    });
    expect(result.tracks.map((track) => track.title), ['歌一', '歌二', '歌三']);
    expect(result.tracks[0].artist, '歌手一');
    expect(result.tracks[0].duration, const Duration(seconds: 180));
    expect(result.tracks[1].duration, const Duration(seconds: 200));
    expect(result.tracks[2].duration, isNull);
    expect(result.totalSongCount, 3);
    // tracks 非空时优先使用 tracks（带歌手/时长），不再回退 songNames。
    expect(result.importTracks, hasLength(3));
  });

  test('非 QQ 链接（网易云）仍走 Rust /playlist/external/parse', () async {
    final client = _FakeExternalParseClient();
    const text = 'https://music.163.com/playlist?id=123';
    final result = await MusicApi(client).parseExternalPlaylist(text);

    expect(client.lastPath, '/playlist/external/parse');
    expect(client.lastBody, {'sourceText': text});
    expect(result.playlistName, '旧解析歌单');
    expect(result.importTracks.single.title, '只有歌名的歌');
  });
}
