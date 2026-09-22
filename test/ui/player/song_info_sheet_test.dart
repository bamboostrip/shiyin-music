// 歌曲信息弹层：首屏零请求行 + 专辑详情/歌词署名两路异步行。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/player/song_info_sheet.dart';

class _FakeInfoClient implements ApiClientInterface {
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
    switch (path) {
      case '/album/detail':
        return {
          'data': [
            {
              'album_id': '123',
              'album_name': '单身情歌．超炫精选',
              'publish_date': '1999-07-01',
              'author_name': '林志炫',
              'intro': '一张精选集。',
            },
          ],
        };
      case '/search/lyric':
        // 仅 h1 有歌词候选，其余 hash 走无歌词分支。
        if (query['hash'] == 'h1') {
          return {'id': '1', 'accesskey': 'k'};
        }
        return {};
      case '/lyric':
        return {
          'decodedContent':
              '[00:00.00]作词：易家扬\n[00:05.00]作曲：陈耀川\n[00:10.00]抓不住爱情的我',
        };
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

class _FakeInfoPlayer extends ChangeNotifier implements PlayerController {
  _FakeInfoPlayer(this.api);

  @override
  final MusicApi api;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeInfoAuth extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _testSong = Song(
  id: 's1',
  hash: 'h1',
  title: '单身情歌',
  artist: '林志炫',
  artists: [ArtistRef(id: 'a1', name: '林志炫')],
  albumId: '123',
  albumName: '单身情歌',
  duration: Duration(minutes: 4, seconds: 29),
);

Widget _host(Song song, _FakeInfoPlayer player) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showSongInfoSheet(
          context: context,
          player: player,
          auth: _FakeInfoAuth(),
          song: song,
        ),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  group('showSongInfoSheet', () {
    testWidgets('首屏行 + 专辑年份 + 词曲署名齐备', (tester) async {
      final player = _FakeInfoPlayer(MusicApi(_FakeInfoClient()));
      await tester.pumpWidget(_host(_testSong, player));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('歌曲：单身情歌'), findsOneWidget);
      expect(find.textContaining('歌手：林志炫'), findsOneWidget);
      expect(find.textContaining('作词：易家扬'), findsOneWidget);
      expect(find.textContaining('作曲：陈耀川'), findsOneWidget);
      expect(find.textContaining('专辑：'), findsOneWidget);
      expect(find.textContaining('发行年份：1999'), findsOneWidget);
      expect(find.textContaining('时长：04:29'), findsOneWidget);
      expect(find.text('专辑简介'), findsOneWidget);
    });

    testWidgets('无专辑无歌词时对应行隐藏，不抛错', (tester) async {
      final player = _FakeInfoPlayer(MusicApi(_FakeInfoClient()));
      const song = Song(
        id: 's2',
        hash: 'unknown',
        title: '无名',
        artist: '未知艺人',
      );
      await tester.pumpWidget(_host(song, player));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('歌曲：无名'), findsOneWidget);
      expect(find.textContaining('发行年份'), findsNothing);
      expect(find.textContaining('作词'), findsNothing);
      expect(find.textContaining('作曲'), findsNothing);
      expect(find.textContaining('专辑：'), findsNothing);
    });
  });
}
