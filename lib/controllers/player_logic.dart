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

/// 进度换算。
abstract final class PlayerPositionLogic {
  /// 把进度夹取到 [0, duration]；时长未知（<= 0）时只夹下界。
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
