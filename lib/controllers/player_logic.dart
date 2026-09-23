import 'dart:convert';
import 'dart:math' as math;

import '../models/music_models.dart';

/// PlayerController 提取出的无状态纯逻辑。
///
/// 这些函数只依赖入参、不触碰控制器任何可变状态（this），
/// 算法与提取前逐字符等价，行为由 test/controllers/player_logic_test.dart 锁定。

/// 歌词定位与行时长估算。
abstract final class PlayerLyricLogic {
  /// 定位 [position] 所处歌词行下标：空歌词返回 -1，
  /// 第一行之前返回 0，其余返回时间点不晚于进度的最后一行。
  static int activeIndex(List<LyricLine> lyrics, Duration position) {
    if (lyrics.isEmpty) {
      return -1;
    }
    var index = 0;
    for (var i = 0; i < lyrics.length; i++) {
      if (position >= lyrics[i].time) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  /// 估算第 [index] 行的展示时长：显式时长 > 下一行起始间隔 > 歌曲尾段。
  static Duration? estimatedLineDuration(
    List<LyricLine> lyrics,
    Duration totalDuration,
    int index,
  ) {
    if (index < 0 || index >= lyrics.length) {
      return null;
    }
    final explicit = lyrics[index].duration;
    if (explicit != null && explicit > Duration.zero) {
      return explicit;
    }
    if (index + 1 < lyrics.length) {
      final nextDuration = lyrics[index + 1].time - lyrics[index].time;
      if (nextDuration > Duration.zero) {
        return nextDuration;
      }
    }
    if (totalDuration > lyrics[index].time) {
      final tailDuration = totalDuration - lyrics[index].time;
      if (tailDuration > Duration.zero) {
        return tailDuration;
      }
    }
    return null;
  }
}

/// 桌面歌词逐字进度换算（无状态纯逻辑）。
///
/// 桌面悬浮窗只接收一个 `[0,1]` 标量：子窗按**整行渲染宽度**做裁剪，所以
/// PC 上的"逐字"等价于把进度映射到**字符占比**而非时间占比。
///
/// 整行线性推进（elapsed / 行时长）在大段伴奏间隙、句中停顿、尾字长音上
/// 会提前点亮后面的字——这正是移动端海报页（真逐字裁剪，见
/// KaraokeLinePainter）与 PC 悬浮窗观感不一致的原因。有逐字时间时改用
/// 分段映射：字内线性推进、字间间隙停住不动。
abstract final class PlayerLyricProgressLogic {
  /// 计算 [line] 在 [position] 时点的进度（0..1）。
  ///
  /// - 有逐字时间：按字符占比分段映射（见类注释）；
  /// - 无逐字时间：按 [lineDuration]（缺省用 [LyricLine.duration]）整行线性推进；
  /// - 时长都不可得（<= 0）：返回 1.0（整行点亮，不留下永不完成的高亮）。
  static double forLine({
    required LyricLine line,
    required Duration position,
    Duration? lineDuration,
  }) {
    final fromWords = _fromWords(line.words, line.text.length, position);
    if (fromWords != null) return fromWords;

    final resolved = lineDuration ?? line.duration;
    final totalMs = resolved?.inMilliseconds ?? 0;
    if (totalMs <= 0) return 1.0;
    final elapsed = position.inMilliseconds - line.time.inMilliseconds;
    return (elapsed / totalMs).clamp(0.0, 1.0);
  }

  /// 逐字分段映射。返回 null 表示逐字数据不可用（无字/无有效文本），
  /// 由调用方退回整行线性推进。
  static double? _fromWords(
    List<LyricWord> words,
    int lineLength,
    Duration position,
  ) {
    if (words.isEmpty || lineLength <= 0) return null;
    var wordsLength = 0;
    for (final word in words) {
      wordsLength += word.text.length;
    }
    if (wordsLength <= 0) return null;

    // 占比分母用整行字符数：裁剪按整行渲染宽度计算，用整行长度才能与
    // 实际裁剪位置对齐。
    var prefix = 0;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final startFrac = (prefix / lineLength).clamp(0.0, 1.0);
      final endFrac = ((prefix + word.text.length) / lineLength).clamp(0.0, 1.0);
      final wordStartMs = word.time.inMilliseconds;

      if (position.inMilliseconds < wordStartMs) {
        // 落在上一字结束到本字开始之间的间隙（或整行开头）：停住不动。
        return startFrac;
      }
      final spanMs = word.duration.inMilliseconds;
      if (spanMs > 0 && position.inMilliseconds < wordStartMs + spanMs) {
        final ratio = (position.inMilliseconds - wordStartMs) / spanMs;
        return (startFrac + (endFrac - startFrac) * ratio).clamp(0.0, 1.0);
      }
      // 本字已唱完（duration<=0 视为瞬时完成）：末字之后整行补齐，
      // 覆盖未被逐字数据包含的尾部（标点等），不留半亮状态。
      if (i == words.length - 1) return 1.0;
      prefix += word.text.length;
    }
    return 1.0;
  }
}

/// 歌词进度偏移（无状态纯逻辑）。
///
/// 语义：偏移为正 = 歌词提前。定位时用 `播放位置 + 偏移` 去比对歌词行时间，
/// 于是 +0.5s 让真实进度 10.0s 处显示 10.5s 那一句（提前 0.5 秒唱）。
abstract final class PlayerLyricOffsetLogic {
  /// 夹取偏移到 ±[limit]。
  static Duration clamp(Duration value, Duration limit) {
    if (value > limit) return limit;
    if (value < -limit) return -limit;
    return value;
  }

  /// 秒数文案：整数不带小数（`1 秒`），非整数保留一位（`0.5 秒`）。
  static String formatSeconds(Duration value) {
    final milliseconds = value.inMilliseconds.abs();
    final seconds = milliseconds / 1000;
    final text = seconds == seconds.roundToDouble()
        ? seconds.round().toString()
        : seconds.toStringAsFixed(1);
    return '$text 秒';
  }

  /// 完整描述：`歌词提前 0.5 秒` / `歌词延后 1 秒` / `无偏移`。
  static String describe(Duration value) {
    if (value == Duration.zero) return '无偏移';
    final direction = value > Duration.zero ? '提前' : '延后';
    return '歌词$direction ${formatSeconds(value)}';
  }

  /// 短读数（面板大读数 / 详情宫格副标题共用）：
  /// `+0.5 秒` / `−1 秒` / 零为 `0 秒`（减号用 U+2212，与排版数字对齐）。
  static String formatSigned(Duration value) {
    if (value == Duration.zero) return '0 秒';
    final sign = value > Duration.zero ? '+' : '−';
    return '$sign${formatSeconds(value)}';
  }
}

/// 进度换算。
abstract final class PlayerPositionLogic {  /// 把进度夹取到 [0, duration]；时长未知（<= 0）时只夹下界。
  static Duration clamp(Duration value, Duration duration) {
    if (value < Duration.zero) {
      return Duration.zero;
    }
    if (duration > Duration.zero && value > duration) {
      return duration;
    }
    return value;
  }
}

/// 曲末推进与重播判定（无状态纯逻辑）。
abstract final class PlayerPlaybackLogic {
  /// 系统播放键（通知栏/锁屏/耳机媒体键）在「引擎已到曲尾（completed）且
  /// 位置停在尾部」时是否应按「重播本曲」处理。
  ///
  /// 背景：移动端原生 just_audio 在 EOF 只把 processingState 置 completed、
  /// 不动 playing（陈旧 true），`play()` 首行 `if (playing) return` 会把
  /// 重新起播整体短路——通知栏/耳机的播放键在曲末按了毫无反应（应用内
  /// togglePlay 有专门的 completed 分支，系统媒体键路径此前直接透传）。
  ///
  /// 只在「位置停在尾部」时才回零重播：seekToAndPlay/_ensurePlaying 已把
  /// 位置定位到曲中（歌词点击、高潮试听）的 completed 状态必须原地续播，
  /// 不能被回零冲掉。时长未知（<= 0）时按重播处理——此时续播只会瞬间再次
  /// completed，听感等于没反应。
  ///
  /// 容差取 1s（而非 220ms 级判距）：引擎 position 回调有颗粒度
  /// （Android 约 0.5~1s 一跳），completed 到达时上报位置可能滞后真实
  /// 尾部近 1s；容差过窄会导致“位置差几百 ms → 不回零 → play() 被陈旧
  /// playing 短路 → 通知栏播放键按了没反应”。曲中定位（seekToAndPlay）
  /// 落在尾部 1s 内的概率可忽略，误回零风险远小于按键失灵。
  static bool shouldRestartTrackOnPlay({
    required bool completed,
    required Duration? duration,
    required Duration position,
  }) {
    if (!completed) return false;
    if (duration == null || duration <= Duration.zero) return true;
    return position >= duration - const Duration(seconds: 1);
  }

  /// 曲末停滞 watchdog 判定：兜底 timer 建立后，引擎位置是否自基准
  /// [builtAt] 起原地停滞（控制器仍在播、位置在 ±[positionEpsilon] 内
  /// 纹丝不动）。
  ///
  /// 实机形态：CDN 尾部断供时引擎位置冻结在曲尾前 1~2 秒、playerState
  /// 停在 ready/buffering——completed 永远不来，位置也不再触发新的兜底
  /// 窗口（remaining > 750ms），队列永久停在曲尾。控制器不在播（用户
  /// 暂停）时恒为不停滞：暂停停在曲尾不得被误判为播完而自动切歌。
  static bool isTailStalled({
    required bool ctrlPlaying,
    required Duration builtAt,
    required Duration now,
    Duration positionEpsilon = const Duration(milliseconds: 150),
  }) {
    if (!ctrlPlaying) return false;
    return (now - builtAt).inMilliseconds.abs() <=
        positionEpsilon.inMilliseconds;
  }
}

/// 音质降级档位。
abstract final class PlayerQualityLogic {
  /// 返回更低一档的音质；已是最低档时返回 null。
  static AudioQuality? nextLowerQuality(AudioQuality quality) {
    switch (quality) {
      case AudioQuality.lossless:
        return AudioQuality.high;
      case AudioQuality.high:
        return AudioQuality.standard;
      case AudioQuality.standard:
        return null;
    }
  }
}

/// 均衡器频段换算与持久化恢复。
abstract final class PlayerEqualizerLogic {
  /// 把 [source] 的增益等级重采样到 [count] 个频段。
  static List<int> levelsForBandCount(List<int> source, int count) {
    if (count <= 0) {
      return const [];
    }
    if (source.length == count) {
      return List<int>.of(source);
    }
    if (source.length == 1) {
      return List<int>.filled(count, source.first);
    }

    return [
      for (var index = 0; index < count; index++)
        source[((index / math.max(1, count - 1)) * (source.length - 1))
            .round()],
    ];
  }

  /// 从持久化 JSON 恢复均衡器等级；无效数据返回 [defaultLevels] 的拷贝。
  static List<int> restoreLevels(String? raw, List<int> defaultLevels) {
    if (raw == null || raw.isEmpty) {
      return List<int>.of(defaultLevels);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final levels = decoded
            .whereType<num>()
            .map((value) => value.round())
            .toList();
        if (levels.isNotEmpty) {
          return levelsForBandCount(levels, defaultLevels.length);
        }
      }
    } catch (_) {}
    return List<int>.of(defaultLevels);
  }
}
