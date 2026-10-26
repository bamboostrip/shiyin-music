// 首页「推荐歌曲」6 组 API 层（MusicApi.recommendedSongCards）：
// - 6 组并发请求 Rust 引擎 `/top/card`（card_id 1..6），不允许串行；
// - 每组独立 try/catch：单组失败只丢该组，不拖垮首页；
// - 空 song_list 组过滤；`rec_desc` 进入卡片 description。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

class _FakeTopCardClient implements ApiClientInterface {
  _FakeTopCardClient({this.failCardIds = const {}, this.emptyCardIds = const {}});

  /// 请求即抛错的组（模拟单组接口失败）。
  final Set<int> failCardIds;

  /// 返回空 song_list 的组。
  final Set<int> emptyCardIds;

  /// 记录实际请求过的 card_id（含顺序，用 set 断言并发 6 组全覆盖）。
  final List<int> requestedCardIds = [];

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
    if (path != '/top/card') {
      throw ArgumentError('Unexpected path: $path');
    }
    final cardId = query['card_id'] as int;
    requestedCardIds.add(cardId);
    if (failCardIds.contains(cardId)) {
      throw Exception('mock card $cardId failure');
    }
    if (emptyCardIds.contains(cardId)) {
      return {'song_list': <dynamic>[]};
    }
    return {
      'rec_desc': '第$cardId组推荐语',
      'song_list': [
        {
          'songname': '歌曲$cardId',
          'author_name': '歌手$cardId',
          'hash': 'HASH_$cardId',
          'time_length': 100.5,
          'sizable_cover': 'http://img.kugou.com/{size}/$cardId.jpg',
        },
      ],
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
  group('MusicApi.recommendedSongCards', () {
    test('并发请求 6 组 /top/card（card_id 1..6），按定义顺序返回', () async {
      final client = _FakeTopCardClient();
      final api = MusicApi(client);

      final cards = await api.recommendedSongCards();

      expect(client.requestedCardIds.toSet(), {1, 2, 3, 4, 5, 6});
      expect(client.requestedCardIds.length, 6);
      expect(cards.map((card) => card.cardId), [1, 2, 3, 4, 5, 6]);
      expect(cards.map((card) => card.title), [
        '私人专属好歌',
        '经典怀旧金曲',
        '热门好歌精选',
        '小众宝藏佳作',
        '潮流尝鲜',
        'VIP 专属推荐',
      ]);
      // 单组响应解析：歌曲 hash/标题与小数秒时长。
      final first = cards.first;
      expect(first.songs.single.hash, 'HASH_1');
      expect(first.songs.single.title, '歌曲1');
      expect(
        first.songs.single.duration,
        const Duration(milliseconds: 100500),
      );
      expect(first.coverUrl, 'http://img.kugou.com/480/1.jpg');
    });

    test('rec_desc 进入 description，songSummary 兜底首曲信息', () async {
      final client = _FakeTopCardClient();
      final api = MusicApi(client);

      final cards = await api.recommendedSongCards();

      expect(cards.first.description, '第1组推荐语');
      expect(cards.first.songSummary, '歌曲1 · 歌手1');
    });

    test('某组抛错：其余组正常返回，不向上抛出', () async {
      final client = _FakeTopCardClient(failCardIds: {3});
      final api = MusicApi(client);

      final cards = await api.recommendedSongCards();

      expect(cards.map((card) => card.cardId), [1, 2, 4, 5, 6]);
      expect(cards.map((card) => card.title), [
        '私人专属好歌',
        '经典怀旧金曲',
        '小众宝藏佳作',
        '潮流尝鲜',
        'VIP 专属推荐',
      ]);
    });

    test('空 song_list 组被过滤', () async {
      final client = _FakeTopCardClient(emptyCardIds: {4});
      final api = MusicApi(client);

      final cards = await api.recommendedSongCards();

      expect(cards.map((card) => card.cardId), [1, 2, 3, 5, 6]);
      expect(cards, hasLength(5));
    });

    test('全部失败时返回空列表（首页整体降级，不抛错）', () async {
      final client = _FakeTopCardClient(
        failCardIds: {1, 2, 3, 4, 5, 6},
      );
      final api = MusicApi(client);

      expect(await api.recommendedSongCards(), isEmpty);
    });
  });
}
