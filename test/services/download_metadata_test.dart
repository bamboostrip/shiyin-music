import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/audio_file_format.dart';
import 'package:shiyin_music/services/download_metadata_writer.dart';
import 'package:shiyin_music/services/flac_tag_writer.dart';

/// 下载元数据写入的字节级用例（上游 3.3.0 `d688884`）。
///
/// 全部用最小构造文件跑真实 IO：标签写入是**按字节改文件**的操作，写错位置
/// 会直接毁掉一首歌，只有读回原始字节断言才算数。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('shiyin_meta_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// 一段「音频帧」字节（内容只要不变就够，不需要真是可解码音频）。
  final audioBytes = Uint8List.fromList(
    List<int>.generate(512, (index) => (index * 7 + 3) & 0xff),
  );

  /// 构造最小 FLAC：`fLaC` + STREAMINFO(34) + 音频帧。
  Uint8List buildFlac({int streamInfoLength = 34}) {
    final builder = BytesBuilder();
    builder.add([0x66, 0x4c, 0x61, 0x43]); // 'fLaC'
    // 唯一的元数据块：type 0 (STREAMINFO)，最高位 1 = 最后一块。
    final length = streamInfoLength;
    builder.add([0x80 | 0x00, (length >> 16) & 0xff, (length >> 8) & 0xff, length & 0xff]);
    builder.add(List<int>.filled(length, 0x11));
    builder.add(audioBytes);
    return builder.takeBytes();
  }

  /// 构造最小 MP3：可选 ID3v2 头 + 一个 MPEG1 Layer III 帧同步。
  Uint8List buildMp3({bool withId3 = false}) {
    final builder = BytesBuilder();
    if (withId3) {
      builder.add([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    }
    builder.add([0xff, 0xfb, 0x90, 0x00]);
    builder.add(audioBytes);
    return builder.takeBytes();
  }

  Future<File> writeFile(String name, List<int> bytes) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  group('按字节识别真实编码', () {
    test('FLAC 被识别为 flac，offset 指向容器起点（跳过 ID3 之后）', () async {
      final file = await writeFile('a.flac', buildFlac());
      final result = await inspectAudioFile(file.path);
      expect(result.format, AudioFileFormat.flac);
      expect(result.offset, 0, reason: '裸 FLAC 的 fLaC 标记就在 0，无前缀可跳');
    });

    test('MP3 被识别为 mp3', () async {
      final file = await writeFile('a.mp3', buildMp3());
      final result = await inspectAudioFile(file.path);
      expect(result.format, AudioFileFormat.mp3);
      expect(result.offset, 0);
    });

    test('带 ID3v2 前缀的 MP3：offset 跳过标签', () async {
      final file = await writeFile('b.mp3', buildMp3(withId3: true));
      final result = await inspectAudioFile(file.path);
      expect(result.format, AudioFileFormat.mp3);
      expect(result.offset, 10);
    });

    test('认不出的字节判 unsupported（不改名、不写标签）', () async {
      final file = await writeFile('c.mp3', List<int>.filled(64, 0x00));
      final result = await inspectAudioFile(file.path);
      expect(result.format, AudioFileFormat.unsupported);
      expect(result.offset, 0);
    });
  });

  group('FLAC 标签写入', () {
    test('写入后可读回 TITLE/ARTIST/ALBUM/LYRICS，且音频帧字节不变', () async {
      final original = buildFlac();
      final file = await writeFile('song.flac', original);

      final ok = await FlacTagWriter.injectMetadata(
        filePath: file.path,
        song: const Song(
          id: '1',
          title: '夜曲',
          artist: '周杰伦',
          hash: 'h1',
          albumName: '十一月的萧邦',
        ),
        lyricsText: '[00:01.00]一群嗜血的蚂蚁',
      );
      expect(ok, isTrue);

      final written = await file.readAsBytes();
      // 1) 仍是 FLAC（没有变成 ID3 前缀）。
      expect(written.sublist(0, 4), [0x66, 0x4c, 0x61, 0x43]);
      // 2) 能重新识别。
      expect((await inspectAudioFile(file.path)).format, AudioFileFormat.flac);
      // 3) 音频帧原样保留在文件尾部。
      expect(
        written.sublist(written.length - audioBytes.length),
        audioBytes,
      );
      // 4) 文本标签按 UTF-8 写进 Vorbis comment。
      final asUtf8 = const Utf8Decoder(allowMalformed: true).convert(written);
      expect(asUtf8.contains('TITLE=夜曲'), isTrue);
      expect(asUtf8.contains('ARTIST=周杰伦'), isTrue);
      expect(asUtf8.contains('ALBUM=十一月的萧邦'), isTrue);
      expect(asUtf8.contains('LYRICS=[00:01.00]一群嗜血的蚂蚁'), isTrue);
    });

    test('重复写入是替换而不是叠加（只有一份 comment 块）', () async {
      final file = await writeFile('song.flac', buildFlac());
      const song = Song(id: '1', title: '第一版', artist: 'A', hash: 'h1');
      await FlacTagWriter.injectMetadata(filePath: file.path, song: song);
      await FlacTagWriter.injectMetadata(
        filePath: file.path,
        song: const Song(id: '1', title: '第二版', artist: 'A', hash: 'h1'),
      );

      final asUtf8 = const Utf8Decoder(
        allowMalformed: true,
      ).convert(await file.readAsBytes());
      expect(asUtf8.contains('TITLE=第二版'), isTrue);
      expect(asUtf8.contains('TITLE=第一版'), isFalse);
    });

    test('非 FLAC 文件一律拒写（避免把 ID3/其它容器改坏）', () async {
      final original = buildMp3();
      final file = await writeFile('a.mp3', original);
      final ok = await FlacTagWriter.injectMetadata(
        filePath: file.path,
        song: const Song(id: '1', title: 'T', artist: 'A', hash: 'h1'),
      );
      expect(ok, isFalse);
      expect(await file.readAsBytes(), original, reason: '拒写时文件必须原样不动');
    });

    test('封面超过单块上限（≈16MB）只跳封面，文本标签照写', () async {
      // PICTURE 块的 24 位长度字段放不下：不能因为一个封面让整次标签写入
      // 失败（那样歌名/歌手/歌词会一起丢），与 ID3 侧「超限只跳封面」对齐。
      final file = await writeFile('big.flac', buildFlac());
      final hugeCover = Uint8List(0xffffff + 1)
        ..[0] = 0x89
        ..[1] = 0x50
        ..[2] = 0x4e
        ..[3] = 0x47;

      final ok = await FlacTagWriter.injectMetadata(
        filePath: file.path,
        song: const Song(id: '1', title: '大封面', artist: 'A', hash: 'h1'),
        coverBytes: hugeCover,
      );

      expect(ok, isTrue);
      final asUtf8 = const Utf8Decoder(
        allowMalformed: true,
      ).convert(await file.readAsBytes());
      expect(asUtf8.contains('TITLE=大封面'), isTrue);
    });
  });

  group('元数据收尾编排', () {
    test('不支持的编码不写标签，但仍会落 .lrc', () async {
      final file = await writeFile('x.ape', List<int>.filled(32, 0x01));
      final result = await DownloadMetadataWriter.write(
        filePath: file.path,
        song: const Song(id: '1', title: 'T', artist: 'A', hash: 'h1'),
        lyricsText: '[00:00.00]hello',
      );
      expect(result.tagsWritten, isFalse);
      expect(result.sidecarWritten, isTrue);
      final sidecar = File(DownloadMetadataWriter.lyricsFilePath(file.path));
      expect(sidecar.existsSync(), isTrue);
      expect(await sidecar.readAsString(), '[00:00.00]hello');
    });

    test('FLAC 标签写成功后默认不留 .lrc；勾选后留', () async {
      final file = await writeFile('ok.flac', buildFlac());
      final result = await DownloadMetadataWriter.write(
        filePath: file.path,
        song: const Song(id: '1', title: 'T', artist: 'A', hash: 'h1'),
        lyricsText: '[00:00.00]hello',
      );
      expect(result.tagsWritten, isTrue);
      expect(result.lyricsEmbedded, isTrue);
      expect(result.sidecarWritten, isFalse);

      final again = await DownloadMetadataWriter.write(
        filePath: file.path,
        song: const Song(id: '1', title: 'T', artist: 'A', hash: 'h1'),
        lyricsText: '[00:00.00]hello',
        saveLyricsFile: true,
      );
      expect(again.sidecarWritten, isTrue);
    });

    test('lyricsFilePath 只按最后一段扩展名截断', () {
      expect(
        DownloadMetadataWriter.lyricsFilePath('/a/v1.2/song.mp3'),
        '/a/v1.2/song.lrc',
      );
    });
  });

  group('LRC 文本', () {
    test('保留时间轴并带上翻译行', () {
      final text = downloadLyricsText([
        LyricLine(
          time: const Duration(minutes: 1, seconds: 2, milliseconds: 340),
          text: '原文',
          translation: '译文',
        ),
        const LyricLine(time: Duration(minutes: 1, seconds: 5), text: ''),
      ]);
      expect(text, '[01:02.34]原文\n[01:02.34]译文\n');
    });

    test('空歌词返回空串', () {
      expect(downloadLyricsText(const []), '');
    });
  });
}
