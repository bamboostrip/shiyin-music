import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 只响应 `/search` 的假客户端，记录调用路径与 query 以便断言。
class _FakeSearchApiClient implements ApiClientInterface {
  _FakeSearchApiClient(this.response);

  final dynamic response;
  final List<String> paths = [];
  final List<Map<String, Object?>> queries = [];

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
    paths.add(path);
    queries.add(Map<String, Object?>.of(query));
    if (path == '/search') {
      return response;
    }
    throw ArgumentError('Unexpected path: $path');
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
  group('MusicApi.searchPlaylists', () {
    test(
      '走 /search?type=special（Rust 引擎无 /search/special 路由），解析真实 lists 响应',
      () async {
        // 真实响应形态（2026-11-06 用 Rust 引擎探针抓取并裁剪）：外层是
        // 完整响应对象，歌单数组在顶层 `lists`，字段名与 api.json 的
        // SearchPlaylistItem 一致，gid 形如 collection_3_<uid>_<listid>_0。
        final client = _FakeSearchApiClient({
          'status': 1,
          'error_code': 0,
          'page': 1,
          'pagesize': 30,
          'total': 480,
          'lists': [
            {
              'specialname': '周杰伦出道26周年｜播放属于我们的青春记忆',
              'specialid': 6409645,
              'gid': 'collection_3_2132029040_287_0',
              'song_count': 194,
              'nickname': '酷乐推荐',
              'total_play_count': '37441232',
              'play_count': '202773',
              'img':
                  'http://imge.kugou.com/soft/collection/150/20261105174305581202.jpg',
              'intro': '一晃二十六载，从首张专辑横空出世开始……',
              'publish_time': '2023-01-10 00:00:01',
            },
            {
              'specialname': '演唱会曲目 | 周杰伦 《嘉年华Ⅱ》巡演',
              'specialid': '9404077',
              'gid': 'collection_3_2132040296_638_0',
              'song_count': '97',
              'nickname': '酷狗站-现场看我的',
              'total_play_count': 759332,
              'img': 'http://imge.kugou.com/soft/collection/150/cover2.jpg',
            },
          ],
        });
        final api = MusicApi(client);

        final results = await api.searchPlaylists('周杰伦');

        // 引擎只支持通用 /search 的 type=special 分支；独立路由会 Unknown route。
        expect(client.paths, ['/search']);
        expect(client.queries.single, {
          'keywords': '周杰伦',
          'page': 1,
          'pagesize': 30,
          'type': 'special',
        });
        expect(results, hasLength(2));

        // gid 是详情/曲目接口唯一接受的 ID（specialid 数字 ID 实测会返回空）。
        expect(results[0].id, 'collection_3_2132029040_287_0');
        expect(results[0].title, '周杰伦出道26周年｜播放属于我们的青春记忆');
        expect(results[0].subtitle, '酷乐推荐');
        expect(results[0].songCount, 194);
        expect(results[0].playCount, 37441232);
        expect(results[0].coverUrl,
            'http://imge.kugou.com/soft/collection/150/20261105174305581202.jpg');
        expect(results[0].sourceGlobalId, results[0].id);

        // gid 直接作为详情/曲目接口的 ID。
        expect(results[1].id, 'collection_3_2132040296_638_0');
        expect(results[1].title, '演唱会曲目 | 周杰伦 《嘉年华Ⅱ》巡演');
        expect(results[1].songCount, 97);
        expect(results[1].playCount, 759332);
      },
    );

    test('兼容底层直接返回裸数组', () async {
      final client = _FakeSearchApiClient([
        {
          'specialname': '华语经典',
          'specialid': 123,
          'gid': 'collection_3_1_2_0',
          'song_count': 50,
          'nickname': '小酷',
          'total_play_count': 100,
          'img': 'https://imge.kugou.com/special/{size}/cover.jpg',
        },
        {
          'specialname': '粤语金曲',
          'specialid': '456',
          'gid': 'collection_3_2_3_0',
          'song_count': '20',
          'nickname': '阿粤',
          'total_play_count': 200,
          'img': 'https://imge.kugou.com/special/cover2.jpg',
        },
      ]);
      final api = MusicApi(client);

      final results = await api.searchPlaylists('周杰伦');

      expect(results, hasLength(2));
      expect(results[0].id, 'collection_3_1_2_0');
      expect(results[0].coverUrl, contains('/480/'));
      // gid 直接作为详情/曲目接口的 ID。
      expect(results[1].id, 'collection_3_2_3_0');
      expect(results[1].songCount, 20);
    });

    test('page 参数透传（int 形态）', () async {
      final client = _FakeSearchApiClient(<dynamic>[]);
      final api = MusicApi(client);

      await api.searchPlaylists('林俊杰', page: 3);

      expect(client.queries.single, {
        'keywords': '林俊杰',
        'page': 3,
        'pagesize': 30,
        'type': 'special',
      });
    });

    test('兼容 {info: [...]} 包装', () async {
      final client = _FakeSearchApiClient({
        'info': [
          {'specialname': '包装内的歌单', 'specialid': 1, 'gid': 'g1'},
        ],
      });
      final api = MusicApi(client);

      final results = await api.searchPlaylists('测试');

      expect(results, hasLength(1));
      expect(results.single.id, 'g1');
      expect(results.single.title, '包装内的歌单');
    });

    test('兼容 {data: {info: [...]}} 嵌套包装', () async {
      final client = _FakeSearchApiClient({
        'data': {
          'info': [
            {'specialname': '嵌套包装的歌单', 'gid': 'g2'},
          ],
        },
      });
      final api = MusicApi(client);

      final results = await api.searchPlaylists('测试');

      expect(results, hasLength(1));
      expect(results.single.id, 'g2');
      expect(results.single.title, '嵌套包装的歌单');
    });

    test('兼容 {data: [...]}（data 直接是数组）包装', () async {
      final client = _FakeSearchApiClient({
        'data': [
          {'specialname': 'data 数组歌单', 'gid': 'g-data'},
        ],
      });
      final api = MusicApi(client);

      final results = await api.searchPlaylists('测试');

      expect(results, hasLength(1));
      expect(results.single.id, 'g-data');
      expect(results.single.title, 'data 数组歌单');
    });

    test('过滤无 gid 的条目；标题缺失时回落默认标题而不是丢弃', () async {
      final client = _FakeSearchApiClient({
        'lists': [
          // 有效条目。
          {'specialname': '有效', 'gid': 'g1', 'specialid': 11, 'song_count': 5},
          // 无标题但有 gid：保留，标题回落「未命名歌单」。
          {'gid': 'g22', 'nickname': '某用户'},
          // 只有数字 specialid（实测详情接口不接受）：无法打开，过滤。
          {'specialname': '只有 specialid', 'specialid': 22},
          // gid 与 specialid 都缺失：无法打开详情，过滤。
          {'specialname': '无 ID 歌单'},
          // 空串 ID 视为缺失，过滤。
          {'specialname': '空 ID 歌单', 'gid': '', 'specialid': ''},
          // 非 Map 条目直接跳过。
          'not-a-map',
        ],
      });
      final api = MusicApi(client);

      final results = await api.searchPlaylists('测试');

      expect(results.map((p) => p.id).toList(), ['g1', 'g22']);
      expect(results.map((p) => p.title).toList(), ['有效', '未命名歌单']);
      expect(results[1].subtitle, '某用户');
    });

    test('只有 gid 的条目可用：specialid 或空 gid 条目一律过滤', () async {
      final client = _FakeSearchApiClient({
        'lists': [
          {'specialname': '有 gid', 'gid': 'collection_3_1_2_0', 'specialid': 99},
          {'specialname': '只有 specialid', 'specialid': 100},
          {'specialname': '空 gid', 'gid': '  ', 'specialid': 101},
        ],
      });
      final api = MusicApi(client);

      final results = await api.searchPlaylists('测试');

      expect(results.map((p) => p.id).toList(), ['collection_3_1_2_0']);
      expect(results.map((p) => p.sourceGlobalId).toList(), [
        'collection_3_1_2_0',
      ]);
    });

    test('响应为 null、空 Map 或空 data 时返回空列表', () async {
      final apiNull = MusicApi(_FakeSearchApiClient(null));
      expect(await apiNull.searchPlaylists('测试'), isEmpty);

      final apiEmptyMap = MusicApi(_FakeSearchApiClient(<String, dynamic>{}));
      expect(await apiEmptyMap.searchPlaylists('测试'), isEmpty);

      final apiEmptyData = MusicApi(
        _FakeSearchApiClient({'data': <String, dynamic>{}}),
      );
      expect(await apiEmptyData.searchPlaylists('测试'), isEmpty);
    });
  });
}
