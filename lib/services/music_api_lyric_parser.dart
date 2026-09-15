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
    // 空行是酷狗的占位记号（标题/Credits/纯音乐段等未覆盖行用空串占位），
    // 保留在 byIndex 中维持行序对齐信息；定时行没有位置意义且无内容，
    // 直接丢弃。
    return time == null ? (time: null, text: '') : null;
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

  // 1. 若变体数组原始长度与主歌词严格一致，说明各行已包含空串或占位行（如酷狗在
  // 标题行放入版权声明、制作人员及纯音乐段放入空串）。此时槽位已严格 1:1，
  // 绝不能先剔除版权声明行而破坏数组下标；版权声明行只需在赋值时滤除。
  if (variant.byIndex.length == lines.length) {
    final result = <int, String>{};
    for (var i = 0; i < lines.length; i++) {
      final text = variant.byIndex[i].trim();
      if (text.isEmpty ||
          _isLyricVariantHeaderRow(text) ||
          _sameLyricText(lines[i].text, text)) {
        continue;
      }
      result[i] = text;
    }
    _debugLyricLog(
      'indexedVariants(raw 1:1): lines=${lines.length} assigned=${result.length}',
    );
    return result;
  }

  // 轨道自带的声明/版权头行不对应任何歌词行（实测 "以下谐音标注由AI工具
  // 生产"、"腾讯享有本翻译作品的著作权"/"TME享有..."），先剔除——它们
  // 参与对齐会整体推移后面所有行。
  final padded = variant.byIndex
      .map((t) => t.trim())
      .where((t) => !_isLyricVariantHeaderRow(t))
      .toList();

  // 2. 酷狗对未覆盖的行（标题/Credits/纯音乐段）用空串占位。剔除头行后长度
  // 与主歌词一致时，说明头行是额外插入行，剔除后空占位本身就是精确对齐信息：直接 1:1。
  if (padded.length == lines.length) {
    final result = <int, String>{};
    for (var i = 0; i < lines.length; i++) {
      final text = padded[i];
      if (text.isEmpty || _sameLyricText(lines[i].text, text)) {
        continue;
      }
      result[i] = text;
    }
    _debugLyricLog(
      'indexedVariants(padded 1:1): lines=${lines.length} assigned=${result.length}',
    );
    return result;
  }

  // 长度不一致：非空行进入锚点对齐 / 旧启发式。
  final rows = padded.where((t) => t.isNotEmpty).toList();
  if (rows.isEmpty || lines.isEmpty) {
    return const {};
  }

  // 锚点对齐（见 _alignVariantRowsToLines）：变体轨与主歌词的行数经常
  // 不一致（Credits 覆盖范围不同、声明头、跳过空行），固定偏移量无法
  // 对上；锚点驱动的全局对齐可吸收任意插入/缺失。无锚点时回退旧启发式。
  final aligned = _alignVariantRowsToLines(rows, lines);
  if (aligned != null) {
    final result = <int, String>{};
    aligned.forEach((lineIndex, rowIndex) {
      if (_sameLyricText(lines[lineIndex].text, rows[rowIndex])) {
        return;
      }
      result[lineIndex] = rows[rowIndex];
    });
    _debugLyricLog(
      'indexedVariants(aligned): lines=${lines.length} rows=${rows.length} assigned=${result.length}',
    );
    return result;
  }

  final result = <int, String>{};

  // 旧固定偏移启发式（无锚点时的兜底）：
  // 开头有空条目（对应制作人员信息行）则直接按 padded 索引从前往后对齐，否则收尾对齐。
  final leadingEmpty = padded.takeWhile((t) => t.isEmpty).length;
  final offset = leadingEmpty > 0
      ? 0
      : (lines.length - padded.length).clamp(0, lines.length);

  _debugLyricLog(
    'indexedVariants(legacy): lines=${lines.length} padded=${padded.length} leadingEmpty=$leadingEmpty offset=$offset',
  );

  for (var i = 0; i < padded.length; i++) {
    final lineIndex = i + offset;
    if (lineIndex >= lines.length) break;

    final text = padded[i];
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

/// 变体行与主歌词行的全局序列对齐（Needleman–Wunsch）。
///
/// 返回 行索引 → 变体行索引 的配对；没有任何可信锚点时返回 null（调用
/// 方回退旧的固定偏移启发式——盲猜也比被单个巧合锚点带偏好）。
///
/// 背景：谐音/音译变体轨与主歌词行数常不一致——Credits 段覆盖范围不同、
/// 变体轨自带声明头、纯英文行无条目、两侧各自跳过空行——单一偏移量必然
/// 错位（实测某粤语歌整体错 8~9 行，每行显示上一句的谐音）。序列对齐用
/// 锚点把可信区段锁死，空位罚分让无锚点区段（纯中文 ↔ 谐音，文本上无法
/// 互认）沿用邻近锚点的相对位置，天然吸收中间的插入/缺失。
Map<int, int>? _alignVariantRowsToLines(
  List<String> rows,
  List<LyricLine> lines,
) {
  final rowCount = rows.length;
  final lineCount = lines.length;

  // "纯拉丁行跳行"惩罚开关：谐音/粤拼轨对纯英文行（无汉字可转写）不生成
  // 条目，对齐时必须在这些行上空一格而不是推移后续行。仅当轨道的汉字行
  // 数与主歌词的汉字行数相当（≤）且主歌词确有纯拉丁行时启用——若轨道
  // 对每行都有内容（如给英文行配了中文翻译的正常翻译轨），惩罚会伤及
  // 正确配对，必须关闭。
  final linesWithHan = lines
      .where((line) => _hasHanRune(line.text))
      .length;
  final rowsWithHan = rows.where(_hasHanRune).length;
  final penalizeLatinOnlyLines =
      lineCount > linesWithHan && rowsWithHan <= linesWithHan;

  // 逐对打分并统计锚点数。
  final scores = List.generate(
    rowCount,
    (_) => List.filled(lineCount, 0),
    growable: false,
  );
  var anchorPairs = 0;
  for (var r = 0; r < rowCount; r++) {
    for (var l = 0; l < lineCount; l++) {
      final score = _variantPairScore(
        rows[r],
        lines[l].text,
        penalizeLatinOnlyLines: penalizeLatinOnlyLines,
      );
      scores[r][l] = score;
      if (score > 0) anchorPairs++;
    }
  }
  if (anchorPairs < 1) return null;

  const gapPenalty = -1;
  final dp = List.generate(
    rowCount + 1,
    (_) => List.filled(lineCount + 1, 0),
    growable: false,
  );
  for (var i = 1; i <= rowCount; i++) {
    dp[i][0] = i * gapPenalty;
  }
  for (var j = 1; j <= lineCount; j++) {
    dp[0][j] = j * gapPenalty;
  }
  for (var i = 1; i <= rowCount; i++) {
    for (var j = 1; j <= lineCount; j++) {
      final diagonal = dp[i - 1][j - 1] + scores[i - 1][j - 1];
      final skipRow = dp[i - 1][j] + gapPenalty;
      final skipLine = dp[i][j - 1] + gapPenalty;
      var best = diagonal;
      if (skipRow > best) best = skipRow;
      if (skipLine > best) best = skipLine;
      dp[i][j] = best;
    }
  }

  // 回溯（对角优先，保证无得分差异时按原始顺序 1:1 走）。
  final pairs = <int, int>{};
  var i = rowCount;
  var j = lineCount;
  while (i > 0 && j > 0) {
    if (dp[i][j] == dp[i - 1][j - 1] + scores[i - 1][j - 1]) {
      pairs[j - 1] = i - 1;
      i--;
      j--;
    } else if (dp[i][j] == dp[i - 1][j] + gapPenalty) {
      i--;
    } else {
      j--;
    }
  }
  return pairs;
}

/// 变体行与主歌词行的匹配得分：0 = 无证据，-1 = 轻度反证。
///
/// - 文本（去符号压缩后）完全相同 → 强锚点。外文歌的"音译"轨就是原文，
///   这种行大量存在且位置可信。
/// - 主歌词行里的英文/数字片段在变体行中原样保留 → 锚点。谐音/粤拼
///   通常只转写汉字，原文的 "@S.A.G"、"love is gone"、人名等片段会
///   原样留在变体行里，可据此互认（实测 Credits 行与混排英文行都有）。
/// - [penalizeLatinOnlyLines] 开启时，纯拉丁行（无汉字，无从转写）配
///   任何非原文行 → -1。谐音/粤拼轨对纯英文行不生成条目，这个轻罚把
///   对齐的"空档"推到英文行上，而不是错推前后行（实测 Just leave me
///   alone 行的空档被放错到上一行，导致其后整体错一行）。
int _variantPairScore(
  String rowText,
  String lineText, {
  required bool penalizeLatinOnlyLines,
}) {
  final compactRow = _compactLyricText(rowText);
  final compactLine = _compactLyricText(lineText);
  if (compactRow.isNotEmpty && compactRow == compactLine) {
    return 3;
  }
  final anchors = _latinAnchors(lineText);
  if (anchors.isNotEmpty) {
    final rowLower = rowText.toLowerCase().replaceAll(' ', '');
    var matched = true;
    for (final anchor in anchors) {
      if (!rowLower.contains(anchor)) {
        matched = false;
        break;
      }
    }
    if (matched) return 2;
  }
  if (penalizeLatinOnlyLines && !_hasHanRune(lineText)) {
    return -1;
  }
  return 0;
}

bool _hasHanRune(String text) {
  for (final rune in text.runes) {
    if (_isHanRune(rune)) return true;
  }
  return false;
}

/// 提取一行里的拉丁锚点片段（小写、去空格、长度 ≥ 4 的连续
/// [字母数字.@/&] 串）。片段越小越容易在粤拼串里碰巧出现，4 是实测
/// （@s.a.g / vhypher / sean / loveisgone）下够用且不误报的下限。
List<String> _latinAnchors(String text) {
  final matches = RegExp(
    r'[a-z0-9][a-z0-9.@/&]*',
  ).allMatches(text.toLowerCase());
  return matches
      .map((m) => m.group(0)!)
      .where((token) => token.length >= 4)
      .toList();
}

bool _sameLyricText(String a, String b) {
  return _compactLyricText(a) == _compactLyricText(b);
}

/// 轨道自带的声明/版权头行：不对应任何歌词行，参与对齐会把后续行整体
/// 推移（实测 "以下谐音标注由AI工具生产"、"腾讯/TME 享有本翻译作品的
/// 著作权"）。
bool _isLyricVariantHeaderRow(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  return trimmed.contains('谐音标注') ||
      (trimmed.contains('著作权') && trimmed.contains('享有'));
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
