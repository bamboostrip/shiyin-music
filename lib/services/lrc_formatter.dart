// 系统媒体会话歌词用的标准 LRC 格式化（纯函数，零 IO，便于单测）。
//
// 背景：上游 3.3.0（e9dde17 #134）把整首 LRC 内联拼在控制器里，仅在歌词行
// 变化时随 MediaSession extras 一起下发；fork 的播放器控制器已按职责拆分，
// 且要求「歌词列表换新才格式化一次、不随位置 tick 重复拼接」，故把规则收敛
// 到本文件：
//   1. 时间标签与 LRC 生态（Lyricon/LyricProvider/ColorOS 锁屏岛）互通；
//   2. 纯函数可脱离 AudioPlayer/平台通道单测（见
//      test/services/lrc_formatter_test.dart）。
import '../models/music_models.dart';

/// 歌词 → 标准 LRC 文本格式化器。
abstract final class LrcFormatter {
  /// 单行时间标签：`mm:ss.xx`（分钟至少两位、秒两位、厘秒两位）。
  ///
  /// - 负值按 0 处理（歌词偏移/脏数据不应产生 `[-01:00.00]` 这类非法标签）；
  /// - 毫秒**截断**到 10ms 一位（LRC 惯例），不做四舍五入——向上取整会让
  ///   相邻两行在高亮边界处竞争同一时刻；
  /// - 分钟不取 60 余：上游内联实现用 `inMinutes.remainder(60)`，超过 1 小时
  ///   的有声书/现场会回绕成 `[01:00.00]`，与标准 LRC（`mm` 允许 >59）及
  ///   播放器语义不符，这里按总分钟数输出（`[61:01.00]`）。
  static String formatTimestamp(Duration time) {
    final safe = time.isNegative ? Duration.zero : time;
    final minutes = safe.inMinutes.toString().padLeft(2, '0');
    final seconds = safe.inSeconds.remainder(60).toString().padLeft(2, '0');
    final centiseconds = (safe.inMilliseconds.remainder(1000) ~/ 10)
        .toString()
        .padLeft(2, '0');
    return '$minutes:$seconds.$centiseconds';
  }

  /// 把整首歌词格式化为标准 LRC 文本（`[mm:ss.xx]歌词正文`，行间 `\n`）。
  ///
  /// 返回 `null` 表示没有可下发的歌词（空列表），调用方据此清空元数据；
  /// 空文本行仍保留时间标签（与上游一致：间奏占位行需要时间轴连续）。
  /// 只输出原文，不混排翻译/音译——翻译走独立的 `translationLyric` 字段，
  /// 混进 LRC 正文会让按行解析的第三方歌词插件错位。
  static String? buildFullLrc(List<LyricLine> lines) {
    if (lines.isEmpty) return null;
    final buffer = StringBuffer();
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (index > 0) {
        buffer.write('\n');
      }
      buffer
        ..write('[')
        ..write(formatTimestamp(line.time))
        ..write(']')
        ..write(line.text);
    }
    return buffer.toString();
  }

  /// 时间标签：`[mm:ss]`、`[mm:ss.xx]`（毫秒 1~3 位也吃掉，兼容第三方 LRC）。
  static final RegExp _timestampTag = RegExp(
    r'\[[0-9]+:[0-9]{2}(?:[.:][0-9]{1,3})?\]',
  );

  /// 整首 LRC 去掉时间标签后的纯文本歌词（行结构保持不变）。
  ///
  /// 用途：部分车机/车机歌词 App 的歌词槽只接受**纯文本**，见到 `[00:12.34]`
  /// 会原样显示成"乱码"（issue #22 的实拍截图）；这类消费方拿到逐行纯文本至
  /// 少能按行显示。**空行（间奏占位）保留**——删空行会让按行号对齐 LRC 的
  /// 消费方整体错位。
  ///
  /// 返回 `null` 表示没有可用文本（null/空串/全是时间标签）。
  static String? toPlainText(String? lrc) {
    if (lrc == null || lrc.isEmpty) return null;
    final plain = lrc.split('\n').map((line) {
      // 行首可能叠了多个标签（`[00:01.00][00:02.00]正文`），全部剥掉。
      var text = line;
      while (true) {
        final match = _timestampTag.matchAsPrefix(text);
        if (match == null) break;
        text = text.substring(match.end);
      }
      return text.trimRight();
    }).join('\n');
    return plain.trim().isEmpty ? null : plain;
  }
}
