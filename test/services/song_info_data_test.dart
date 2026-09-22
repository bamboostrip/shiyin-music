import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';

LyricLine _line(String text) => LyricLine(time: Duration.zero, text: text);

class _FakeAlbumClient implements ApiClientInterface {
  _FakeAlbumClient(this.response);

  final dynamic response;

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
    if (path == '/album/detail') {
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
  }) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

void main() {
  group('extractLyricCredits', () {
    test('头部作词作曲行被提取，冒号兼容半角/全角', () {
      final credits = extractLyricCredits([
        _line('[00:00.00] 作词：易家扬'),
        _line('[00:01.00] 作曲: 陈耀川'),
        _line('[00:02.00] 抓不住爱情的我'),
      ]);
      expect(credits.lyricist, '易家扬');
      expect(credits.composer, '陈耀川');
      expect(credits.isEmpty, isFalse);
    });

    test('无署名行返回空，有多条时取第一条', () {
      final empty = extractLyricCredits([
        _line('抓不住爱情的我'),
        _line('总是眼睁睁看它溜走'),
      ]);
      expect(empty.isEmpty, isTrue);

      final first = extractLyricCredits([
        _line('作词：甲'),
        _line('作词：乙'),
      ]);
      expect(first.lyricist, '甲');
    });

    test('只扫头部，超出 maxLines 的署名被忽略', () {
      final lines = List.generate(15, (i) => _line('第 $i 句'));
      final credits = extractLyricCredits([...lines, _line('作词：迟到')]);
      expect(credits.lyricist, isNull);
    });
  });

  group('MusicApi.albumDetail', () {
    test('data 数组首个有效专辑被解析', () async {
      final api = MusicApi(
        _FakeAlbumClient({
          'data': [
            {
              'album_id': '123',
              'album_name': '单身情歌．超炫精选',
              'publish_date': '1999-07-01',
              'author_name': '林志炫',
              'intro': '精选集',
            },
          ],
        }),
      );
      final album = await api.albumDetail('123');
      expect(album, isNotNull);
      expect(album!.name, '单身情歌．超炫精选');
      expect(album.publishDate, '1999-07-01');
      expect(album.intro, '精选集');
    });

    test('空 albumId 与空结果返回 null（调用方隐藏对应行）', () async {
      final api = MusicApi(_FakeAlbumClient({'data': []}));
      expect(await api.albumDetail(''), isNull);
      expect(await api.albumDetail('   '), isNull);
      expect(await api.albumDetail('999'), isNull);
    });
  });
}
