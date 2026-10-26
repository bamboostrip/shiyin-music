import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

/// 逐字歌词缓存回归（上游 kgka_Music_hl 3.2.0 `87c35a1` 附带修复）。
///
/// KRC 歌词里词与词之间的空格本身也是「带时间的词」，`LyricWord.toCache()`
/// 会把纯空白文本原样写进缓存。读取时若走 `asString`（会 trim、空白直接变
/// null）就会丢掉词间空格，表现为「缓存过的逐字歌词单词连在一起」。
Map<String, dynamic> _roundtrip(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  test('LyricWord 缓存往返保留纯空白词与时间', () {
    const space = LyricWord(
      time: Duration(milliseconds: 1300),
      duration: Duration(milliseconds: 100),
      text: ' ',
    );
    final restored = LyricWord.fromCache(_roundtrip(space.toCache()));
    expect(restored.text, ' ');
    expect(restored, space);
  });

  test('LyricLine 缓存往返后逐字文本仍能拼回带空格歌词', () {
    final line = LyricLine(
      time: const Duration(milliseconds: 1000),
      text: 'Hello world',
      duration: const Duration(milliseconds: 1000),
      words: const [
        LyricWord(
          time: Duration(milliseconds: 1000),
          duration: Duration(milliseconds: 300),
          text: 'Hello',
        ),
        LyricWord(
          time: Duration(milliseconds: 1300),
          duration: Duration(milliseconds: 100),
          text: ' ',
        ),
        LyricWord(
          time: Duration(milliseconds: 1400),
          duration: Duration(milliseconds: 600),
          text: 'world',
        ),
      ],
    );
    final restored = LyricLine.fromCache(_roundtrip(line.toCache()));
    expect(restored.words.map((word) => word.text).join(), 'Hello world');
    expect(restored, line);
  });

  test('空文本词仍按空字符串还原（不因 trim 变 null）', () {
    const empty = LyricWord(
      time: Duration.zero,
      duration: Duration.zero,
      text: '',
    );
    expect(LyricWord.fromCache(_roundtrip(empty.toCache())).text, '');
  });
}
