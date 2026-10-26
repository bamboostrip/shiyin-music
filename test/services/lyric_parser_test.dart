import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 移植自上游 kgka_Music_hl 3.2.0 `bf264d9`（KRC language 空行对齐与直接索引）。
///
/// 关键行为：
/// 1. `[language:...]` 变体轨的 `lyricContent` 行序与「原始 KRC 时间标签行」
///    严格 1:1，空数组行（`[]`）是占位记号，必须保留，不能丢弃；
/// 2. 变体行数 == 原始 KRC 行数时，按原始行号直接挂 translation/romanization，
///    而不是按「跳过了空文本行之后的歌词行」下标对齐；
/// 3. 只有 `[数字, 文本]` 的双元素行才是定时行，多列脏行/数字字符串首元素
///    不得被误判成时间戳。
void main() {
  group('KRC language 空行占位与音译逐词空格（上游用例）', () {
    test('空数组行保留占位，翻译/音译按原始行号逐行对齐', () {
      final languageJson = {
        'content': [
          {
            'type': 1,
            'lyricContent': [
              <String>[],
              ['第一句翻译'],
              [''],
              ['第三句翻译'],
            ],
          },
          {
            'type': 0,
            'lyricContent': [
              <String>[],
              ['Day ', 'by ', 'day ', 'u', 'n', 'za', 'ri'],
              [' '],
              ['sa ', 'yo', 'na', 'ra'],
            ],
          },
        ],
      };
      final krc =
          '''
[language:${_encodeLanguage(languageJson)}]
[0,1000]<0,500,0>作词：测试
[1000,2000]<0,500,0>Day by day うんざり
[3000,1500]<0,500,0>(I say I say my heaven)
[4500,2000]<0,500,0>さよなら
''';

      final parsed = parseLyrics(krc);
      expect(parsed.length, 4);
      expect(parsed[0].translation, isNull);
      expect(parsed[0].romanization, isNull);
      expect(parsed[1].translation, '第一句翻译');
      expect(parsed[1].romanization, 'Day by day unzari');
      expect(parsed[2].translation, isNull);
      expect(parsed[2].romanization, isNull);
      expect(parsed[3].translation, '第三句翻译');
      expect(parsed[3].romanization, 'sa yonara');
    });
  });

  group('KRC 原始行号直接索引', () {
    test('原始 KRC 行有空文本（纯音乐段标记）时，后续翻译/音译不错位', () {
      // 4 个原始 KRC 行，其中第 3 行（[3000,1000]）没有歌词文本，解析后会被
      // 跳过；变体轨仍有 4 行（含占位）。必须按原始行号挂载，否则第三句
      // 歌词会拿到「纯音乐段占位」。
      final languageJson = {
        'content': [
          {
            'type': 1,
            'lyricContent': [
              <String>[],
              ['译文一'],
              ['纯音乐段占位'],
              ['译文四'],
            ],
          },
          {
            'type': 0,
            'lyricContent': [
              <String>[],
              ['roman one'],
              ['roman placeholder'],
              ['roman four'],
            ],
          },
        ],
      };
      final krc =
          '''
[language:${_encodeLanguage(languageJson)}]
[0,1000]<0,300,0>作词：测试
[1000,1000]<0,500,0>第一句歌词
[3000,1000]
[4000,1000]<0,500,0>第四句歌词
''';

      final parsed = parseLyrics(krc);
      expect(parsed.length, 3);
      expect(parsed[0].text, '作词：测试');
      expect(parsed[1].text, '第一句歌词');
      expect(parsed[2].text, '第四句歌词');
      // 空文本原始行没有对应歌词行，其占位不参与显示。
      expect(parsed[0].translation, isNull);
      expect(parsed[0].romanization, isNull);
      expect(parsed[1].translation, '译文一');
      expect(parsed[1].romanization, 'roman one');
      expect(parsed[2].translation, '译文四');
      expect(parsed[2].romanization, 'roman four');
    });
  });

  group('_parseKrcLanguageRow 空行/脏行行为（经 parseLyrics 入口）', () {
    test('多列脏行不当作定时行（只有 [数字, 文本] 双元素行才取时间）', () {
      final languageJson = {
        'content': [
          {
            'type': 1,
            'lyricContent': [
              [1000, '时间戳译文', '多余列'],
              ['索引译文'],
            ],
          },
        ],
      };
      final krc =
          '''
[language:${_encodeLanguage(languageJson)}]
[0,1000]<0,500,0>第一句
[2000,1000]<0,500,0>第二句
''';

      final parsed = parseLyrics(krc);
      expect(parsed.length, 2);
      // 旧的 `row.length > 1 ? asInt(row[0])` 会把 1000 当时间戳，只在
      // 1000ms 上挂「时间戳译文」；新规则把它当索引行整行保留。
      expect(parsed[0].translation, '1000 时间戳译文 多余列');
      expect(parsed[1].translation, '索引译文');
    });

    test('[时间戳, 文本] 双元素行仍按时间挂载', () {
      final languageJson = {
        'content': [
          {
            'type': 1,
            'lyricContent': [
              [1000, '时间戳译文'],
              ['索引译文'],
            ],
          },
        ],
      };
      final krc =
          '''
[language:${_encodeLanguage(languageJson)}]
[1000,1000]<0,500,0>第一句
[4000,1000]<0,500,0>第二句
''';

      final parsed = parseLyrics(krc);
      expect(parsed.length, 2);
      expect(parsed[0].time, const Duration(milliseconds: 1000));
      expect(parsed[0].translation, '时间戳译文');
      expect(parsed[1].translation, '索引译文');
    });

    test('变体行数与原始行数不一致时不启用直接索引，退回既有对齐', () {
      // 只有 1 行翻译对应 2 行歌词：不能按原始行号直接挂到第 0 行。
      final languageJson = {
        'content': [
          {
            'type': 1,
            'lyricContent': [
              ['唯一译文'],
            ],
          },
        ],
      };
      final krc =
          '''
[language:${_encodeLanguage(languageJson)}]
[0,1000]<0,500,0>第一句
[2000,1000]<0,500,0>第二句
''';

      final parsed = parseLyrics(krc);
      expect(parsed.length, 2);
      expect(parsed[0].translation, isNull);
      expect(parsed[1].translation, '唯一译文');
    });
  });

  group('LRC 路径回归', () {
    test('同时间戳的原文+翻译仍合并到同一行', () {
      final parsed = parseLyrics('''
[00:01.00]原文
[00:01.00]翻译
[00:02.00]第二句
''');
      expect(parsed.length, 2);
      expect(parsed[0].text, '原文');
      expect(parsed[0].translation, '翻译');
      expect(parsed[1].text, '第二句');
      expect(parsed[1].translation, isNull);
    });
  });
}

String _encodeLanguage(Map<String, Object?> json) {
  return base64.encode(utf8.encode(jsonEncode(json)));
}
