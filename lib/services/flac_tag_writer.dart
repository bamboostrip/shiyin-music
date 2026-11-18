import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/music_models.dart';
import 'audio_file_format.dart';

typedef _Block = ({int type, Uint8List bytes});

/// 为已落盘的 FLAC 文件写入 Vorbis comment（歌名/歌手/专辑/歌词）与封面。
///
/// 移植自上游 3.3.0 `d688884`（`lib/services/flac_tag_writer.dart`），
/// 只把 vendor 字符串改成项目名，其余按字节格式照搬。
///
/// 为什么需要独立实现：[`Id3TagWriter`] 只认 MP3 —— ID3v2 是「文件头前缀」，
/// 而 FLAC 要求 `fLaC` 标记在偏移 0，标签必须写成 Vorbis comment（type 4）
/// 元数据块。往 FLAC 前面贴 ID3 会让严格的解码器直接判文件损坏。
///
/// 与 ID3 一致的取舍：
/// - 先写同目录临时文件再 `rename` 覆盖，写一半被杀进程时原文件仍完整；
/// - 任何异常都返回 false 并只记日志，绝不把已下载成功的音频判为失败；
/// - 封面只接受 PNG/JPEG（老播放器只认这两种 MIME）。
class FlacTagWriter {
  FlacTagWriter._();

  /// 临时文件后缀：与目标文件同目录，保证 rename 在同一文件系统内原子。
  static const String tempSuffix = '.tag.tmp';

  /// Vorbis comment 的 vendor 字段（写进文件，播放器一般不展示）。
  static const String vendor = 'shiyin';

  /// 向 [filePath] 写入 Vorbis comment / 封面，成功返回 true。
  ///
  /// [lyricsText] 非空时写 `LYRICS`，并顺手删掉旧的 `UNSYNCEDLYRICS`/`LYRIC`
  /// ——同一份歌词留三种键会让不同的播放器各显示一份。
  static Future<bool> injectMetadata({
    required String filePath,
    required Song song,
    Uint8List? coverBytes,
    String? lyricsText,
  }) async {
    final temporary = File('$filePath$tempSuffix');
    try {
      final format = await inspectAudioFile(filePath);
      if (format.format != AudioFileFormat.flac) return false;
      final file = File(filePath);
      final reader = await file.open();
      final blocks = <_Block>[];
      late int audioOffset;
      try {
        final fileLength = await reader.length();
        await reader.setPosition(format.offset + 4);
        var last = false;
        while (!last) {
          if (await reader.position() + 4 > fileLength) {
            throw const FormatException('FLAC 元数据块头被截断');
          }
          final header = await reader.read(4);
          last = header[0] & 0x80 != 0;
          final type = header[0] & 0x7f;
          final length = (header[1] << 16) | (header[2] << 8) | header[3];
          // 127 是非法块类型；块数上限只是防畸形文件把内存吃光。
          if (type == 127 ||
              await reader.position() + length > fileLength ||
              blocks.length >= 1024) {
            throw const FormatException('FLAC 元数据块非法');
          }
          blocks.add((type: type, bytes: await reader.read(length)));
        }
        audioOffset = await reader.position();
      } finally {
        await reader.close();
      }
      // STREAMINFO 必须是第一个块（规范要求），顺带用它校验这是真 FLAC。
      if (blocks.isEmpty ||
          blocks.first.type != 0 ||
          blocks.first.bytes.length != 34) {
        throw const FormatException('FLAC STREAMINFO 必须位于首块');
      }

      final replacements = <String, String>{
        if (song.title.isNotEmpty) 'TITLE': song.title,
        if (song.artist.isNotEmpty) 'ARTIST': song.artist,
        if (song.albumName?.isNotEmpty == true) 'ALBUM': song.albumName!,
        if (lyricsText?.isNotEmpty == true) 'LYRICS': lyricsText!,
      };
      var blockVendor = vendor;
      final comments = <String>[];
      // 保留已有块里没被覆盖的键（作词/作曲/音轨号等），只替换本次要写的。
      for (final block in blocks.where((block) => block.type == 4)) {
        final original = _readComments(block.bytes);
        blockVendor = original.vendor;
        comments.addAll(
          original.comments.where((comment) {
            final key = comment.split('=').first.toUpperCase();
            return !replacements.containsKey(key) &&
                !(replacements.containsKey('LYRICS') &&
                    (key == 'UNSYNCEDLYRICS' || key == 'LYRIC'));
          }),
        );
      }
      comments.addAll(
        replacements.entries.map((entry) => '${entry.key}=${entry.value}'),
      );
      final newBlocks = <_Block>[
        blocks.first,
        (type: 4, bytes: _writeComments(blockVendor, comments)),
        for (final block in blocks.skip(1))
          // 丢掉旧的 comment 块（已在上面重建）与旧的 3 号封面（type 6，
          // picture type 3 = front cover）。
          if (block.type != 4 &&
              !(coverBytes != null &&
                  block.type == 6 &&
                  block.bytes.length >= 4 &&
                  ByteData.sublistView(block.bytes).getUint32(0) == 3))
            block,
        if (coverBytes != null) (type: 6, bytes: _writePicture(coverBytes)),
      ];
      final sink = temporary.openWrite();
      try {
        sink.add(ascii.encode('fLaC'));
        for (var index = 0; index < newBlocks.length; index++) {
          final block = newBlocks[index];
          final length = block.bytes.length;
          if (length > 0xffffff) {
            throw const FormatException('FLAC 元数据块过大');
          }
          sink.add([
            // 每个块的最高位是「是否最后一块」，必须按新顺序重算。
            block.type | (index == newBlocks.length - 1 ? 0x80 : 0),
            (length >> 16) & 0xff,
            (length >> 8) & 0xff,
            length & 0xff,
          ]);
          sink.add(block.bytes);
        }
        // 音频帧原样流式复制（无损文件动辄几十 MB，不能整读进内存）。
        await sink.addStream(file.openRead(audioOffset));
        await sink.flush();
      } finally {
        await sink.close();
      }
      await temporary.rename(filePath);
      return true;
    } catch (error) {
      debugPrint('[FlacTagWriter] 写入标签失败（已忽略，不影响下载）: $error');
      return false;
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
    }
  }

  static ({String vendor, List<String> comments}) _readComments(
    Uint8List bytes,
  ) {
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    int readLength() {
      if (offset + 4 > bytes.length) {
        throw const FormatException('Vorbis comment 长度域非法');
      }
      final length = data.getUint32(offset, Endian.little);
      offset += 4;
      return length;
    }

    String readString() {
      final length = readLength();
      if (offset + length > bytes.length) {
        throw const FormatException('Vorbis comment 字符串越界');
      }
      // 历史文件里可能残留非法 UTF-8：容错解码，不能因此拒绝替换坏标签。
      final text = utf8.decode(
        bytes.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      return text;
    }

    final blockVendor = readString();
    final count = readLength();
    if (count > (bytes.length - offset) ~/ 4) {
      throw const FormatException('Vorbis comment 条目数非法');
    }
    return (
      vendor: blockVendor,
      comments: [for (var i = 0; i < count; i++) readString()],
    );
  }

  static Uint8List _writeComments(String blockVendor, List<String> comments) {
    final builder = BytesBuilder();
    void addString(String value) {
      final encoded = utf8.encode(value);
      builder.add(_uint32(encoded.length, Endian.little));
      builder.add(encoded);
    }

    addString(blockVendor);
    builder.add(_uint32(comments.length, Endian.little));
    for (final comment in comments) {
      addString(comment);
    }
    return builder.takeBytes();
  }

  static Uint8List _writePicture(Uint8List bytes) {
    final png = bytes.length >= 24 && bytes[0] == 0x89 && bytes[1] == 0x50;
    final mime = ascii.encode(png ? 'image/png' : 'image/jpeg');
    final builder = BytesBuilder();
    builder.add(_uint32(3)); // picture type 3 = 正面封面。
    builder.add(_uint32(mime.length));
    builder.add(mime);
    builder.add(_uint32(0)); // 描述为空。
    final dimensions = _pictureDimensions(bytes, png: png);
    builder.add(_uint32(dimensions.width));
    builder.add(_uint32(dimensions.height));
    builder.add(_uint32(dimensions.depth));
    builder.add(_uint32(dimensions.colors));
    builder.add(_uint32(bytes.length));
    builder.add(bytes);
    return builder.takeBytes();
  }

  /// 解析图片宽高/色深。
  ///
  /// 部分播放器会校验 PICTURE 块头里的尺寸（写 0 可能导致封面不显示），
  /// 所以能解析就填真值，解析不出才退回 0。
  static ({int width, int height, int depth, int colors}) _pictureDimensions(
    Uint8List bytes, {
    required bool png,
  }) {
    final data = ByteData.sublistView(bytes);
    if (png) {
      final colorType = bytes.length > 25 ? bytes[25] : 0;
      final channels = switch (colorType) {
        2 => 3,
        4 => 2,
        6 => 4,
        _ => 1,
      };
      final bits = bytes.length > 24 ? bytes[24] : 0;
      return (
        width: data.getUint32(16),
        height: data.getUint32(20),
        depth: bits * channels,
        colors: colorType == 3 ? 1 << bits : 0,
      );
    }
    // JPEG 的尺寸在 SOF 段里，前面可能夹着若干 APP/EXIF 段。
    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset++] != 0xff) break;
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xd9 || marker == 0xda) break;
      if (marker == 0x01 || marker >= 0xd0 && marker <= 0xd8) continue;
      if (offset + 2 > bytes.length) break;
      final length = data.getUint16(offset);
      if (length < 2 || offset + length > bytes.length) break;
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc &&
          length >= 8) {
        return (
          width: data.getUint16(offset + 5),
          height: data.getUint16(offset + 3),
          depth: bytes[offset + 2] * bytes[offset + 7],
          colors: 0,
        );
      }
      offset += length;
    }
    return (width: 0, height: 0, depth: 0, colors: 0);
  }

  static Uint8List _uint32(int value, [Endian endian = Endian.big]) =>
      (ByteData(4)..setUint32(0, value, endian)).buffer.asUint8List();
}
