import 'dart:io';

/// 下载文件的**真实**音频格式（不是扩展名）。
///
/// 移植自上游 3.3.0 `d688884`（`lib/services/audio_file_format.dart`）。
///
/// 存在理由：本 fork 的下载文件名在**请求音质**时就定好了扩展名
/// （`DownloadService.fileNameFor`：无损 → `.flac`，其余 → `.mp3`），
/// 而服务端可能降级下发别的编码（见 `DownloadController` 的
/// `_downloadQualityFallbackChain`：flac → 320 → 128）。于是会出现
///
/// - 文件名 `.flac`、内容其实是 MP3：第三方播放器按扩展名选解析器，
///   显示不出时长/标签，车机甚至直接判为损坏；
/// - 文件名 `.mp3`、内容其实是 FLAC：往 `fLaC` 头前面写 ID3v2 会破坏文件，
///   只能靠字节判断来避免。
///
/// 所以写入标签、纠正扩展名都必须先问这个函数，**不能信扩展名**。
enum AudioFileFormat { mp3, flac, unsupported }

/// 按文件头字节识别格式，并给出「音频数据起始偏移」。
///
/// [offset] 已经是跳过所有前置 ID3v2 标签之后的位置，FLAC 写入器要按它
/// 定位 `fLaC` 标记；无法识别时返回 `unsupported` 且 offset 为 0。
Future<({AudioFileFormat format, int offset})> inspectAudioFile(
  String path,
) async {
  final reader = await File(path).open();
  try {
    final length = await reader.length();
    var offset = 0;
    // 逐段跳过 ID3v2（可能连续多个）。头部缺陷一律判 unsupported，
    // 不去猜——猜错就会在真正的音频数据中间下刀。
    while (offset + 10 <= length) {
      await reader.setPosition(offset);
      final header = await reader.read(10);
      if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) {
        break;
      }
      // 版本号只支持 2.2/2.3/2.4；size 字段必须是 synchsafe（每字节最高位 0）。
      if (header[3] < 2 ||
          header[3] > 4 ||
          header.skip(6).any((byte) => byte > 0x7f)) {
        return (format: AudioFileFormat.unsupported, offset: 0);
      }
      final size =
          (header[6] << 21) | (header[7] << 14) | (header[8] << 7) | header[9];
      offset += 10 + size;
      // v2.4 的 footer（有 footer 标志时多 10 字节）。
      if (header[3] == 4 && header[5] & 0x10 != 0) offset += 10;
    }
    if (offset + 4 > length) {
      return (format: AudioFileFormat.unsupported, offset: 0);
    }
    await reader.setPosition(offset);
    final signature = await reader.read(4);
    if (signature[0] == 0x66 &&
        signature[1] == 0x4c &&
        signature[2] == 0x61 &&
        signature[3] == 0x43) {
      return (format: AudioFileFormat.flac, offset: offset);
    }
    // MPEG 音频帧同步字：11 位全 1，并排除 ADTS(AAC) 的 layer 00 与保留值。
    if (signature[0] == 0xff &&
        signature[1] & 0xe0 == 0xe0 &&
        signature[1] & 0x06 != 0 &&
        signature[1] & 0x18 != 0x08 &&
        signature[2] & 0xf0 != 0xf0 &&
        signature[2] & 0x0c != 0x0c) {
      return (format: AudioFileFormat.mp3, offset: offset);
    }
    return (format: AudioFileFormat.unsupported, offset: 0);
  } finally {
    await reader.close();
  }
}
