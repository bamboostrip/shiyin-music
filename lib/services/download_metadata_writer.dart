import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/music_models.dart';
import 'audio_file_format.dart';
import 'flac_tag_writer.dart';
import 'id3_tag_writer.dart';
import 'lrc_formatter.dart';

/// 一次下载收尾的写入结果（供调用方决定要不要提示「歌词已另存」）。
class DownloadMetadataResult {
  const DownloadMetadataResult({
    required this.tagsWritten,
    required this.lyricsEmbedded,
    required this.sidecarWritten,
  });

  /// 标签是否写成功（MP3 走 ID3v2.3，FLAC 走 Vorbis comment）。
  final bool tagsWritten;

  /// 歌词是否真的写进了音频文件（[tagsWritten] 为假时必然为假）。
  final bool lyricsEmbedded;

  /// 是否另外落了一份同名 `.lrc`。
  final bool sidecarWritten;
}

/// 用户下载的音频在「入库前」统一收尾：写标签、写歌词、按需留 `.lrc`。
///
/// 移植自上游 3.3.0 `d688884`（`lib/services/download_metadata_writer.dart`），
/// 按本 fork 的两条硬约束裁剪：
///
/// - **不引入 `audio_metadata_reader`**。上游用它回读原文件已有标签补齐
///   专辑名/内嵌歌词，本 fork 明令禁止该依赖（见 `id3_tag_writer.dart` 与
///   `local_lyrics_service.dart` 顶部说明：内嵌歌词统一走 Rust /
///   MethodChannel）。缺的字段就不写，不影响主流程。
/// - **不联网取封面**。上游在缺封面时 `http.get` 拉一次（4s 超时）；本 fork
///   的封面已由 [ImageDiskCache] 落到磁盘，调用方读好字节传进来，拿不到就
///   跳过封面帧——下载链路对弱网/离线也必须能正常收尾。
///
/// 顺序上刻意「先标签、后边文件」：标签写失败（格式不支持/文件被占用）时
/// 仍会把歌词落到 `.lrc`，用户至少还能拿到歌词。
abstract final class DownloadMetadataWriter {
  /// 执行收尾。[filePath] 必须是**已完整落盘**的文件。
  static Future<DownloadMetadataResult> write({
    required String filePath,
    required Song song,
    String? lyricsText,
    bool saveLyricsFile = false,
    Uint8List? coverBytes,
  }) async {
    var tagsWritten = false;
    var cover = coverBytes;
    if (cover != null && !_isCoverImage(cover)) cover = null;
    final hasLyrics = lyricsText != null && lyricsText.trim().isNotEmpty;

    try {
      // 按**字节**而不是扩展名分派：服务端可能降级下发别的编码，
      // 而扩展名在请求音质时就定死了（见 audio_file_format.dart）。
      final format = await inspectAudioFile(filePath);
      switch (format.format) {
        case AudioFileFormat.mp3:
          tagsWritten = await Id3TagWriter.injectMetadata(
            filePath: filePath,
            song: song,
            coverBytes: cover,
            lyricsText: hasLyrics ? lyricsText : null,
          );
        case AudioFileFormat.flac:
          tagsWritten = await FlacTagWriter.injectMetadata(
            filePath: filePath,
            song: song,
            coverBytes: cover,
            lyricsText: hasLyrics ? lyricsText : null,
          );
        case AudioFileFormat.unsupported:
          // AAC/APE/WAV 等保持原样不动，歌词仍可通过 `.lrc` 使用。
          break;
      }
    } catch (error) {
      debugPrint('[Download] 嵌入元数据失败（已忽略）: $error');
    }

    var sidecarWritten = false;
    // 内嵌成功且用户没要求留副本时不再多写一个文件：`.lrc` 只是
    // 「标签写不进去」时的退路，以及用户显式勾选的可移植副本。
    if (hasLyrics && (saveLyricsFile || !tagsWritten)) {
      final sidecar = File(lyricsFilePath(filePath));
      final temporary = File('${sidecar.path}.tmp');
      try {
        await temporary.writeAsString(
          lyricsText,
          encoding: utf8,
          flush: true,
        );
        await temporary.rename(sidecar.path);
        sidecarWritten = true;
      } catch (error) {
        debugPrint('[Download] 写入 LRC 失败（已忽略）: $error');
      } finally {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
    }

    return DownloadMetadataResult(
      tagsWritten: tagsWritten,
      lyricsEmbedded: hasLyrics && tagsWritten,
      sidecarWritten: sidecarWritten,
    );
  }

  /// 与音频同名的 `.lrc` 路径（`a/b.mp3` → `a/b.lrc`）。
  ///
  /// 只按最后一个 `.` 截断：目录名里有点（`v1.2/song.mp3`）时不能误伤。
  static String lyricsFilePath(String filePath) {
    final slash = filePath.lastIndexOf(RegExp(r'[/\\]'));
    final dot = filePath.lastIndexOf('.');
    final stem = dot > slash ? filePath.substring(0, dot) : filePath;
    return '$stem.lrc';
  }

  static bool _isCoverImage(Uint8List bytes) =>
      (bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47 &&
          bytes[4] == 0x0d &&
          bytes[5] == 0x0a &&
          bytes[6] == 0x1a &&
          bytes[7] == 0x0a) ||
      (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff);
}

/// 歌词列表 → 可写进音频/`.lrc` 的 LRC 文本。
///
/// 与系统媒体会话用的 [LrcFormatter.buildFullLrc] 有两点刻意的差异：
/// - **带上翻译行**（原文一行、译文紧跟一行）：下载出去的文件主要给
///   第三方播放器看，它们只认一份 `LYRICS`/`.lrc`，不像本 App 有独立的
///   翻译字段；
/// - 换行与空行容错：标签里塞进裸 `\n` 会让部分车机解析出错。
String downloadLyricsText(List<LyricLine> lyrics) {
  final lines = <String>[];
  for (final line in lyrics) {
    final stamp = '[${LrcFormatter.formatTimestamp(line.time)}]';
    for (final text in [line.text, line.translation]) {
      if (text == null || text.trim().isEmpty) continue;
      lines.add('$stamp${text.replaceAll(RegExp(r'[\r\n]+'), ' ')}');
    }
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}
