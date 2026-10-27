import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/services/id3_tag_writer.dart';
import 'package:shiyin_music/services/image_disk_cache.dart';

/// 本地音频服务器（模拟酷狗 CDN）：只回固定字节，不关心 Range。
class _AudioServer {
  _AudioServer(this.data);

  final List<int> data;
  HttpServer? _server;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentLength = data.length;
      request.response.add(Uint8List.fromList(data));
      await request.response.close();
    });
    return 'http://127.0.0.1:${server.port}/track.mp3';
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}

void main() {
  // 纯 IO 测试（本地 HttpServer + 真实 dio）：不能初始化
  // TestWidgetsFlutterBinding——它会劫持 HttpClient 全部返回 400。
  late Directory tempDir;
  late Directory downloadDir;
  late DownloadService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = await Directory.systemTemp.createTemp('shiyin_dl_id3_');
    downloadDir = Directory('${tempDir.path}${Platform.pathSeparator}downloads');
    await DownloadService.setCustomDownloadDir(downloadDir.path);
    // 封面磁盘缓存指向临时目录（单测环境拿不到 path_provider 临时目录）。
    final imageDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}image_cache',
    );
    await imageDir.create(recursive: true);
    ImageDiskCache.instance
      ..debugReset()
      ..configure(8 * 1024 * 1024)
      ..debugOverrideDirectory(imageDir);
    service = DownloadService();
  });

  tearDown(() async {
    service.dispose();
    ImageDiskCache.instance.debugReset();
    await DownloadService.setCustomDownloadDir(null);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows 下文件句柄释放有延迟：清理失败不影响断言（系统临时目录兜底）。
    }
  });

  test('下载 mp3 完成后自动写入 ID3v2.3 标签，音频字节完整', () async {
    final audio = dummyAudio();
    final server = _AudioServer(audio);
    final url = await server.start();
    addTearDown(server.stop);

    final path = await service.download(
      song: testSong,
      quality: AudioQuality.standard,
      url: url,
      onProgress: (_, _) {},
    );

    expect(path.toLowerCase().endsWith('.mp3'), isTrue);
    final bytes = await File(path).readAsBytes();
    // 标签头与版本。
    expect(ascii.decode(bytes.sublist(0, 3)), 'ID3');
    expect(bytes[3], 0x03);
    expect(bytes[4], 0x00);
    // 标签长度 + 音频长度 = 文件总长（没有丢音频、没有写两遍）。
    expect(10 + synchsafe(bytes, 6) + audio.length, bytes.length);
    // 文本帧 ID 与 UTF-16LE 内容都在。
    expect(containsSequence(bytes, ascii.encode('TIT2')), isTrue);
    expect(containsSequence(bytes, ascii.encode('TPE1')), isTrue);
    expect(containsSequence(bytes, ascii.encode('TALB')), isTrue);
    expect(containsSequence(bytes, utf16Le('晴天')), isTrue);
    expect(containsSequence(bytes, utf16Le('周杰伦')), isTrue);
    expect(containsSequence(bytes, utf16Le('叶惠美')), isTrue);
    // 标签之后的音频字节原样保留。
    expect(bytes.sublist(bytes.length - audio.length), audio);
    // 下载目录不留 .part / .id3.tmp 垃圾。
    expect(leftoverFiles(downloadDir), isEmpty);
  });

  test('封面命中磁盘缓存时写 APIC；未命中只跳过封面，下载照常成功', () async {
    final audio = dummyAudio();
    final server = _AudioServer(audio);
    final url = await server.start();
    addTearDown(server.stop);

    // 1) 命中：先把封面字节放进封面磁盘缓存（运行时由 DiskCachedImageProvider
    //    落盘，这里直接 store 模拟"下载前界面已加载过封面"）。
    const coverUrl = 'https://img.example.com/cover_hit.jpg';
    final jpeg = Uint8List.fromList(<int>[
      0xFF, 0xD8, 0xFF, 0xE0, // JPEG SOI + APP0
      ...List<int>.generate(16, (i) => i),
    ]);
    await ImageDiskCache.instance.store(coverUrl, jpeg);
    final hitPath = await service.download(
      song: const Song(
        id: 's_hit',
        title: '封面命中',
        artist: '歌手',
        albumName: '专辑',
        hash: 'hash_cover_hit',
        coverUrl: coverUrl,
      ),
      quality: AudioQuality.standard,
      url: url,
      onProgress: (_, _) {},
    );
    final hitBytes = await File(hitPath).readAsBytes();
    expect(containsSequence(hitBytes, ascii.encode('APIC')), isTrue);
    expect(containsSequence(hitBytes, jpeg), isTrue);
    expect(containsSequence(hitBytes, ascii.encode('image/jpeg')), isTrue);

    // 2) 未命中：coverUrl 不在缓存里，也不能联网二次下载——只丢封面帧，
    //    文本标签与下载结果不受影响。
    final missPath = await service.download(
      song: const Song(
        id: 's_miss',
        title: '封面未命中',
        artist: '歌手',
        hash: 'hash_cover_miss',
        coverUrl: 'https://img.example.com/cover_miss.jpg',
      ),
      quality: AudioQuality.standard,
      url: url,
      onProgress: (_, _) {},
    );
    final missBytes = await File(missPath).readAsBytes();
    expect(containsSequence(missBytes, ascii.encode('APIC')), isFalse);
    expect(containsSequence(missBytes, utf16Le('封面未命中')), isTrue);
    expect(missBytes.sublist(missBytes.length - audio.length), audio);
  });

  test('无损 .flac 跳过标签注入，字节与下载内容一致', () async {
    final flac = Uint8List.fromList(<int>[
      ...ascii.encode('fLaC'),
      0x00, 0x00, 0x00, 0x22,
      ...List<int>.generate(48, (i) => i),
    ]);
    final server = _AudioServer(flac);
    final url = await server.start();
    addTearDown(server.stop);

    final path = await service.download(
      song: testSong,
      quality: AudioQuality.lossless,
      url: url,
      onProgress: (_, _) {},
    );

    expect(path.toLowerCase().endsWith('.flac'), isTrue);
    // FLAC 需 Vorbis comment（本期不做）：文件必须与下载内容完全一致，
    // 不能塞 ID3 头（尾部 ID3 会让部分解码器直接报错）。
    expect(await File(path).readAsBytes(), flac);
  });

  test('同一首歌二次下载：覆盖同名文件不产生 (2) 副本，也不叠加重复 ID3', () async {
    final audio = dummyAudio();
    final server = _AudioServer(audio);
    final url = await server.start();
    addTearDown(server.stop);

    final firstPath = await service.download(
      song: testSong,
      quality: AudioQuality.standard,
      url: url,
      onProgress: (_, _) {},
    );
    final firstBytes = await File(firstPath).readAsBytes();

    final secondPath = await service.download(
      song: testSong,
      quality: AudioQuality.standard,
      url: url,
      onProgress: (_, _) {},
    );

    // 关键回归：写标签后目标文件比新的纯音频 .part 大，冲突判定若按文件
    // 总大小比较会误判"同名不同歌"而多存一份 "(2).mp3"。
    expect(secondPath, firstPath);
    final dotIndex = firstPath.lastIndexOf('.');
    final stem = dotIndex > 0 ? firstPath.substring(0, dotIndex) : firstPath;
    final extension = dotIndex > 0 ? firstPath.substring(dotIndex) : '.mp3';
    expect(File('$stem (2)$extension').existsSync(), isFalse);

    final bytes = await File(secondPath).readAsBytes();
    expect(countOccurrences(bytes, ascii.encode('ID3')), 1);
    expect(countOccurrences(bytes, ascii.encode('TIT2')), 1);
    expect(bytes.length, firstBytes.length);
    expect(bytes.sublist(bytes.length - audio.length), audio);
    expect(leftoverFiles(downloadDir), isEmpty);
  });

  test('元数据全空时注入被跳过，下载仍成功（标签失败不拖垮下载）', () async {
    final audio = dummyAudio();
    final server = _AudioServer(audio);
    final url = await server.start();
    addTearDown(server.stop);

    final path = await service.download(
      song: const Song(id: 'empty', title: '', artist: '', hash: 'hash_empty'),
      quality: AudioQuality.standard,
      url: url,
      onProgress: (_, _) {},
    );

    expect(File(path).existsSync(), isTrue);
    // 没有可写帧 → 不写标签，文件就是纯音频（而不是失败或被写成空文件）。
    expect(await File(path).readAsBytes(), audio);
  });
}

/// 测试用歌曲。
const Song testSong = Song(
  id: 'song_1',
  title: '晴天',
  artist: '周杰伦',
  albumName: '叶惠美',
  hash: 'abc123def456',
);

/// 伪造 MP3 音频字节（MPEG 同步字开头；其余字节避开 ASCII，避免误命中帧 ID）。
Uint8List dummyAudio() {
  final audio = Uint8List(96);
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

List<int> utf16Le(String text) {
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

String fileNameOf(String path) {
  final index = path.lastIndexOf(Platform.pathSeparator);
  return index >= 0 ? path.substring(index + 1) : path;
}

/// 下载目录里残留的临时文件（.part / .id3.tmp）。
List<String> leftoverFiles(Directory dir) {
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .map((file) => fileNameOf(file.path))
      .where(
        (name) =>
            name.endsWith('.part') ||
            name.endsWith(Id3TagWriter.tempSuffix),
      )
      .toList();
}
