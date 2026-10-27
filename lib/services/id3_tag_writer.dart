import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/music_models.dart';

/// 为已落盘的 MP3 文件写入 ID3v2.3 标签（歌名 / 歌手 / 专辑 / 封面，可选歌词）。
///
/// 移植自上游 kgka_Music_hl 3.3.0（`e9dde17`，#122）的
/// `lib/services/id3_tag_writer.dart`，按本 fork 架构做了三处适配：
///
/// - **不自行联网下载封面**。上游在缺少封面字节时用 http 拉一次封面（4s
///   超时），本 fork 的封面已经由 [ImageDiskCache] 落到磁盘，封面字节统一由
///   调用方从磁盘缓存读好传入；拿不到就跳过 APIC 帧，绝不为写标签多打一次
///   网络请求（下载链路对弱网/离线也必须能正常收尾）。
/// - **不依赖任何音频元数据解析库**。本 fork 明令禁止引入 `audio_metadata_reader`
///   （见 `local_lyrics_service.dart` 顶部说明），这里只按 ID3v2.3 字节格式
///   写标签；读回校验由单测用最小字节断言完成。
/// - **失败一律静默降级**。标签注入只是「让第三方播放器/车机能看到元数据」的
///   锦上添花，任何异常（文件被占用、磁盘满、封面损坏）都返回 false 并只记
///   日志，绝不把已完整下载的音频判为失败，也不破坏原文件。
///
/// 写入策略（沿用上游）：
/// - 文件头已有 ID3v2 标签（v2.2 / v2.3 / v2.4）时，按头部 synchsafe 长度
///   整块跳过后再重写——二次注入是替换而非叠加，不会出现重复标签；
/// - 先写同目录临时文件（标签 + 原音频字节），再 rename 覆盖目标文件，
///   写一半被杀进程时原文件仍完整；
/// - 文本帧用 ID3v2.3 支持的 UTF-16LE + BOM（编码字节 0x01），中文不会乱码；
/// - APIC 只接受 PNG/JPEG（老播放器只认这两种 MIME），其他格式跳过。
class Id3TagWriter {
  Id3TagWriter._();

  /// 临时文件后缀：与目标文件同目录，保证 rename 是同一文件系统内的原子操作。
  static const String tempSuffix = '.id3.tmp';

  /// APIC 封面上限（字节）：超限则跳过封面帧。
  ///
  /// 封面缓存里偶尔会存整张扫描图（数 MB），塞进标签会让 MP3 体积翻倍，
  /// 车机/老播放器读取也慢；常规 640px 封面远小于此值。
  static const int maxCoverBytes = 4 * 1024 * 1024;

  /// 向 [filePath] 写入 ID3v2.3 标签，成功返回 true。
  ///
  /// 返回 false 的情形（均为静默降级，调用方无需视为错误）：
  /// - 文件不存在、不是 `.mp3`、没有任何可写字段；
  /// - 读写标签过程中出现任何异常。
  ///
  /// [coverBytes]：封面原始图片字节（PNG/JPEG），为 null 时不写 APIC；
  /// [lyricsText]：内嵌歌词文本，非空时写 USLT——本期下载链路不传（歌词
  /// 另走 local_lyrics_service/在线匹配），接口先保留。
  static Future<bool> injectMetadata({
    required String filePath,
    required Song song,
    Uint8List? coverBytes,
    String? lyricsText,
  }) async {
    // 双保险：调用方（DownloadService）已按扩展名过滤，这里再守一次，
    // 避免把 ID3v2.3 标签写进 FLAC 等需要 Vorbis comment 的格式。
    if (!filePath.toLowerCase().endsWith('.mp3')) return false;

    final file = File(filePath);
    try {
      if (!await file.exists()) return false;

      final frames = _buildFrames(
        song: song,
        coverBytes: coverBytes,
        lyricsText: lyricsText,
      );
      if (frames.isEmpty) return false;

      final fileLength = await file.length();
      // 现有标签整体替换：从 audioOffset 起才是纯音频字节。
      final audioOffset = await _existingTagEnd(file, fileLength);

      final tagBytes = BytesBuilder(copy: false)
        ..add(_buildId3Header(frames.length))
        ..add(frames);

      final tmp = File('$filePath$tempSuffix');
      var renamed = false;
      try {
        final sink = tmp.openWrite();
        try {
          sink.add(tagBytes.takeBytes());
          // 原音频字节原样拼在标签之后；分块流式拷贝，避免整首歌读进内存。
          if (audioOffset < fileLength) {
            await sink.addStream(file.openRead(audioOffset));
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        // 同目录 rename：POSIX/Windows 上都是「替换目标」的原子操作，
        // 失败时目标文件保持原样（此时只留下临时文件，由 finally 清理）。
        await tmp.rename(filePath);
        renamed = true;
        return true;
      } finally {
        if (!renamed) {
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {
            // 临时文件清理失败（被占用等）：不影响原文件，下次注入会覆盖它。
          }
        }
      }
    } catch (error) {
      debugPrint('[Id3TagWriter] 写入 ID3 标签失败（已忽略，不影响下载）: $error');
      return false;
    }
  }

  /// 组装全部帧；不需要写任何帧（字段全空且无封面/歌词）时返回空字节。
  static Uint8List _buildFrames({
    required Song song,
    Uint8List? coverBytes,
    String? lyricsText,
  }) {
    final frames = BytesBuilder(copy: false);

    // 文本帧：TIT2 歌名 / TPE1 歌手 / TALB 专辑（值为空时跳过该帧）。
    if (song.title.trim().isNotEmpty) {
      frames.add(_buildTextFrame('TIT2', song.title));
    }
    if (song.artist.trim().isNotEmpty) {
      frames.add(_buildTextFrame('TPE1', song.artist));
    }
    final albumName = song.albumName;
    if (albumName != null && albumName.trim().isNotEmpty) {
      frames.add(_buildTextFrame('TALB', albumName));
    }

    // APIC 封面：字节由调用方提供（本 fork 从封面磁盘缓存读，不联网）。
    final apic = coverBytes == null ? null : _buildApicFrame(coverBytes);
    if (apic != null) frames.add(apic);

    // USLT 内嵌歌词（可选，本期下载链路不传）。
    if (lyricsText != null && lyricsText.trim().isNotEmpty) {
      frames.add(_buildUsltFrame(lyricsText));
    }

    return frames.takeBytes();
  }

  /// 构建 ID3v2.3 标签头（10 字节）：`ID3` + 版本 0x03 0x00 + flags 0x00 +
  /// 28-bit synchsafe 标签数据长度（不含这 10 字节头）。
  static Uint8List _buildId3Header(int tagDataLength) {
    final header = Uint8List(10);
    header[0] = 0x49; // 'I'
    header[1] = 0x44; // 'D'
    header[2] = 0x33; // '3'
    header[3] = 0x03; // 主版本：ID3v2.3
    header[4] = 0x00; // 修订版本
    header[5] = 0x00; // flags：无 unsynchronisation / 无扩展头 / 无 footer
    header[6] = (tagDataLength >> 21) & 0x7F;
    header[7] = (tagDataLength >> 14) & 0x7F;
    header[8] = (tagDataLength >> 7) & 0x7F;
    header[9] = tagDataLength & 0x7F;
    return header;
  }

  /// 通用文本帧：编码字节 0x01（UTF-16 with BOM）+ UTF-16LE 文本字节。
  static Uint8List _buildTextFrame(String frameId, String text) {
    final payload = BytesBuilder(copy: false)
      ..addByte(0x01)
      ..add(_encodeUtf16LeWithBom(text));
    return _packFrame(frameId, payload.takeBytes());
  }

  /// APIC 封面帧；图片格式不受支持/超过 [maxCoverBytes] 时返回 null（跳过）。
  static Uint8List? _buildApicFrame(Uint8List imageBytes) {
    if (imageBytes.isEmpty || imageBytes.length > maxCoverBytes) return null;
    final mimeType = _imageMimeType(imageBytes);
    if (mimeType == null) return null;

    final payload = BytesBuilder(copy: false)
      // 编码字节：MIME 与描述都是 ASCII，用 ISO-8859-1 即可（APIC 专用语义）。
      ..addByte(0x00)
      ..add(ascii.encode(mimeType))
      ..addByte(0x00) // MIME 类型结束符
      ..addByte(0x03) // 图片类型：0x03 = Cover (front)
      ..addByte(0x00) // 描述文本（空）的结束符
      ..add(imageBytes);
    return _packFrame('APIC', payload.takeBytes());
  }

  /// USLT 非同步内嵌歌词帧。
  ///
  /// 结构：编码 0x01（UTF-16 with BOM）+ 3 字节语言码 `zho` + 内容描述
  /// （空，UTF-16 终止符 0x00 0x00）+ 歌词正文（UTF-16LE + BOM）。
  static Uint8List _buildUsltFrame(String lyrics) {
    final payload = BytesBuilder(copy: false)
      ..addByte(0x01)
      ..add(const <int>[0x7A, 0x68, 0x6F]) // 'zho'
      ..add(const <int>[0x00, 0x00]) // 空内容描述的 UTF-16 终止符
      ..add(_encodeUtf16LeWithBom(lyrics));
    return _packFrame('USLT', payload.takeBytes());
  }

  /// 打包一帧：4 字节帧 ID + 4 字节大端长度（**非** synchsafe）+ 2 字节 flags +
  /// 负载。帧长度只算负载，不含这 10 字节帧头。
  static Uint8List _packFrame(String frameId, Uint8List payload) {
    final frame = Uint8List(10 + payload.length);
    frame.setRange(0, 4, ascii.encode(frameId));
    final size = payload.length;
    frame[4] = (size >> 24) & 0xFF;
    frame[5] = (size >> 16) & 0xFF;
    frame[6] = (size >> 8) & 0xFF;
    frame[7] = size & 0xFF;
    frame[8] = 0x00; // flags1：无压缩/加密/分组
    frame[9] = 0x00; // flags2
    frame.setRange(10, frame.length, payload);
    return frame;
  }

  /// 字符串 → UTF-16LE 字节（带 0xFF 0xFE BOM）。
  ///
  /// 逐 code unit 写出即可覆盖 BMP 与代理对（String.codeUnits 本身就是
  /// UTF-16 码元序列），无需做编码转换。
  static Uint8List _encodeUtf16LeWithBom(String text) {
    final bytes = Uint8List(2 + text.length * 2);
    bytes[0] = 0xFF; // BOM（小端）
    bytes[1] = 0xFE;
    var offset = 2;
    for (final unit in text.codeUnits) {
      bytes[offset++] = unit & 0xFF;
      bytes[offset++] = (unit >> 8) & 0xFF;
    }
    return bytes;
  }

  /// 同步读取文件头已有 ID3v2 标签占用的字节数（含 10 字节标签头，v2.4
  /// footer 也算在内）；无标签 / 读失败返回 0。
  ///
  /// 供下载服务做同名文件冲突判定：写标签后目标文件会比新下载的纯音频
  /// `.part` 大出一段标签，若仍按文件总大小比较会被误判「同名不同歌」而
  /// 多存一份 `(2).mp3`；按「音频字节数」比较才是同一首歌。
  static int existingTagLengthSync(File file) {
    try {
      final fileLength = file.lengthSync();
      if (fileLength < 10) return 0;
      final reader = file.openSync();
      try {
        final head = reader.readSync(10);
        return _tagEndFromHeader(head, fileLength);
      } finally {
        try {
          reader.closeSync();
        } catch (_) {}
      }
    } catch (_) {
      return 0;
    }
  }

  /// 现有 ID3v2 标签的结束偏移（含 10 字节头）；没有标签/标签损坏时返回 0。
  ///
  /// 只解析头部长度字段，不解析帧：v2.2/v2.3/v2.4 的头部长度都是 28-bit
  /// synchsafe，`10 + size` 就是音频起点。v2.4 带 footer（flag bit 0x10）
  /// 时再向后多跳 10 字节。长度非法（> 文件长度）按「无标签」处理——
  /// 宁可多写一个标签，也不能把音频开头当标签裁掉。
  static Future<int> _existingTagEnd(File file, int fileLength) async {
    if (fileLength < 10) return 0;
    RandomAccessFile? reader;
    try {
      reader = await file.open();
      final head = await reader.read(10);
      return _tagEndFromHeader(head, fileLength);
    } catch (_) {
      // 读头失败（文件被占用/权限）：按无标签处理，后续追加由外层兜底。
      return 0;
    } finally {
      try {
        await reader?.close();
      } catch (_) {}
    }
  }

  /// 从 10 字节标签头计算标签总长度；不是合法标签头时返回 0。
  static int _tagEndFromHeader(List<int> head, int fileLength) {
    if (fileLength < 10 || head.length < 10) return 0;
    // 必须是 'ID3' 魔数。
    if (head[0] != 0x49 || head[1] != 0x44 || head[2] != 0x33) return 0;
    final majorVersion = head[3];
    // 0xFF 是 ID3v2 规定的非法版本；> 4 的版本本实现不认识，按无标签处理。
    if (majorVersion == 0xFF || majorVersion > 0x04) return 0;
    final tagDataLength = _decodeSynchsafe(head[6], head[7], head[8], head[9]);
    var end = 10 + tagDataLength;
    // ID3v2.4 footer：flag 的低 4 位中 0x10 = footer 存在。
    if (majorVersion == 0x04 && (head[5] & 0x10) != 0) {
      end += 10;
    }
    if (end > fileLength) return 0;
    return end;
  }

  /// 解码 28-bit synchsafe 整数（每个字节只用低 7 位）。
  static int _decodeSynchsafe(int b0, int b1, int b2, int b3) {
    return ((b0 & 0x7F) << 21) |
        ((b1 & 0x7F) << 14) |
        ((b2 & 0x7F) << 7) |
        (b3 & 0x7F);
  }

  /// 按魔数判断封面图片的 MIME 类型；不支持的格式返回 null（跳过 APIC）。
  ///
  /// 只认 JPEG/PNG：ID3v2.3 的 APIC MIME 虽然允许任意字符串，但老车机播放器
  /// 基本只认这两种；把 WebP/AVIF 标成 `image/jpeg` 反而可能让整段元数据读不出。
  static String? _imageMimeType(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    return null;
  }
}
