import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/song.dart';
import 'package:shiyin_music/services/lyric_converter.dart';

void main() {
  test('convertToFlutterLyricModel 逐字时间戳随行下发（车机/横屏 karaoke 数据链路）', () {
    final lyrics = [
      const LyricLine(
        time: Duration(seconds: 1),
        text: 'hello world',
        translation: '你好世界',
        words: [
          LyricWord(
            time: Duration(seconds: 1),
            duration: Duration(milliseconds: 500),
            text: 'hello ',
          ),
          LyricWord(
            time: Duration(milliseconds: 1500),
            duration: Duration(milliseconds: 700),
            text: 'world',
          ),
        ],
      ),
      const LyricLine(
        time: Duration(seconds: 4),
        text: 'second line',
      ),
    ];

    final model = convertToFlutterLyricModel(lyrics);

    expect(model.lines, hasLength(2));
    final words = model.lines.first.words;
    expect(words, isNotNull);
    expect(words, hasLength(2));
    expect(words![0].text, 'hello ');
    expect(words[0].start, const Duration(seconds: 1));
    expect(words[0].end, const Duration(milliseconds: 1500));
    expect(words[1].text, 'world');
    expect(words[1].start, const Duration(milliseconds: 1500));
    expect(words[1].end, const Duration(milliseconds: 2200));

    // 无逐字时间的行 words 为空，行结束时间取下一行起点
    expect(model.lines[1].words ?? const [], isEmpty);
    expect(model.lines[0].end, const Duration(seconds: 4));
  });

  test('showTranslation/showRomanization 控制副文本', () {
    final lyrics = [
      const LyricLine(
        time: Duration.zero,
        text: 'line',
        translation: '翻译',
        romanization: 'luo ma yin',
      ),
    ];

    expect(convertToFlutterLyricModel(lyrics).lines.first.translation, '翻译');
    expect(
      convertToFlutterLyricModel(
        lyrics,
        showTranslation: false,
        showRomanization: true,
      ).lines.first.translation,
      'luo ma yin',
    );
    expect(
      convertToFlutterLyricModel(lyrics, showTranslation: false).lines.first.translation,
      isNull,
    );
  });
}
