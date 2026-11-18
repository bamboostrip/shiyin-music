// 旧下载迁移/补扫（`repairDownloadedFiles`）的字节级用例。
//
// 覆盖交接文档 `2026-11-18-download-migration-and-scan-order-test.md` 的验收
// 清单：升级前落盘的文件不走新下载的收尾链路，扩展名可能撒谎、没有内嵌标签，
// 这里把「字节判型 → 扩展名纠正 → 写标签 → 重扫媒体库」整条补做一遍。
//
// 全部用真实临时目录 + 最小构造音频样本跑真实 IO：标签写入是按字节改文件的
// 操作，写错位置会直接毁掉一首歌，只有读回原始字节断言才算数。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/download_metadata_writer.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/services/music_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late _RepairService service;

  /// 一段「音频帧」字节（内容只要不变就够，不需要真是可解码音频）。
  final audioBytes = List<int>.generate(512, (index) => (index * 7 + 3) & 0xff);

  const song = Song(
    id: '1',
    title: '修复歌',
    artist: '修复歌手',
    hash: 'repair_song',
    albumName: '修复专辑',
  );
  const song2 = Song(id: '2', title: '第二首', artist: '修复歌手', hash: 'repair_song_2');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('shiyin_repair_');
    service = _RepairService(dir: tmpDir);
  });

  tearDown(() async {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 指定长度的「音频帧」字节（内容固定，便于按长度区分不同歌）。
  List<int> audioOf(int length) =>
      List<int>.generate(length, (index) => (index * 7 + 3) & 0xff);

  /// 构造最小 FLAC：`fLaC` + STREAMINFO(34) + 音频帧。
  Uint8List buildFlac({int audioLength = 512}) {
    final builder = BytesBuilder();
    builder.add([0x66, 0x4c, 0x61, 0x43]); // 'fLaC'
    const length = 34;
    builder.add([
      0x80 | 0x00,
      (length >> 16) & 0xff,
      (length >> 8) & 0xff,
      length & 0xff,
    ]);
    builder.add(List<int>.filled(length, 0x11));
    builder.add(audioOf(audioLength));
    return builder.takeBytes();
  }

  /// 构造最小 MP3：一个 MPEG1 Layer III 帧同步 + 音频帧。
  Uint8List buildMp3({int audioLength = 512}) {
    final builder = BytesBuilder();
    builder.add([0xff, 0xfb, 0x90, 0x00]);
    builder.add(audioOf(audioLength));
    return builder.takeBytes();
  }

  File writeFile(String name, List<int> bytes) {
    final file = File('${tmpDir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(bytes, flush: true);
    return file;
  }

  /// 预置多条已下载记录（顺序即表内顺序，修复按此顺序串行处理）。
  Future<void> seedIndexList(List<(Song, String)> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'shiyin_downloads_index',
      jsonEncode([
        for (final item in items)
          {
            'song': item.$1.toCache(),
            'quality': '128',
            'filePath': item.$2,
            'downloadedAt': '2026-09-01T00:00:00.000',
          },
      ]),
    );
  }

  /// 预置下载索引（一条已下载记录）。
  Future<void> seedIndex(String filePath, {Song? target}) =>
      seedIndexList([((target ?? song), filePath)]);

  Future<String> readIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('shiyin_downloads_index') ?? '';
  }

  DownloadController buildController() =>
      DownloadController(service, _FakeApi());

  test('.flac 里其实是 MP3 → 改名 .mp3 并写入 ID3 标签', () async {
    final path = writeFile('a.flac', buildMp3()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();

    final progress = <(int, int)>[];
    final result = await controller.repairDownloadedFiles(
      onProgress: (processed, total) => progress.add((processed, total)),
    );

    expect(result.total, 1);
    expect(result.repaired, 1);
    expect(result.renamed, 1);
    expect(result.failed, 0);

    // 旧名字消失、新名字出现，索引指向最终路径并已落盘
    expect(File(path).existsSync(), isFalse);
    final entry = controller.entryFor(song)!;
    expect(entry.filePath, endsWith('a.mp3'));
    expect(await readIndex(), contains('a.mp3'));

    final written = File(entry.filePath!).readAsBytesSync();
    expect(written.sublist(0, 3), [0x49, 0x44, 0x33]); // 'ID3'
    expect(written.sublist(written.length - audioBytes.length), audioBytes);
    // 进度：0/1 起、1/1 收
    expect(progress.first, (0, 1));
    expect(progress.last, (1, 1));
  });

  test('.mp3 里其实是 FLAC → 改名 .flac 并写 Vorbis comment', () async {
    final path = writeFile('b.mp3', buildFlac()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();

    final result = await controller.repairDownloadedFiles();

    expect(result.repaired, 1);
    expect(result.renamed, 1);
    expect(File(path).existsSync(), isFalse);
    final entry = controller.entryFor(song)!;
    expect(entry.filePath, endsWith('b.flac'));
    final written = File(entry.filePath!).readAsBytesSync();
    expect(written.sublist(0, 4), [0x66, 0x4c, 0x61, 0x43]); // 'fLaC'
    final asUtf8 = const Utf8Decoder(allowMalformed: true).convert(written);
    expect(asUtf8.contains('TITLE=修复歌'), isTrue);
    expect(asUtf8.contains('ARTIST=修复歌手'), isTrue);
    expect(asUtf8.contains('ALBUM=修复专辑'), isTrue);
  });

  test('扩展名已正确 → 只补标签，不改名', () async {
    final path = writeFile('c.mp3', buildMp3()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();

    final result = await controller.repairDownloadedFiles();

    expect(result.repaired, 1);
    expect(result.renamed, 0);
    expect(controller.entryFor(song)!.filePath, path);
    expect(File(path).readAsBytesSync().sublist(0, 3), [0x49, 0x44, 0x33]);
    expect(service.tagWrites, [path]);
  });

  test('目标名已存在且内容不同 → 落 (2) 备选名，两份都不丢', () async {
    // c.flac 里是 MP3（1024 字节音频帧），同名 c.mp3 是另一首歌
    final path = writeFile('c.flac', buildMp3(audioLength: 1024)).path;
    final occupied = writeFile('c.mp3', buildMp3()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();

    final result = await controller.repairDownloadedFiles();

    expect(result.repaired, 1);
    expect(result.renamed, 1);
    final entry = controller.entryFor(song)!;
    expect(entry.filePath, endsWith('c (2).mp3'));
    // 另一首歌的文件原样保留
    expect(File(occupied).existsSync(), isTrue);
    expect(File(occupied).readAsBytesSync(), buildMp3());
  });

  test('编码不支持（AAC/APE/WAV 等）→ 不改名、不写标签、不扫描', () async {
    final path = writeFile('d.mp3', List<int>.filled(64, 0x00)).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();
    final indexBefore = await readIndex();

    final result = await controller.repairDownloadedFiles();

    expect(result.skipped, 1);
    expect(result.repaired, 0);
    expect(controller.entryFor(song)!.filePath, path);
    expect(File(path).existsSync(), isTrue);
    expect(service.tagWrites, isEmpty);
    expect(service.scans, isEmpty);
    expect(await readIndex(), indexBefore);
  });

  test('写标签失败 → 记为失败、原文件与索引都不变', () async {
    final path = writeFile('e.mp3', buildMp3()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();
    final indexBefore = await readIndex();
    service.failTagWrite = true;

    final result = await controller.repairDownloadedFiles();

    expect(result.failed, 1);
    expect(result.repaired, 0);
    expect(File(path).existsSync(), isTrue);
    expect(controller.entryFor(song)!.filePath, path);
    expect(await readIndex(), indexBefore);
  });

  test('在播文件跳过（rename 会打断播放），下次再处理', () async {
    final path = writeFile('f.flac', buildMp3()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();
    controller.playingPathProvider = () => path;

    final result = await controller.repairDownloadedFiles();

    expect(result.skipped, 1);
    expect(result.repaired, 0);
    expect(File(path).existsSync(), isTrue);
    expect(service.tagWrites, isEmpty);
    expect(service.scans, isEmpty);
  });

  test('文件缺失 → 跳过（找回/裁剪交给对账），不写索引', () async {
    // 父目录整个不存在：对账判不出「外部删除」，条目会被保留
    final path = '${tmpDir.path}${Platform.pathSeparator}offline'
        '${Platform.pathSeparator}x.mp3';
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();
    final indexBefore = await readIndex();

    final result = await controller.repairDownloadedFiles();

    expect(result.skipped, 1);
    expect(controller.entryFor(song)?.status, DownloadStatus.downloaded);
    expect(await readIndex(), indexBefore);
  });

  test('重复执行幂等：不产生副本，标签是替换而不是叠加', () async {
    final path = writeFile('g.mp3', buildMp3()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();

    await controller.repairDownloadedFiles();
    final firstSize = File(path).lengthSync();
    final firstFiles = tmpDir.listSync().length;
    await controller.repairDownloadedFiles();
    final secondSize = File(path).lengthSync();

    expect(tmpDir.listSync().length, firstFiles);
    expect(secondSize, firstSize, reason: '二次写入应替换标签而不是叠加');
    expect(controller.entryFor(song)!.filePath, path);
  });

  test('标签实际没写进去（writer 返回 false）→ 记失败，不谎报「已更新」', () async {
    final path = writeFile('k.mp3', buildMp3()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();
    // writer 内部吞掉异常后返回 tagsWritten:false（改名被占用、文件被锁等）
    service.tagWriteReturnsFalse = true;

    final result = await controller.repairDownloadedFiles();

    expect(result.repaired, 0);
    expect(result.failed, 1);
    expect(File(path).existsSync(), isTrue);
  });

  test('修复期间条目被删除（快照已过期）→ 该条跳过，不抢删除/重下的文件', () async {
    final first = writeFile('p.mp3', buildMp3()).path;
    final second = writeFile('q.mp3', buildMp3()).path;
    await seedIndexList([(song, first), (song2, second)]);
    final controller = buildController();
    await controller.initialize();
    // 第一首写标签时把第二首删掉：真实竞态（用户在修复过程中点删除）
    service.onTagWrite = (filePath) async {
      if (filePath == first) await controller.deleteDownload(song2);
    };

    final result = await controller.repairDownloadedFiles();

    expect(result.repaired, 1);
    expect(result.skipped, 1);
    expect(service.tagWrites, [first], reason: '过期快照条目不应被处理');
    expect(File(second).existsSync(), isFalse);
    expect(controller.entryFor(song2), isNull);
  });

  test('落到 (2) 备选名时同名 .lrc 边文件跟着走（不留孤儿歌词）', () async {
    final path = writeFile('m.flac', buildMp3(audioLength: 1024)).path;
    writeFile('m.mp3', buildMp3()); // 同名另一首歌，占住 m.mp3
    writeFile('m.lrc', utf8.encode('[00:01.00]旧歌词'));
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();

    await controller.repairDownloadedFiles();

    final moved = File('${tmpDir.path}${Platform.pathSeparator}m (2).lrc');
    expect(controller.entryFor(song)!.filePath, endsWith('m (2).mp3'));
    expect(moved.existsSync(), isTrue);
    expect(moved.readAsStringSync(), contains('旧歌词'));
    // 原来那首歌的边文件位置不再被占（否则会读到别人的歌词）
    expect(
      File('${tmpDir.path}${Platform.pathSeparator}m.lrc').existsSync(),
      isFalse,
    );
  });

  test('非公共目录不扫描；公共目录才扫（Android 媒体库口径）', () async {
    final path = writeFile('h.mp3', buildMp3()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();

    service.sharedStorage = false;
    await controller.repairDownloadedFiles();
    expect(service.scans, isEmpty, reason: '应用专属目录扫了也没意义');

    service.sharedStorage = true;
    await controller.repairDownloadedFiles();
    expect(service.scans, [path]);
  });

  test('公共目录下改名：先扫旧路径（清 MediaStore 旧条目）再扫新路径', () async {
    final path = writeFile('j.flac', buildMp3()).path;
    await seedIndex(path);
    final controller = buildController();
    await controller.initialize();
    service.sharedStorage = true;

    await controller.repairDownloadedFiles();

    expect(service.scans, [
      path,
      endsWith('${Platform.pathSeparator}j.mp3'),
    ]);
  });

  test('顺手清理崩溃残留的标签临时文件（旧的不留、新的不动）', () async {
    final path = writeFile('i.mp3', buildMp3()).path;
    await seedIndex(path);
    final stale = writeFile('i.mp3.id3.tmp', buildMp3());
    final fresh = writeFile('i.flac.tag.tmp', buildFlac());
    stale.setLastModifiedSync(
      DateTime.now().subtract(const Duration(hours: 3)),
    );
    final controller = buildController();
    await controller.initialize();

    await controller.repairDownloadedFiles();

    expect(stale.existsSync(), isFalse, reason: '超过 1 小时的残片应回收');
    expect(fresh.existsSync(), isTrue, reason: '刚写入的临时文件不能碰');
  });
}

/// 真实 IO 的下载服务替身：扩展名纠正/标签写入/临时文件清理都委托给真实
/// [DownloadService]（用例要断言真实字节），只把扫描与目录替换成可控实现。
class _RepairService implements DownloadService {
  _RepairService({required this.dir});

  final Directory dir;
  final DownloadService _real = DownloadService();

  /// 记录写标签的目标路径（顺序即调用顺序）。
  final List<String> tagWrites = [];

  /// 记录媒体库扫描路径。
  final List<String> scans = [];

  /// 模拟「文件在公共目录」（Android 自定义到 Music/Download 的场景）。
  bool sharedStorage = false;

  bool failTagWrite = false;

  /// 模拟 writer「吞掉异常、返回 tagsWritten:false」的情形。
  bool tagWriteReturnsFalse = false;

  /// 每次写标签后的回调（供用例制造「修复期间条目被删」的竞态）。
  Future<void> Function(String filePath)? onTagWrite;

  @override
  Future<Directory> downloadDir() async {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  @override
  Future<List<Directory>> legacyDownloadDirs() async => const [];

  @override
  Future<bool> customDownloadDirUnavailable() async => false;

  @override
  String resolveNonCollidingPath(String targetPath, String partPath) =>
      _real.resolveNonCollidingPath(targetPath, partPath);

  @override
  Future<String> correctExtension(String path) => _real.correctExtension(path);

  @override
  Future<bool> isSharedStoragePath(String path) async => sharedStorage;

  @override
  Future<int> cleanStaleTagTempFilesIn(
    Directory dir, {
    Duration minAge = const Duration(hours: 1),
  }) => _real.cleanStaleTagTempFilesIn(dir, minAge: minAge);

  @override
  Future<DownloadMetadataResult> writeDownloadMetadata({
    required String filePath,
    required Song song,
    String? lyricsText,
    bool saveLyricsFile = false,
  }) async {
    tagWrites.add(filePath);
    if (failTagWrite) throw StateError('模拟写标签失败');
    if (tagWriteReturnsFalse) {
      return const DownloadMetadataResult(
        tagsWritten: false,
        lyricsEmbedded: false,
        sidecarWritten: false,
      );
    }
    final result = await _real.writeDownloadMetadata(
      filePath: filePath,
      song: song,
      lyricsText: lyricsText,
      saveLyricsFile: saveLyricsFile,
    );
    final hook = onTagWrite;
    if (hook != null) await hook(filePath);
    return result;
  }

  @override
  Future<void> scanForMediaLibrary(String filePath) async {
    scans.add(filePath);
  }

  @override
  Future<int> fileSize(String path) async {
    final file = File(path);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  @override
  String cacheKeyFor(Song song, AudioQuality quality) =>
      '${song.hash}_${quality.apiValue}';

  @override
  Set<String> inFlightKeysFor(DownloadTaskKind kind) => const {};

  @override
  Future<void> prunePlayCache(
    List<({String cacheKey, String filePath, DateTime cachedAt})> entries, {
    int? maxBytes,
    Set<String> excludePaths = const {},
  }) async {}

  @override
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeApi implements MusicApi {
  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async {
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
