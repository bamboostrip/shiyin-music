part of 'music_api.dart';

/// 歌词解析（LRC / KRC / 翻译与音译变体合并）及调试日志，纯函数。
List<LyricLine> parseLyrics(String? content) {
  if (content == null || content.trim().isEmpty) {
    return const [];
  }

  final normalized = content
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n');
  final krcLines = _parseKrc(normalized);
  final parsed = krcLines.isNotEmpty
      ? krcLines
      : _mergeSameTimeTranslation(_parseLrc(normalized));
  if (parsed.isEmpty) {
    return const [];
  }

  final variants = _parseLyricVariants(originalContent: normalized);
  return _mergeLyricVariants(parsed, variants);
}

/// 合并同一时间戳的相邻歌词行。
///
/// LRC 歌词常见的“原文 + 翻译”写法是两行共用同一个时间戳，
/// 不合并的话翻译会被当成独立的歌词行（有自己独立的卡拉OK进度），
/// 导致原文瞬间被跳过、翻译进度对不上。这里把第二行并入第一行的
/// [LyricLine.translation]，与 KRC language 标签的处理保持一致。
List<LyricLine> _mergeSameTimeTranslation(List<LyricLine> lines) {
  if (lines.length < 2) {
    return lines;
  }
  final merged = <LyricLine>[];
  for (final line in lines) {
    final last = merged.isNotEmpty ? merged.last : null;
    if (last != null &&
        last.translation == null &&
        last.romanization == null &&
        line.time == last.time &&
        !_sameLyricText(last.text, line.text)) {
      merged[merged.length - 1] = last.copyWith(translation: line.text);
      continue;
    }
    merged.add(line);
  }
  return merged;
}

List<LyricLine> _parseKrc(String content) {
  final lines = <LyricLine>[];
  final offset = _extractOffset(content);
  final lineExpression = RegExp(r'^\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\](.*)$');
  final wordExpression = RegExp(r'<\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*>');

  for (final rawLine in content.split('\n')) {
    final match = lineExpression.firstMatch(rawLine.trim());
    if (match == null) {
      continue;
    }

    final start = int.tryParse(match.group(1) ?? '');
    final duration = int.tryParse(match.group(2) ?? '');
    if (start == null || duration == null) {
      continue;
    }

    final content = match.group(3) ?? '';
    final words = <LyricWord>[];
    final matches = wordExpression.allMatches(content).toList();
    for (var index = 0; index < matches.length; index++) {
      final wordMatch = matches[index];
      final wordStart = int.tryParse(wordMatch.group(1) ?? '') ?? 0;
      final wordDuration = int.tryParse(wordMatch.group(2) ?? '') ?? 0;
      final wordEnd = index + 1 < matches.length
          ? matches[index + 1].start
          : content.length;
      final wordText = content.substring(wordMatch.end, wordEnd);
      if (wordText.isEmpty) {
        continue;
      }
      words.add(
        LyricWord(
          time: Duration(
            milliseconds: (start + wordStart + offset)
                .clamp(0, 1 << 31)
                .toInt(),
          ),
          duration: Duration(
            milliseconds: wordDuration.clamp(0, 1 << 31).toInt(),
          ),
          text: wordText,
        ),
      );
    }

    final displayWords = _trimLyricWords(words);
    final text = displayWords.isEmpty
        ? content.replaceAll(wordExpression, '').trim()
        : displayWords.map((word) => word.text).join();
    if (text.isEmpty) {
      continue;
    }

    lines.add(
      LyricLine(
        time: Duration(
          milliseconds: (start + offset).clamp(0, 1 << 31).toInt(),
        ),
        duration: Duration(milliseconds: duration.clamp(0, 1 << 31).toInt()),
        text: text,
        words: displayWords,
      ),
    );
  }

  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

List<LyricWord> _trimLyricWords(List<LyricWord> words) {
  final result = words
      .map(
        (word) => LyricWord(
          time: word.time,
          duration: word.duration,
          text: word.text,
        ),
      )
      .toList();
  while (result.isNotEmpty && result.first.text.trim().isEmpty) {
    result.removeAt(0);
  }
  while (result.isNotEmpty && result.last.text.trim().isEmpty) {
    result.removeLast();
  }
  if (result.isEmpty) {
    return result;
  }
  result[0] = LyricWord(
    time: result[0].time,
    duration: result[0].duration,
    text: result[0].text.trimLeft(),
  );
  final lastIndex = result.length - 1;
  result[lastIndex] = LyricWord(
    time: result[lastIndex].time,
    duration: result[lastIndex].duration,
    text: result[lastIndex].text.trimRight(),
  );
  return result.where((word) => word.text.isNotEmpty).toList();
}

List<LyricLine> _parseLrc(String content) {
  final lines = <LyricLine>[];
  final offset = _extractOffset(content);
  final expression = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  for (final rawLine in content.split('\n')) {
    final matches = expression.allMatches(rawLine).toList();
    if (matches.isEmpty) {
      continue;
    }
    final text = rawLine.replaceAll(expression, '').trim();
    if (text.isEmpty) {
      continue;
    }
    for (final match in matches) {
      final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
      final fraction = match.group(3) ?? '0';
      final milliseconds = fraction.length == 3
          ? int.parse(fraction)
          : int.parse(fraction.padRight(3, '0'));
      lines.add(
        LyricLine(
          time: Duration(
            milliseconds:
                (Duration(
                          minutes: minutes,
                          seconds: seconds,
                          milliseconds: milliseconds,
                        ).inMilliseconds +
                        offset)
                    .clamp(0, 1 << 31)
                    .toInt(),
          ),
          text: text,
        ),
      );
    }
  }

  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

int _extractOffset(String content) {
  final match = RegExp(
    r'^\[offset:([+-]?\d+)\]',
    multiLine: true,
  ).firstMatch(content);
  return int.tryParse(match?.group(1) ?? '') ?? 0;
}

int _lyricContentScore(String content) {
  var score = 0;
  if (RegExp(
    r'^\[\s*-?\d+\s*,\s*-?\d+\s*\].*<',
    multiLine: true,
  ).hasMatch(content)) {
    score += 100;
  }
  if (RegExp(
    r'^\[\s*-?\d+\s*,\s*-?\d+\s*\]',
    multiLine: true,
  ).hasMatch(content)) {
    score += 60;
  }
  if (RegExp(r'\[\d{1,2}:\d{1,2}').hasMatch(content)) {
    score += 40;
  }
  if (content.contains('[language:')) {
    score += 10;
  }
  return score;
}

_ParsedLyricVariants _parseLyricVariants({required String originalContent}) {
  // decodedTranslation 是纯文本，没有行号/时间戳信息，无法与主歌词逐行对应。
  // 翻译/音译只从 decodedContent 中的 [language:...] 标签解析，
  // 其 lyricContent 下标与主歌词行序严格一致。
  final krcVariants = _parseKrcLanguageVariants(originalContent);
  return _ParsedLyricVariants(
    translation: krcVariants.translation,
    romanization: krcVariants.romanization,
  );
}

_ParsedLyricVariants _parseKrcLanguageVariants(String content) {
  final match = RegExp(
    r'^\[language:([A-Za-z0-9+/\-_]+=*)\]',
    multiLine: true,
  ).firstMatch(content);
  final encoded = match?.group(1);
  if (encoded == null || encoded.isEmpty) {
    return const _ParsedLyricVariants();
  }

  try {
    // [language:...] 标签中的 Base64 可能使用 URL-safe 变体，需要转换
    var normalized = encoded.replaceAll('-', '+').replaceAll('_', '/');
    final mod4 = normalized.length % 4;
    if (mod4 > 0) {
      normalized += '=' * (4 - mod4);
    }
    final decoded = utf8.decode(base64.decode(normalized));
    _debugLyricContent('language tag decoded', decoded);
    final json = jsonDecode(decoded);
    final translationByTime = <int, String>{};
    final translationByIndex = <String>[];
    final romanizationByTime = <int, String>{};
    final romanizationByIndex = <String>[];
    _collectKrcLanguageRows(
      json,
      translationByTime: translationByTime,
      translationByIndex: translationByIndex,
      romanizationByTime: romanizationByTime,
      romanizationByIndex: romanizationByIndex,
    );
    _debugLyricLog(
      'language: transByIndex=${translationByIndex.length} transByTime=${translationByTime.length} romanByIndex=${romanizationByIndex.length} romanByTime=${romanizationByTime.length}',
    );
    for (var i = 0; i < translationByIndex.length; i++) {
      final t = translationByIndex[i];
      if (t.isNotEmpty) {
        _debugLyricLog('language trans[$i]: "$t"');
      }
    }
    return _ParsedLyricVariants(
      translation: _TimedLyricVariant(
        byTime: translationByTime,
        byIndex: translationByIndex,
      ),
      romanization: _TimedLyricVariant(
        byTime: romanizationByTime,
        byIndex: romanizationByIndex,
      ),
    );
  } catch (_) {
    return const _ParsedLyricVariants();
  }
}

void _collectKrcLanguageRows(
  Object? value, {
  required Map<int, String> translationByTime,
  required List<String> translationByIndex,
  required Map<int, String> romanizationByTime,
  required List<String> romanizationByIndex,
}) {
  if (value is List) {
    for (final item in value) {
      _collectKrcLanguageRows(
        item,
        translationByTime: translationByTime,
        translationByIndex: translationByIndex,
        romanizationByTime: romanizationByTime,
        romanizationByIndex: romanizationByIndex,
      );
    }
    return;
  }
  if (value is! Map) {
    return;
  }

  final map = asMap(value);
  final sectionType = asInt(map['type']);
  final lyricContent = map['lyricContent'];
  if (lyricContent is List) {
    for (final row in lyricContent) {
      final parsedRow = _parseKrcLanguageRow(row, sectionType);
      if (parsedRow == null) {
        continue;
      }

      final byTime = sectionType == 0 ? romanizationByTime : translationByTime;
      final byIndex = sectionType == 0
          ? romanizationByIndex
          : translationByIndex;

      if (parsedRow.time != null) {
        byTime[parsedRow.time!] = parsedRow.text;
      } else {
        byIndex.add(parsedRow.text);
      }
    }
  }

  for (final child in map.values) {
    if (child is List || child is Map) {
      _collectKrcLanguageRows(
        child,
        translationByTime: translationByTime,
        translationByIndex: translationByIndex,
        romanizationByTime: romanizationByTime,
        romanizationByIndex: romanizationByIndex,
      );
    }
  }
}

({int? time, String text})? _parseKrcLanguageRow(
  Object? row,
  int? sectionType,
) {
  if (row is! List || row.isEmpty) {
    return null;
  }

  final time = row.length > 1 ? asInt(row[0]) : null;
  final values = row.map(asString).whereType<String>().toList();
  if (values.isEmpty) {
    return null;
  }

  final text = time != null && row.length > 1
      ? asString(row[1])
      : (sectionType == 0 ? values.join('') : values.join(' ').trim());
  if (text == null || text.isEmpty) {
    return null;
  }
  return (time: time, text: text);
}

List<LyricLine> _mergeLyricVariants(
  List<LyricLine> lines,
  _ParsedLyricVariants variants,
) {
  if (variants.isEmpty) {
    return lines;
  }

  final indexedTranslations = _indexedLyricVariants(
    lines,
    variants.translation,
  );
  final indexedRomanizations = _indexedLyricVariants(
    lines,
    variants.romanization,
  );
  final merged = <LyricLine>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final byTime = variants.translation.byTime[line.time.inMilliseconds];
    final nearest = _nearestLyricVariant(
      line.time.inMilliseconds,
      variants.translation.byTime,
    );
    final indexed = indexedTranslations[index];
    final trans = byTime ?? nearest ?? indexed;
    merged.add(
      line.copyWith(
        translation: trans,
        romanization:
            variants.romanization.byTime[line.time.inMilliseconds] ??
            _nearestLyricVariant(
              line.time.inMilliseconds,
              variants.romanization.byTime,
            ) ??
            indexedRomanizations[index],
      ),
    );
    if (trans != null && trans.isNotEmpty) {
      _debugLyricLog(
        'merge[$index]: "${line.text}" → "$trans" (byTime=$byTime nearest=$nearest indexed=$indexed)',
      );
    }
  }
  return merged;
}

Map<int, String> _indexedLyricVariants(
  List<LyricLine> lines,
  _TimedLyricVariant variant,
) {
  if (variant.byIndex.isEmpty) {
    return const {};
  }

  final result = <int, String>{};

  // 计算偏移量：
  // 如果翻译数组开头有空条目（对应制作人员信息行），则直接按索引对应。
  // 如果没有空条目（翻译只包含实际歌词），则需要偏移。
  final leadingEmpty = variant.byIndex
      .takeWhile((t) => t.trim().isEmpty)
      .length;
  final offset = leadingEmpty > 0
      ? 0
      : (lines.length - variant.byIndex.length).clamp(0, lines.length);

  _debugLyricLog(
    'indexedVariants: lines=${lines.length} variants=${variant.byIndex.length} leadingEmpty=$leadingEmpty offset=$offset',
  );

  for (var i = 0; i < variant.byIndex.length; i++) {
    final lineIndex = i + offset;
    if (lineIndex >= lines.length) break;

    final text = variant.byIndex[i].trim();
    if (text.isEmpty || _sameLyricText(lines[lineIndex].text, text)) {
      continue;
    }
    result[lineIndex] = text;
    _debugLyricLog(
      'indexedVariants[$i→$lineIndex]: "${lines[lineIndex].text}" → "$text"',
    );
  }

  _debugLyricLog('indexedVariants: assigned=${result.length} entries');
  return result;
}

bool _sameLyricText(String a, String b) {
  return _compactLyricText(a) == _compactLyricText(b);
}

String _compactLyricText(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    if (_isHanRune(rune) ||
        _isKanaRune(rune) ||
        _isHangulRune(rune) ||
        _isLatinRune(rune) ||
        (rune >= 0x30 && rune <= 0x39)) {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

bool _isHanRune(int rune) {
  return (rune >= 0x3400 && rune <= 0x4dbf) ||
      (rune >= 0x4e00 && rune <= 0x9fff) ||
      (rune >= 0xf900 && rune <= 0xfaff);
}

bool _isKanaRune(int rune) {
  return (rune >= 0x3040 && rune <= 0x30ff) ||
      (rune >= 0x31f0 && rune <= 0x31ff);
}

bool _isHangulRune(int rune) {
  return (rune >= 0x1100 && rune <= 0x11ff) ||
      (rune >= 0x3130 && rune <= 0x318f) ||
      (rune >= 0xac00 && rune <= 0xd7af);
}

bool _isLatinRune(int rune) {
  return (rune >= 0x41 && rune <= 0x5a) || (rune >= 0x61 && rune <= 0x7a);
}

String? _nearestLyricVariant(int time, Map<int, String> variants) {
  var bestDistance = 1 << 31;
  String? bestText;
  for (final entry in variants.entries) {
    final distance = (entry.key - time).abs();
    if (distance < bestDistance && distance <= 250) {
      bestDistance = distance;
      bestText = entry.value;
    }
  }
  return bestText;
}

class _ParsedLyricVariants {
  const _ParsedLyricVariants({
    this.translation = const _TimedLyricVariant(),
    this.romanization = const _TimedLyricVariant(),
  });

  final _TimedLyricVariant translation;
  final _TimedLyricVariant romanization;

  bool get isEmpty => translation.isEmpty && romanization.isEmpty;
}

class _TimedLyricVariant {
  const _TimedLyricVariant({this.byTime = const {}, this.byIndex = const []});

  final Map<int, String> byTime;
  final List<String> byIndex;

  bool get isEmpty => byTime.isEmpty && byIndex.isEmpty;
}

void _debugLyricLog(String message) {
  if (!AppConfig.debugLyrics || !kDebugMode) {
    return;
  }
  debugPrint('[时音][lyrics] $message');
}

void _debugLyricLogObject(String label, Object? value) {
  if (!AppConfig.debugLyrics || !kDebugMode) {
    return;
  }
  final text = const JsonEncoder.withIndent('  ').convert(value);
  _debugLyricContent(label, text);
}

void _debugLyricContent(String label, String content) {
  if (!AppConfig.debugLyrics || !kDebugMode) {
    return;
  }
  debugPrint('[时音][lyrics] ==== $label ====');
  const chunkSize = 1800;
  for (var start = 0; start < content.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, content.length);
    debugPrint(content.substring(start, end));
  }
  debugPrint('[时音][lyrics] ==== end $label ====');
}
