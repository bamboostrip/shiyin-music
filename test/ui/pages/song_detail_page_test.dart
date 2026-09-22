// PC 歌曲详情页：头部 + 评论/详情双 tab。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/pages/song_detail_page.dart';

class _FakeDetailClient implements ApiClientInterface {
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
              'album_name': 'take it for granted',
              'publish_date': '2024-05-01',
              'author_name': 'GRAHAM',
              'language': '英语',
              'intro': '一张专辑。',
            },
          ],
        };
      case '/search/lyric':
        return {'id': '1', 'accesskey': 'k'};
      case '/lyric':
        return {
          'decodedContent': '[00:00.00]作词：Graham Stiefel\n[00:05.00]作曲：Graham Stiefel',
        };
      case '/comment/music':
        return {
          'status': 1,
          'count': 655,
          'list': [
            {
              'id': 1,
              'content': '好听',
              'user_name': '路人',
              'addtime': '2024-01-01',
              'like': {'count': 10},
            },
          ],
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

class _FakeDetailPlayer extends ChangeNotifier implements PlayerController {
  _FakeDetailPlayer(this.api);

  @override
  final MusicApi api;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDetailAuth extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _testSong = Song(
  id: 's1',
  hash: 'h1',
  title: 'take it for granted',
  artist: 'GRAHAM',
  artists: [ArtistRef(id: 'a1', name: 'GRAHAM')],
  albumId: '123',
  albumName: 'take it for granted',
  albumAudioId: 'm1',
  duration: Duration(minutes: 2, seconds: 2),
);

Widget _host(SongDetailTab initialTab) {
  final player = _FakeDetailPlayer(MusicApi(_FakeDetailClient()));
  return MaterialApp(
    home: Scaffold(
      body: SongDetailPage(
        api: player.api,
        auth: _FakeDetailAuth(),
        player: player,
        song: _testSong,
        initialTab: initialTab,
      ),
    ),
  );
}

void main() {
  group('SongDetailPage', () {
    testWidgets('默认详情 tab：头部 + 演唱者/词曲/发行年份/语种', (tester) async {
      await tester.pumpWidget(_host(SongDetailTab.detail));
      await tester.pumpAndSettle();

      expect(find.text('take it for granted'), findsWidgets);
      expect(find.text('演唱者'), findsOneWidget);
      expect(find.text('GRAHAM'), findsWidgets);
      expect(find.text('作词'), findsOneWidget);
      expect(find.text('作曲'), findsOneWidget);
      expect(find.text('发行年份'), findsOneWidget);
      expect(find.text('2024'), findsOneWidget);
      expect(find.text('歌曲语种'), findsOneWidget);
      expect(find.text('英语'), findsOneWidget);
    });

    testWidgets('切到评论 tab：评论列表渲染，标题带数', (tester) async {
      await tester.pumpWidget(_host(SongDetailTab.detail));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Tab).first);
      await tester.pumpAndSettle();

      expect(find.text('好听'), findsOneWidget);
      expect(find.text('评论655'), findsOneWidget);
    });

    testWidgets('initialTab 评论：直接落在评论 tab', (tester) async {
      await tester.pumpWidget(_host(SongDetailTab.comments));
      await tester.pumpAndSettle();

      expect(find.text('好听'), findsOneWidget);
    });

    testWidgets('有上一页时展示返回键，点击回到上一页', (tester) async {
      final player = _FakeDetailPlayer(MusicApi(_FakeDetailClient()));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SongDetailPage(
                      api: player.api,
                      auth: _FakeDetailAuth(),
                      player: player,
                      song: _testSong,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回'), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(find.text('take it for granted'), findsNothing);
    });
  });
}
