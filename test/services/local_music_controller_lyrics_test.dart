import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/local_music_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LocalMusicController build({
    Future<String?> Function(String path)? pathReader,
    Future<String?> Function(Uint8List bytes)? bytesReader,
    Future<Uint8List?> Function(String source)? headReader,
  }) {
    return LocalMusicController(
      rustLyricsReader: pathReader,
      rustLyricsBytesReader: bytesReader,
      mediaHeadReader: headReader,
    );
  }

  test('路径读到歌词：直接返回，不走字节兜底', () async {
    var headCalls = 0;
    final c = build(
      pathReader: (_) async => '[00:01.00]你好',
      headReader: (_) async {
        headCalls++;
        return Uint8List.fromList(const [1]);
      },
    );
    expect(await c.getEmbeddedLyrics('/a.mp3'), '[00:01.00]你好');
    expect(headCalls, 0);
  });

  test('路径解析成功但无歌词（返回 null）：这是确定性结论，不走兜底', () async {
    var headCalls = 0;
    final c = build(
      pathReader: (_) async => null,
      headReader: (_) async {
        headCalls++;
        return Uint8List.fromList(const [1]);
      },
    );
    expect(await c.getEmbeddedLyrics('/a.mp3'), isNull);
    expect(headCalls, 0);
  });

  test('路径读不了（抛错）且有 contentUri：截头→字节解析拿到歌词', () async {
    final bytes = Uint8List.fromList(const [1, 2, 3]);
    var headSource = '';
    final c = build(
      pathReader: (_) async => throw Exception('open failed'),
      bytesReader: (b) async {
        expect(b, same(bytes)); // 字节原样透传
        return '[00:02.00]兜底';
      },
      headReader: (s) async {
        headSource = s;
        return bytes;
      },
    );
    final r = await c.getEmbeddedLyrics(
      '/storage/0/a.mp3',
      contentUri: 'content://media/external/audio/media/9',
    );
    expect(r, '[00:02.00]兜底');
    expect(headSource, 'content://media/external/audio/media/9');
  });

  test('路径读不了但没有 contentUri：返回 null', () async {
    final c = build(pathReader: (_) async => throw Exception('open failed'));
    expect(await c.getEmbeddedLyrics('/a.mp3'), isNull);
  });

  test('截头失败：返回 null 且不把异常抛给调用方', () async {
    final c = build(
      pathReader: (_) async => throw Exception('open failed'),
      headReader: (_) async => throw Exception('content gone'),
    );
    expect(
      await c.getEmbeddedLyrics('/a.mp3', contentUri: 'content://x/y'),
      isNull,
    );
  });
}
