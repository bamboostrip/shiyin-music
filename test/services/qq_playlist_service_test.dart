// QQ 歌单公开接口解析（QqPlaylistService）：
// - 分享文本中的 QQ 链接提取（host 白名单、拒绝 userInfo）；
// - 短链 302 最多 6 跳解析歌单编号，跳转到非 QQ 域立即拒绝；
// - musicu.fcg 分页拉取 songlist（每页 100 首、上限 100 页），
//   mid 去重、空页停止、重复页报错、超页上限报错、空歌单报错；
// - 字段映射：name → title、singer[].name → artist（数组/对象/字符串容错）、
//   interval（秒）→ duration；totalSongCount 回填。
//
// 全部使用 package:http/testing.dart 的 MockClient，不联网。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiyin_music/services/qq_playlist_service.dart';

/// 构造一页 QQ 接口响应（与真实 musicu.fcg 成功信封同构）。
http.Response qqPage(
  List<Map<String, Object?>> songs, {
  int total = 1,
  String title = '测试歌单',
}) => http.Response(
  jsonEncode({
    'code': 0,
    'req_0': {
      'code': 0,
      'data': {
        'code': 0,
        'dirinfo': {'title': title, 'songnum': total},
        'songlist': songs,
      },
    },
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object?> qqSong(
  String id,
  String artist, {
  String title = '同名歌曲',
  Object? singer,
  int? interval = 180,
}) => {
  'mid': id,
  'name': title,
  'interval': interval,
  'singer': singer ?? [
    {'name': artist},
  ],
};

/// 从 musicu.fcg 请求的 data 参数里取分页偏移与 disstid。
({int disstid, int offset}) qqParam(http.Request request) {
  final data = jsonDecode(request.url.queryParameters['data']!);
  final param = data['req_0']['param'] as Map;
  return (
    disstid: param['disstid'] as int,
    offset: param['song_begin'] as int,
  );
}

void main() {
  group('shareUri 链接提取', () {
    test('纯链接与子域链接均可识别', () {
      expect(
        QqPlaylistService.shareUri('https://y.qq.com/n/ryqq/playlist/123')?.host,
        'y.qq.com',
      );
      expect(
        QqPlaylistService.shareUri(
          'https://i.y.qq.com/n2/m/share/details/taoge.html?id=123',
        )?.host,
        'i.y.qq.com',
      );
    });

    test('分享文案 / Markdown 中夹带的短链可提取', () {
      final uri = QqPlaylistService.shareUri(
        '分享歌单《测试歌单》 [点这里](https://c6.y.qq.com/base/fcgi-bin/u?__=abc) 快来听',
      );
      expect(uri?.host, 'c6.y.qq.com');
      expect(uri?.queryParameters['__'], 'abc');
    });

    test('非 QQ 域名不识别', () {
      expect(
        QqPlaylistService.shareUri('https://music.163.com/playlist?id=123'),
        isNull,
      );
      expect(
        QqPlaylistService.shareUri('https://y.qq.com.evil.example/playlist/123'),
        isNull,
      );
      expect(QqPlaylistService.shareUri('no link here'), isNull);
    });

    test('带 userInfo 的恶意链接被拒绝', () {
      expect(
        QqPlaylistService.shareUri('https://user@y.qq.com/playlist/123'),
        isNull,
      );
      expect(
        QqPlaylistService.shareUri('https://y.qq.com@evil.example/playlist/123'),
        isNull,
      );
    });

    test('多个链接时优先取第一个 QQ 链接', () {
      final uri = QqPlaylistService.shareUri(
        'https://example.com/a https://y.qq.com/n/ryqq/playlist/456',
      );
      expect(uri?.path, '/n/ryqq/playlist/456');
    });
  });

  group('_resolveId 歌单编号解析（经 load 间接验证）', () {
    /// 构造一个只接受 u.y.qq.com 请求的客户端，并记录首个请求。
    MockClient loadClient(void Function(http.Request request) onRequest) {
      return MockClient((request) async {
        onRequest(request);
        return qqPage([qqSong('one', '歌手甲')]);
      });
    }

    test('路径式 /playlist/123 无需跟随跳转', () async {
      final hosts = <String>[];
      final client = loadClient((request) {
        hosts.add(request.url.host);
        expect(qqParam(request).disstid, 123);
      });
      final result = await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123'));
      expect(hosts, ['u.y.qq.com']);
      expect(result.importTracks, hasLength(1));
    });

    test('query 参数 disstid 直接取用', () async {
      final client = loadClient((request) {
        expect(qqParam(request).disstid, 456);
      });
      await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq_v2/playlist?disstid=456'));
    });

    test('taoge.html?id= 取 id', () async {
      final client = loadClient((request) {
        expect(qqParam(request).disstid, 789);
      });
      await QqPlaylistService(client).load(
        Uri.parse('https://y.qq.com/n2/m/share/details/taoge.html?id=789'),
      );
    });

    test('playsquare/ 路径取编号（c60a92f 兼容）', () async {
      final client = loadClient((request) {
        expect(qqParam(request).disstid, 321);
      });
      await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playsquare/321'));
    });

    test('短链 302 跟随一跳后解析出歌单编号', () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'c6.y.qq.com') {
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://i.y.qq.com/n2/m/share/details/taoge.html?id=123&openinqqmusic=1',
            },
          );
        }
        expect(qqParam(request).disstid, 123);
        return qqPage([qqSong('one', '歌手甲')]);
      });
      final result = await QqPlaylistService(
        client,
      ).load(Uri.parse('https://c6.y.qq.com/base/fcgi-bin/u?__=abc'));
      // 只在短链域名上发一次跳转请求，随后直接请求 musicu.fcg。
      expect(hosts, ['c6.y.qq.com', 'u.y.qq.com']);
      expect(result.importTracks.single.artist, '歌手甲');
      expect(
        result.importTracks.single.duration,
        const Duration(seconds: 180),
      );
    });

    test('跳转到非 QQ 域时立即拒绝（不请求 u.y.qq.com）', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(
          '',
          302,
          headers: {'location': 'https://example.com/playlist/123'},
        );
      });
      await expectLater(
        QqPlaylistService(
          client,
        ).load(Uri.parse('https://c6.y.qq.com/base/fcgi-bin/u?__=abc')),
        throwsA(isA<FormatException>()),
      );
      expect(calls, 1);
    });

    test('既无编号也无跳转时给出重新复制的提示', () async {
      final client = MockClient(
        (_) async => http.Response('<html>not a playlist</html>', 200),
      );
      await expectLater(
        QqPlaylistService(
          client,
        ).load(Uri.parse('https://y.qq.com/n/ryqq/index')),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('load 请求与字段映射', () {
    test('请求携带 QQ Referer / UA，且不携带酷狗会话', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return qqPage([qqSong('one', '歌手甲')]);
      });
      await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123'));
      expect(captured.headers['Referer'], 'https://y.qq.com/');
      expect(captured.headers['User-Agent'], contains('Mozilla'));
      expect(captured.headers.containsKey('X-Kg-Session-Id'), isFalse);
      expect(captured.headers.containsKey('Cookie'), isFalse);
    });

    test('name/singer/interval 映射为 title/artist/duration', () async {
      final client = MockClient(
        (_) async => qqPage([
          qqSong('one', '歌手甲', title: '歌曲一', interval: 245),
        ]),
      );
      final result = await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123'));
      final track = result.importTracks.single;
      expect(track.title, '歌曲一');
      expect(track.artist, '歌手甲');
      expect(track.duration, const Duration(seconds: 245));
      expect(track.displayName, '歌手甲 - 歌曲一');
      expect(result.sourcePlatform, 'QQ音乐');
      expect(result.playlistName, '测试歌单');
      expect(result.totalSongCount, 1);
      expect(result.songNames, ['歌曲一']);
    });

    test('singer 为对象/字符串/缺失时容错', () async {
      final client = MockClient(
        (_) async => qqPage([
          qqSong('one', '', singer: {'name': '对象歌手'}),
          qqSong('two', '', singer: '字符串歌手'),
          qqSong('three', '', singer: const []),
        ], total: 3),
      );
      final result = await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123'));
      expect(result.importTracks.map((track) => track.artist), [
        '对象歌手',
        '字符串歌手',
        '',
      ]);
    });

    test('interval 缺失或非正数时 duration 为 null', () async {
      final client = MockClient(
        (_) async => qqPage([
          qqSong('one', '歌手甲', interval: null),
          qqSong('two', '歌手甲', interval: 0),
        ], total: 2),
      );
      final result = await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123'));
      expect(result.importTracks.map((track) => track.duration), [
        isNull,
        isNull,
      ]);
    });

    test('标题缺失的条目被跳过（不生成空标题曲目）', () async {
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode({
            'code': 0,
            'req_0': {
              'code': 0,
              'data': {
                'code': 0,
                'dirinfo': {'title': '测试歌单', 'songnum': 2},
                'songlist': [
                  qqSong('one', '歌手甲'),
                  {'mid': 'no-title', 'interval': 100},
                ],
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final result = await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123'));
      expect(result.importTracks, hasLength(1));
      expect(result.importTracks.single.title, '同名歌曲');
    });
  });

  group('load 分页与异常', () {
    test('多页合并：offset 按已取条数推进', () async {
      final offsets = <int>[];
      final client = MockClient((request) async {
        final param = qqParam(request);
        offsets.add(param.offset);
        return param.offset == 0
            ? qqPage([
                qqSong('one', '歌手甲'),
                qqSong('two', '歌手乙'),
              ], total: 3)
            : qqPage([qqSong('three', '歌手丙')], total: 3);
      });
      final result = await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123'));
      expect(offsets, [0, 2]);
      expect(result.importTracks, hasLength(3));
      // 同名不同歌手不能被去重掉。
      expect(result.importTracks.map((track) => track.artist), [
        '歌手甲',
        '歌手乙',
        '歌手丙',
      ]);
      expect(result.songNames.toSet().length, 1);
      expect(result.totalSongCount, 3);
    });

    test('同 mid 重复曲目只保留一条', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return qqPage([
          qqSong('same-mid', '歌手甲'),
          qqSong('same-mid', '歌手甲'),
        ], total: 2);
      });
      final result = await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123'));
      expect(result.importTracks, hasLength(1));
      expect(calls, 1);
    });

    test('空页停止分页，保留总曲数用于提示差异', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return qqPage(
          calls == 1 ? [qqSong('one', '歌手甲')] : const [],
          total: 2,
        );
      });
      final result = await QqPlaylistService(
        client,
      ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123'));
      expect(result.importTracks, hasLength(1));
      expect(result.totalSongCount, 2);
      expect(calls, 2);
    });

    test('QQ 反复返回同一页时报错而不是死循环', () async {
      final client = MockClient(
        (_) async => qqPage([qqSong('one', '歌手甲')], total: 10),
      );
      await expectLater(
        QqPlaylistService(
          client,
        ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123')),
        throwsA(isA<FormatException>()),
      );
    });

    test('超过 100 页上限时报「歌单过大」', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return qqPage([qqSong('song-$calls', '歌手甲')], total: 10000);
      });
      await expectLater(
        QqPlaylistService(
          client,
        ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123')),
        throwsA(isA<FormatException>()),
      );
      expect(calls, 100);
    });

    test('空歌单报错', () async {
      final client = MockClient((_) async => qqPage(const [], total: 0));
      await expectLater(
        QqPlaylistService(
          client,
        ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123')),
        throwsA(isA<FormatException>()),
      );
    });

    test('HTTP 非 200 报错', () async {
      final client = MockClient(
        (_) async => http.Response('bad gateway', 502),
      );
      await expectLater(
        QqPlaylistService(
          client,
        ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123')),
        throwsA(isA<FormatException>()),
      );
    });

    test('业务错误码（歌单不可读/未公开）报错', () async {
      final client = MockClient(
        (_) async => http.Response('{"code":0,"req_0":{"code":1000}}', 200),
      );
      await expectLater(
        QqPlaylistService(
          client,
        ).load(Uri.parse('https://y.qq.com/n/ryqq/playlist/123')),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
