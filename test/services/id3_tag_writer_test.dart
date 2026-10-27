import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/id3_tag_writer.dart';

/// ID3v2.3 字节断言工具。
///
/// 本 fork 明令禁止 `audio_metadata_reader`（见 `local_lyrics_service.dart`），
/// 所以这里不复用任何解析库，也不复用被测代码的私有实现——手工按 ID3v2.3
/// 规范解析一遍，才能真正守住「写出的字节符合规范」这条测试底线。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('shiyin_id3_test_');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响断言结果（Windows 文件句柄延迟释放常见）。
    }
  });

  Future<File> writeFile(String name, List<int> bytes) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  group('ID3v2.3 头部与帧结构', () {
    test('写入魔数/版本/flags/synchsafe 长度正确，音频字节原样保留', () async {
      final audio = dummyAudio();
      final file = await writeFile('song.mp3', audio);

      final ok = await Id3TagWriter.injectMetadata(
        filePath: file.path,
        song: testSong,
      );

      expect(ok, isTrue);
      final bytes = await file.readAsBytes();
      // 10 字节标签头：'ID3' + v2.3 + flags=0。
      expect(ascii.decode(bytes.sublist(0, 3)), 'ID3');
      expect(bytes[3], 0x03, reason: 'ID3v2.3 主版本');
      expect(bytes[4], 0x00, reason: '修订号 0');
      expect(bytes[5], 0x00, reason: 'flags：无 unsync/扩展头/footer');
      // 头部 4 字节是 28-bit synchsafe，只算标签数据区（不含 10 字节头）。
      final tagDataLength = synchsafe(bytes, 6);
      expect(10 + tagDataLength, bytes.length - audio.length);
      // 标签之后必须是原封不动的音频字节。
      expect(bytes.sublist(bytes.length - audio.length), audio);
      // 帧链长度自洽：逐帧走完应恰好铺满标签数据区。
      parseFrames(bytes);
      // 不残留临时文件。
      expect(
        File('${file.path}${Id3TagWriter.tempSuffix}').existsSync(),
        isFalse,
      );
    });

    test('TIT2/TPE1/TALB：帧 ID、大端帧长、flags 清零、UTF-16LE+BOM 文本', () async {
      final file = await writeFile('frames.mp3', dummyAudio());
      expect(
        await Id3TagWriter.injectMetadata(
          filePath: file.path,
          song: testSong,
        ),
        isTrue,
      );

      final bytes = await file.readAsBytes();
      final frames = parseFrames(bytes);
      expect(frames.map((f) => f.id), ['TIT2', 'TPE1', 'TALB']);

      const expected = {'TIT2': '晴天', 'TPE1': '周杰伦', 'TALB': '叶惠美'};
      for (final entry in expected.entries) {
        final frame = frameById(frames, entry.key);
        expect(frame, isNotNull, reason: '缺少 ${entry.key} 帧');
        // 帧头 2 字节 flags 必须为 0（无压缩/加密/分组/状态位）。
        expect(bytes[frame!.payloadOffset - 2], 0x00);
        expect(bytes[frame.payloadOffset - 1], 0x00);
        // 帧长度 = 编码字节(1) + BOM(2) + 2 字节/码元。
        expect(frame.payloadLength, 1 + 2 + entry.value.length * 2);
        expect(decodeUtf16TextFrame(frame.payloadIn(bytes)), entry.value);
      }
    });

    test('空字段不写帧：歌名/歌手/专辑全空时返回 false 且文件不动', () async {
      final audio = dummyAudio();
      final file = await writeFile('empty.mp3', audio);
      const emptySong = Song(id: 'x', title: '', artist: '', hash: 'h');

      final ok = await Id3TagWriter.injectMetadata(
        filePath: file.path,
        song: emptySong,
      );

      expect(ok, isFalse);
      expect(await file.readAsBytes(), audio);
    });
  });

  group('APIC 封面帧', () {
    test('PNG 写 image/png、JPEG 写 image/jpeg，类型 0x03 且图片字节原样', () async {
      final png = Uint8List.fromList(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 签名
        0x01, 0x02, 0x03, 0x04,
      ]);
      final jpeg = Uint8List.fromList(<int>[
        0xFF, 0xD8, 0xFF, 0xE0, // JPEG SOI + APP0
        0x09, 0x08, 0x07,
      ]);

      for (final entry in <({String name, Uint8List image, String mime})>[
        (name: 'png', image: png, mime: 'image/png'),
        (name: 'jpeg', image: jpeg, mime: 'image/jpeg'),
      ]) {
        final file = await writeFile(
          'cover_${entry.name}.mp3',
          dummyAudio(),
        );
        expect(
          await Id3TagWriter.injectMetadata(
            filePath: file.path,
            song: testSong,
            coverBytes: entry.image,
          ),
          isTrue,
        );

        final bytes = await file.readAsBytes();
        final apic = frameById(parseFrames(bytes), 'APIC');
        expect(apic, isNotNull, reason: '${entry.name} 封面应写 APIC 帧');
        final payload = apic!.payloadIn(bytes);
        expect(payload[0], 0x00, reason: 'APIC 编码字节为 ISO-8859-1');
        final mimeEnd = payload.indexOf(0x00, 1);
        expect(ascii.decode(payload.sublist(1, mimeEnd)), entry.mime);
        expect(payload[mimeEnd + 1], 0x03, reason: '图片类型 Cover (front)');
        expect(payload[mimeEnd + 2], 0x00, reason: '空描述的终止符');
        expect(payload.sublist(mimeEnd + 3), entry.image);
      }
    });

    test('不支持的封面格式（WebP）跳过 APIC，文本帧照常写入', () async {
      final webp = Uint8List.fromList(ascii.encode('RIFF....WEBPdata'));
      final audio = dummyAudio();
      final file = await writeFile('webp.mp3', audio);

      expect(
        await Id3TagWriter.injectMetadata(
          filePath: file.path,
          song: testSong,
          coverBytes: webp,
        ),
        isTrue,
      );

      final bytes = await file.readAsBytes();
      final frames = parseFrames(bytes);
      expect(frameById(frames, 'APIC'), isNull);
      // 文本帧必须仍然写入（封面是可选帧，不能连累元数据）。
      expect(frameById(frames, 'TIT2'), isNotNull);
      expect(frameById(frames, 'TPE1'), isNotNull);
      expect(bytes.sublist(bytes.length - audio.length), audio);
    });

    test('超过 maxCoverBytes 的封面跳过 APIC', () async {
      final huge = Uint8List(Id3TagWriter.maxCoverBytes + 1);
      huge[0] = 0x89;
      huge[1] = 0x50;
      huge[2] = 0x4E;
      huge[3] = 0x47;
      final file = await writeFile('huge.mp3', dummyAudio());

      expect(
        await Id3TagWriter.injectMetadata(
          filePath: file.path,
          song: testSong,
          coverBytes: huge,
        ),
        isTrue,
      );
      final frames = parseFrames(await file.readAsBytes());
      expect(frameById(frames, 'APIC'), isNull);
      expect(frameById(frames, 'TIT2'), isNotNull);
    });
  });

  group('USLT 内嵌歌词（可选参数）', () {
    test('不传歌词不写 USLT 帧', () async {
      final file = await writeFile('no_lyrics.mp3', dummyAudio());
      expect(
        await Id3TagWriter.injectMetadata(
          filePath: file.path,
          song: testSong,
        ),
        isTrue,
      );
      expect(frameById(parseFrames(await file.readAsBytes()), 'USLT'), isNull);
    });

    test('传歌词写 USLT：编码 0x01 + 语言 zho + 空描述 + UTF-16 歌词', () async {
      final file = await writeFile('lyrics.mp3', dummyAudio());
      const lyrics = '[00:01.00]故事的小黄花';
      expect(
        await Id3TagWriter.injectMetadata(
          filePath: file.path,
          song: testSong,
          lyricsText: lyrics,
        ),
        isTrue,
      );

      final bytes = await file.readAsBytes();
      final uslt = frameById(parseFrames(bytes), 'USLT');
      expect(uslt, isNotNull);
      final payload = uslt!.payloadIn(bytes);
      expect(payload[0], 0x01, reason: 'USLT 编码字节 UTF-16 with BOM');
      expect(ascii.decode(payload.sublist(1, 4)), 'zho', reason: '语言码');
      expect(payload[4], 0x00);
      expect(payload[5], 0x00, reason: '空内容描述的 UTF-16 终止符');
      expect(payload[6], 0xFF, reason: '歌词正文 BOM');
      expect(payload[7], 0xFE);
      expect(decodeUtf16Le(payload.sublist(8)), lyrics);
    });
  });

  group('幂等与异常降级', () {
    test('二次注入是替换而非叠加：只有一个 ID3 头、一组帧，音频不变', () async {
      final audio = dummyAudio();
      final file = await writeFile('repeat.mp3', audio);

      expect(
        await Id3TagWriter.injectMetadata(filePath: file.path, song: testSong),
        isTrue,
      );
      final firstLength = await file.length();

      expect(
        await Id3TagWriter.injectMetadata(filePath: file.path, song: testSong),
        isTrue,
      );

      final bytes = await file.readAsBytes();
      // "ID3" 魔数只允许出现一次（文件头）；若叠加第二份标签，音频区
      // 开头也会是 'ID3'，长度也会多出一整段。
      expect(countOccurrences(bytes, ascii.encode('ID3')), 1);
      expect(bytes.length, firstLength, reason: '重写同内容标签，长度应稳定');
      final frames = parseFrames(bytes);
      expect(frames.where((f) => f.id == 'TIT2').length, 1);
      expect(
        decodeUtf16TextFrame(frameById(frames, 'TIT2')!.payloadIn(bytes)),
        '晴天',
      );
      expect(bytes.sublist(bytes.length - audio.length), audio);
    });

    test('已有旧 ID3v2.3 标签（含 padding）被整体替换，不残留旧帧', () async {
      final audio = dummyAudio();
      final oldTag = buildFakeId3Tag(title: '旧歌名');
      final file = await writeFile('old_tag.mp3', <int>[...oldTag, ...audio]);

      expect(
        await Id3TagWriter.injectMetadata(filePath: file.path, song: testSong),
        isTrue,
      );

      final bytes = await file.readAsBytes();
      expect(countOccurrences(bytes, ascii.encode('ID3')), 1);
      final frames = parseFrames(bytes);
      final tit2 = frameById(frames, 'TIT2');
      expect(tit2, isNotNull);
      expect(decodeUtf16TextFrame(tit2!.payloadIn(bytes)), '晴天');
      // 旧歌名的 UTF-16LE 字节不应再出现。
      expect(containsSequence(bytes, encodeUtf16Le('旧歌名')), isFalse);
      expect(bytes.sublist(bytes.length - audio.length), audio);
    });

    test('已有 ID3v2.4 标签（带 footer）被整块跳过后替换', () async {
      final audio = dummyAudio();
      final oldTag = buildFakeId3v24TagWithFooter(title: '旧歌名');
      final file = await writeFile('old_v24.mp3', <int>[...oldTag, ...audio]);

      expect(
        await Id3TagWriter.injectMetadata(filePath: file.path, song: testSong),
        isTrue,
      );

      final bytes = await file.readAsBytes();
      expect(ascii.decode(bytes.sublist(0, 3)), 'ID3');
      expect(bytes[3], 0x03, reason: '统一重写为 v2.3');
      expect(countOccurrences(bytes, ascii.encode('ID3')), 1);
      final frames = parseFrames(bytes);
      expect(
        decodeUtf16TextFrame(frameById(frames, 'TIT2')!.payloadIn(bytes)),
        '晴天',
      );
      expect(containsSequence(bytes, encodeUtf16Le('旧歌名')), isFalse);
      // footer（10 字节）必须一并跳过：音频字节从标签后开始且完整。
      expect(bytes.sublist(bytes.length - audio.length), audio);
    });

    test('文件不存在返回 false', () async {
      final missing = File(
        '${tempDir.path}${Platform.pathSeparator}no_such.mp3',
      );
      expect(
        await Id3TagWriter.injectMetadata(
          filePath: missing.path,
          song: testSong,
        ),
        isFalse,
      );
      expect(missing.existsSync(), isFalse);
    });

    test('.flac 跳过：返回 false 且文件字节不变', () async {
      final flacBytes = Uint8List.fromList(<int>[
        ...ascii.encode('fLaC'),
        0x00, 0x00, 0x00, 0x22, // 伪造 metadata block header
        ...List<int>.generate(32, (i) => i),
      ]);
      final file = await writeFile('lossless.flac', flacBytes);

      final ok = await Id3TagWriter.injectMetadata(
        filePath: file.path,
        song: testSong,
      );

      expect(ok, isFalse, reason: 'FLAC 需 Vorbis comment，不在本期范围');
      expect(await file.readAsBytes(), flacBytes);
    });
  });

  group('existingTagLengthSync（下载冲突判定用）', () {
    test('无标签返回 0；写入标签后返回标签长度；音频长度 = 总长 - 标签长', () async {
      final audio = dummyAudio();
      final file = await writeFile('probe.mp3', audio);
      expect(Id3TagWriter.existingTagLengthSync(file), 0);

      expect(
        await Id3TagWriter.injectMetadata(filePath: file.path, song: testSong),
        isTrue,
      );
      final bytes = await file.readAsBytes();
      final tagLength = Id3TagWriter.existingTagLengthSync(file);
      expect(tagLength, 10 + synchsafe(bytes, 6));
      expect(bytes.length - tagLength, audio.length);
    });
  });
}

/// 测试用歌曲：中文歌名/歌手/专辑覆盖 UTF-16 编码路径。
const Song testSong = Song(
  id: 'song_1',
  title: '晴天',
  artist: '周杰伦',
  albumName: '叶惠美',
  hash: 'abc123def456',
);

/// 伪造 MP3 音频字节：MPEG 同步字开头，其余字节避开 ASCII（不会误命中
/// 'ID3'/'TIT2' 等帧 ID，便于断言"魔数只出现一次"）。
Uint8List dummyAudio() {
  final audio = Uint8List(72);
  audio[0] = 0xFF;
  audio[1] = 0xFB;
  audio[2] = 0x90;
  audio[3] = 0x64;
  for (var i = 4; i < audio.length; i++) {
    audio[i] = 0x80 + (i % 0x40);
  }
  return audio;
}

int synchsafe(Uint8List bytes, int offset) =>
    ((bytes[offset] & 0x7F) << 21) |
    ((bytes[offset + 1] & 0x7F) << 14) |
    ((bytes[offset + 2] & 0x7F) << 7) |
    (bytes[offset + 3] & 0x7F);

int u32be(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// 从文件头开始逐帧解析 ID3v2.3 标签，断言帧链恰好铺满标签数据区。
List<({String id, int payloadOffset, int payloadLength})> parseFrames(
  Uint8List file,
) {
  expect(ascii.decode(file.sublist(0, 3)), 'ID3');
  final tagDataLength = synchsafe(file, 6);
  final tagEnd = 10 + tagDataLength;
  expect(tagEnd, lessThanOrEqualTo(file.length), reason: '标签长度不能超出文件');

  final frames = <({String id, int payloadOffset, int payloadLength})>[];
  var offset = 10;
  while (offset + 10 <= tagEnd) {
    final id = ascii.decode(file.sublist(offset, offset + 4));
    final size = u32be(file, offset + 4);
    expect(size, greaterThan(0), reason: '$id 帧长度不应为 0');
    frames.add((
      id: id,
      payloadOffset: offset + 10,
      payloadLength: size,
    ));
    offset += 10 + size;
  }
  expect(offset, tagEnd, reason: '帧链应恰好铺满标签数据区（无 padding）');
  return frames;
}

({String id, int payloadOffset, int payloadLength})? frameById(
  List<({String id, int payloadOffset, int payloadLength})> frames,
  String id,
) {
  for (final frame in frames) {
    if (frame.id == id) return frame;
  }
  return null;
}

extension _FramePayload on ({String id, int payloadOffset, int payloadLength}) {
  Uint8List payloadIn(Uint8List file) => Uint8List.sublistView(
    file,
    payloadOffset,
    payloadOffset + payloadLength,
  );
}

/// 解文本帧负载：编码字节 0x01 + BOM FF FE + UTF-16LE。
String decodeUtf16TextFrame(Uint8List payload) {
  expect(payload.length, greaterThan(3));
  expect(payload[0], 0x01, reason: '文本帧编码字节应为 1 (UTF-16 with BOM)');
  expect(payload[1], 0xFF);
  expect(payload[2], 0xFE);
  return decodeUtf16Le(payload.sublist(3));
}

String decodeUtf16Le(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

List<int> encodeUtf16Le(String text) {
  final bytes = <int>[];
  for (final unit in text.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add((unit >> 8) & 0xFF);
  }
  return bytes;
}

int countOccurrences(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return 0;
  var count = 0;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) count++;
  }
  return count;
}

bool containsSequence(List<int> haystack, List<int> needle) =>
    countOccurrences(haystack, needle) > 0;

/// 构造带 footer 的 ID3v2.4 标签（header + 一个 TIT2 帧 + 10 字节 footer）：
/// 用来验证「跳过旧标签」逻辑对 v2.4 footer（flags bit 0x10）的处理。
Uint8List buildFakeId3v24TagWithFooter({required String title}) {
  final text = <int>[0x01, 0xFF, 0xFE, ...encodeUtf16Le(title)];
  final frame = <int>[
    ...ascii.encode('TIT2'),
    (text.length >> 24) & 0xFF,
    (text.length >> 16) & 0xFF,
    (text.length >> 8) & 0xFF,
    text.length & 0xFF,
    0x00,
    0x00,
    ...text,
  ];
  final length = frame.length;
  final sizeBytes = <int>[
    (length >> 21) & 0x7F,
    (length >> 14) & 0x7F,
    (length >> 7) & 0x7F,
    length & 0x7F,
  ];
  return Uint8List.fromList(<int>[
    0x49, 0x44, 0x33, // 'ID3'
    0x04, 0x00, // v2.4
    0x10, // flags：footer 存在
    ...sizeBytes,
    ...frame,
    // footer：'3DI' + 版本 + flags + 与 header 相同的 synchsafe size。
    0x33, 0x44, 0x49,
    0x04, 0x00,
    0x10,
    ...sizeBytes,
  ]);
}

/// 构造一个带 padding 的旧 ID3v2.3 标签（仅 TIT2 帧），模拟外部播放器/旧版本
/// 写过的文件头：注入时应整块跳过并替换，而不是叠加。
Uint8List buildFakeId3Tag({required String title}) {
  final text = <int>[0x01, 0xFF, 0xFE, ...encodeUtf16Le(title)];
  final frame = <int>[
    ...ascii.encode('TIT2'),
    (text.length >> 24) & 0xFF,
    (text.length >> 16) & 0xFF,
    (text.length >> 8) & 0xFF,
    text.length & 0xFF,
    0x00,
    0x00,
    ...text,
  ];
  // 32 字节 padding：真实标签常留空位，size 里包含 padding。
  final tagData = <int>[...frame, ...List<int>.filled(32, 0x00)];
  final length = tagData.length;
  return Uint8List.fromList(<int>[
    0x49, 0x44, 0x33, // 'ID3'
    0x03, 0x00, // v2.3
    0x00, // flags
    (length >> 21) & 0x7F,
    (length >> 14) & 0x7F,
    (length >> 7) & 0x7F,
    length & 0x7F,
    ...tagData,
  ]);
}
