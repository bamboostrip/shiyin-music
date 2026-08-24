import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 假客户端：按调用顺序返回预置的 /rank/audio 响应，并记录请求参数。
class _FakeRankClient implements ApiClientInterface {
  _FakeRankClient(this.pages);

  /// 每页的原始条数（与真实接口一致：rawItems 长度即分页判断依据之外的
  /// 展示条数；这里直接按过滤后的条数构造 songlist）。
  final List<int> pages;
  final calls = <Map<String, Object?>>[];

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  Map<String, Object?> _song(int i) => {
        'hash': 'hash$i',
        'filename': '歌手 - 歌曲$i',
        'singername': '歌手',
      };

  @override
  Future<dynamic> get(String path, [Map<String, Object?> query = const {}]) async {
    calls.add({'path': path, ...query});
    if (path != '/rank/audio') {
      throw ArgumentError('unexpected path: $path');
    }
    final pageIndex = calls.length - 1;
    final count = pageIndex < pages.length ? pages[pageIndex] : 0;
    return {
      'songlist': [for (var i = 0; i < count; i++) _song(pageIndex * 100 + i)],
    };
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async => throw UnimplementedError();

  @override
  void close() {}
}

void main() {
  group('MusicApi.rankAudioAll', () {
    test('多页榜单循环拉全：50+50+30 时应请求 3 页并返回 130 首', () async {
      final client = _FakeRankClient([50, 50, 30]);
      final api = MusicApi(client);

      final songs = await api.rankAudioAll(rankId: 8888, pageSize: 50);

      expect(songs.length, 130);
      expect(client.calls.length, 3);
      expect(client.calls[0]['page'], 1);
      expect(client.calls[1]['page'], 2);
      expect(client.calls[2]['page'], 3);
      expect(client.calls[0]['pagesize'], 50);
    });

    test('不足一页时只请求一次：30 首直接返回', () async {
      final client = _FakeRankClient([30]);
      final api = MusicApi(client);

      final songs = await api.rankAudioAll(rankId: 8888, pageSize: 50);

      expect(songs.length, 30);
      expect(client.calls.length, 1);
    });

    test('空榜单返回空列表且只请求一次', () async {
      final client = _FakeRankClient([0]);
      final api = MusicApi(client);

      final songs = await api.rankAudioAll(rankId: 8888, pageSize: 50);

      expect(songs, isEmpty);
      expect(client.calls.length, 1);
    });

    test('maxPages 防御上限：异常数据持续返回满页时也最多翻 maxPages 页', () async {
      final client = _FakeRankClient([50, 50, 50, 50, 50]);
      final api = MusicApi(client);

      final songs = await api.rankAudioAll(rankId: 8888, pageSize: 50, maxPages: 3);

      expect(songs.length, 150);
      expect(client.calls.length, 3);
    });
  });
}
