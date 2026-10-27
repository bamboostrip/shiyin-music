// 本地下载识别补强（P1-4.5）：下载索引 key 归一（trim + 小写）回归。
//
// 背景：同一首歌在不同入口（歌单导入 / 搜索 / 云盘 / 历史恢复）返回的
// hash 大小写可能不一致。旧实现按原始 hash 存/查下载索引，大小写不同即
// 「明明已下载却判未下载而走网络」（歌单导入链路已用小写 hash 比对）。
//
// 修复口径：
// - 下载识别键统一 `trim + lowercase`（_downloadKey/_normalizeHash）；
// - 旧索引兼容采用「加载时迁移」：持久化 JSON 只存 Song 对象、不存 map
//   key，索引键始终由 Song.hash 派生，加载插入时归一即完成迁移（幂等，
//   无需回写 prefs，也不改写 Song.hash 原始值——播放地址接口仍按它请求）；
// - play-cache 同曲映射（_playCacheByHash）按归一 hash 建表/查询；
// - 移除/取消/清空/磁盘对账（目录重写）等路径与表 key 同口径；
// - localPathFor 的同步文件存在性校验保持不动（本文件含回归用例）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/services/music_api.dart';

const _indexKey = 'shiyin_downloads_index';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late Directory currentDir;
  late Directory legacyDir;
  late _FakeDownloadService service;
  late DownloadController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpRoot = await Directory.systemTemp.createTemp('shiyin_download_hash_');
    currentDir = Directory('${tmpRoot.path}/current')
      ..createSync(recursive: true);
    legacyDir = Directory('${tmpRoot.path}/legacy')
      ..createSync(recursive: true);
    service = _FakeDownloadService(
      currentDir: currentDir,
      legacyDirs: [legacyDir],
    );
    controller = DownloadController(service, _FakeApi());
  });

  tearDown(() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    try {
      await tmpRoot.delete(recursive: true);
    } catch (_) {}
  });

  File writeFile(String name, [String content = 'audio-bytes']) {
    final file = File('${tmpRoot.path}/$name')..createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  /// 预置下载索引（模拟旧版本持久化：存原始大小写 hash 的 Song 对象）。
  Future<void> seedDownloads(List<_SeedEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _indexKey,
      jsonEncode([
        for (final entry in entries)
          {
            'song': entry.song.toCache(),
            'quality': entry.quality.apiValue,
            'filePath': entry.filePath,
            'downloadedAt': '2026-10-01T00:00:00.000',
          },
      ]),
    );
  }

  Future<List<dynamic>> readIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_indexKey);
    if (raw == null || raw.isEmpty) return const [];
    return jsonDecode(raw) as List;
  }

  group('已下载识别：hash 归一（trim + 小写）', () {
    test('旧索引大写 hash：小写/原始大小写查询都命中已下载', () async {
      final rawSong = const Song(
        id: '1',
        title: '云盘歌',
        artist: '歌手',
        hash: 'ABC123',
      );
      final file = writeFile('a.mp3');
      await seedDownloads([
        _SeedEntry(rawSong, AudioQuality.standard, file.path),
      ]);
      await controller.initialize();

      final lower = const Song(
        id: '1',
        title: '云盘歌',
        artist: '歌手',
        hash: 'abc123',
      );
      expect(controller.isDownloaded(lower), isTrue);
      expect(controller.entryFor(lower)?.filePath, file.path);
      expect(controller.entryFor(rawSong)?.filePath, file.path);
      // 归一后同一条目：不会因为大小写不同出现第二条。
      expect(controller.downloadEntries, hasLength(1));
    });

    test('hash 带首尾空格：trim 后命中已下载', () async {
      final rawSong = const Song(
        id: '2',
        title: '空格 hash',
        artist: '歌手',
        hash: '  PaddedHash  ',
      );
      final file = writeFile('b.mp3');
      await seedDownloads([
        _SeedEntry(rawSong, AudioQuality.standard, file.path),
      ]);
      await controller.initialize();

      final query = const Song(
        id: '2',
        title: '空格 hash',
        artist: '歌手',
        hash: 'paddedhash',
      );
      expect(controller.isDownloaded(query), isTrue);
      expect(controller.localPathFor(query, AudioQuality.standard), file.path);
    });

    test('localPathFor：同音质命中归一；跨音质不命中，由 AnyQuality 降级命中', () async {
      final rawSong = const Song(
        id: '3',
        title: '无损下载',
        artist: '歌手',
        hash: 'FLAC_HASH',
      );
      final file = writeFile('c.flac');
      await seedDownloads([
        _SeedEntry(rawSong, AudioQuality.lossless, file.path),
      ]);
      await controller.initialize();

      final lower = const Song(
        id: '3',
        title: '无损下载',
        artist: '歌手',
        hash: 'flac_hash',
      );
      // 同音质：归一后直接命中（旧实现 cacheKey 字符串比较会漏判）。
      expect(controller.localPathFor(lower, AudioQuality.lossless), file.path);
      // 跨音质：exact 不命中（保持既有语义），AnyQuality 降级命中。
      expect(controller.localPathFor(lower, AudioQuality.standard), isNull);
      expect(
        controller.localPathForAnyQuality(
          lower,
          preferredQuality: AudioQuality.standard,
        ),
        file.path,
      );
    });

    test('文件存在性校验保持：索引命中但文件被外部删除 → localPathFor 返回 null', () async {
      final rawSong = const Song(
        id: '4',
        title: '被删文件',
        artist: '歌手',
        hash: 'GONE1',
      );
      final file = writeFile('d.mp3');
      await seedDownloads([
        _SeedEntry(rawSong, AudioQuality.standard, file.path),
      ]);
      await controller.initialize();
      expect(controller.isDownloaded(rawSong), isTrue);

      // 启动对账已跑完，之后外部删除：索引仍在（既有行为），本地路径不可用。
      file.deleteSync();
      final lower = const Song(
        id: '4',
        title: '被删文件',
        artist: '歌手',
        hash: 'gone1',
      );
      expect(controller.isDownloaded(lower), isTrue);
      expect(controller.localPathFor(lower, AudioQuality.standard), isNull);
      expect(controller.localPathForAnyQuality(lower), isNull);
    });
  });

  group('下载写入：新条目按归一 key 识别', () {
    test('大写 hash 下载后小写查询命中；Song.hash 原始值保留（不回写）', () async {
      final song = const Song(
        id: '5',
        title: '新下载',
        artist: '歌手',
        hash: 'MiXeDKey',
      );

      await controller.download(song, AudioQuality.standard);

      final lower = const Song(
        id: '5',
        title: '新下载',
        artist: '歌手',
        hash: 'mixedkey',
      );
      expect(controller.isDownloaded(song), isTrue);
      expect(controller.isDownloaded(lower), isTrue);
      // Song 原始 hash 必须保留：播放地址等接口仍按原值请求。
      expect(controller.entryFor(lower)?.song.hash, 'MiXeDKey');

      // 持久化索引同样保留原始 Song（key 由加载时归一派生）。
      final persisted = await readIndex();
      expect(persisted, hasLength(1));
      expect((persisted.single as Map)['song']['hash'], 'MiXeDKey');
    });

    test('批量下载：大小写不同的同一首歌只入队一次', () async {
      final upper = const Song(
        id: '6',
        title: '批量',
        artist: '歌手',
        hash: 'BATCH1',
      );
      final lower = const Song(
        id: '6',
        title: '批量',
        artist: '歌手',
        hash: 'batch1',
      );

      final result = await controller.enqueueBatch([
        upper,
        lower,
      ], AudioQuality.standard);
      await _drain();

      expect(result.total, 1);
      expect(controller.downloadEntries, hasLength(1));
      expect(controller.isDownloaded(lower), isTrue);
    });

    test('已下载（大写 hash）后：小写 hash 的歌不再重复写播放缓存', () async {
      final downloaded = const Song(
        id: '7',
        title: '已下载',
        artist: '歌手',
        hash: 'DONE_KEY',
      );
      final file = writeFile('e.mp3');
      await seedDownloads([
        _SeedEntry(downloaded, AudioQuality.standard, file.path),
      ]);
      await controller.initialize();

      final lower = const Song(
        id: '7',
        title: '已下载',
        artist: '歌手',
        hash: 'done_key',
      );
      await controller.cacheForPlayback(
        lower,
        AudioQuality.standard,
        'https://example.com/stream.mp3',
      );
      await _drain();

      expect(controller.playCacheEntries, isEmpty);
      expect(service.playCacheWrites, isEmpty);
    });
  });

  group('移除 / 取消 / 清空路径与索引同口径', () {
    test('deleteDownload：小写 hash 命中大写索引条目，并删除文件/索引', () async {
      final rawSong = const Song(
        id: '8',
        title: '删除我',
        artist: '歌手',
        hash: 'DELETE_ME',
      );
      final file = writeFile('f.mp3');
      await seedDownloads([
        _SeedEntry(rawSong, AudioQuality.standard, file.path),
      ]);
      await controller.initialize();

      final lower = const Song(
        id: '8',
        title: '删除我',
        artist: '歌手',
        hash: 'delete_me',
      );
      await controller.deleteDownload(lower);
      await _drain();

      expect(controller.entryFor(rawSong), isNull);
      expect(File(file.path).existsSync(), isFalse);
      expect(await readIndex(), isEmpty);
    });

    test('cancelDownload：小写 hash 能取消大写 hash 的下载中条目', () async {
      final song = const Song(
        id: '9',
        title: '取消我',
        artist: '歌手',
        hash: 'CANCEL_ME',
      );
      service.hangNextDownload();
      final downloadFuture = controller.download(song, AudioQuality.standard);
      await _drain();
      expect(controller.entryFor(song)?.status, DownloadStatus.downloading);

      final lower = const Song(
        id: '9',
        title: '取消我',
        artist: '歌手',
        hash: 'cancel_me',
      );
      await controller.cancelDownload(lower);
      await downloadFuture;
      await _drain();

      expect(controller.entryFor(song), isNull);
      expect(service.cancelledKeys, hasLength(1));
    });

    test('removeFailed：小写 hash 移除大写 hash 的失败条目', () async {
      final api = _FakeApi()..failSongUrl = true;
      final failing = DownloadController(service, api);
      final song = const Song(
        id: '10',
        title: '失败歌曲',
        artist: '歌手',
        hash: 'FAIL_KEY',
      );

      await failing.download(song, AudioQuality.standard);
      await _drain();
      expect(failing.entryFor(song)?.status, DownloadStatus.failed);

      failing.removeFailed(
        const Song(id: '10', title: '失败歌曲', artist: '歌手', hash: 'fail_key'),
      );
      expect(failing.entryFor(song), isNull);
    });
  });

  group('磁盘对账（目录重写）按归一 key 记账', () {
    test('旧索引大写 hash + 文件在历史目录：对账搬入当前目录后小写查询可见', () async {
      final rawSong = const Song(
        id: '11',
        title: '历史迁移',
        artist: '歌手',
        hash: 'LEGACY_KEY',
      );
      final legacyFile = File('${legacyDir.path}/migrate.mp3')
        ..writeAsStringSync('legacy-bytes');
      await seedDownloads([
        _SeedEntry(rawSong, AudioQuality.standard, legacyFile.path),
      ]);

      await controller.initialize();

      final lower = const Song(
        id: '11',
        title: '历史迁移',
        artist: '歌手',
        hash: 'legacy_key',
      );
      final entry = controller.entryFor(lower);
      expect(entry?.filePath, '${currentDir.path}/migrate.mp3');
      expect(File('${currentDir.path}/migrate.mp3').existsSync(), isTrue);
      expect(File(legacyFile.path).existsSync(), isFalse);
    });
  });

  group('play-cache 同曲映射按归一 hash 建表', () {
    test('localPathFor：同音质播放缓存，大小写不同的 hash 也能命中', () async {
      final cached = const Song(
        id: '13',
        title: '精确缓存',
        artist: '歌手',
        hash: 'CACHE2_KEY',
      );
      await controller.cacheForPlayback(
        cached,
        AudioQuality.standard,
        'https://example.com/c2.mp3',
      );
      await _drain();
      expect(controller.playCacheEntries, hasLength(1));

      final lower = const Song(
        id: '13',
        title: '精确缓存',
        artist: '歌手',
        hash: 'cache2_key',
      );
      // cacheKey 按原始 hash 生成 → 精确查不中，经归一 hash 同曲索引兜底。
      expect(controller.localPathFor(lower, AudioQuality.standard), isNotNull);
      // 跨音质 exact 仍不命中（保持既有语义，交给 AnyQuality 降级）。
      expect(controller.localPathFor(lower, AudioQuality.lossless), isNull);
    });

    test('AnyQuality 降级：大小写不同的 hash 也能命中播放缓存', () async {
      final cached = const Song(
        id: '12',
        title: '缓存歌',
        artist: '歌手',
        hash: 'CACHE_KEY',
      );
      await controller.cacheForPlayback(
        cached,
        AudioQuality.standard,
        'https://example.com/cache.mp3',
      );
      await _drain();
      expect(controller.playCacheEntries, hasLength(1));

      final lower = const Song(
        id: '12',
        title: '缓存歌',
        artist: '歌手',
        hash: 'cache_key',
      );
      // 首选音质（lossless）无缓存 → 降级走 _playCacheByHash[归一 hash]。
      final path = controller.localPathForAnyQuality(
        lower,
        preferredQuality: AudioQuality.lossless,
      );
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      // 归一后只索引一次（_playCacheByHash 不重复建 key）。
      expect(controller.playCacheEntries.single.song.hash, 'CACHE_KEY');
    });
  });
}

/// 预置索引条目。
class _SeedEntry {
  const _SeedEntry(this.song, this.quality, this.filePath);

  final Song song;
  final AudioQuality quality;
  final String filePath;
}

Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 以真实临时目录驱动的下载服务替身：download/cacheForPlayback 真正落盘，
/// 便于验证 localPathFor 的同步 existsSync 与对账搬移路径。
class _FakeDownloadService implements DownloadService {
  _FakeDownloadService({required this.currentDir, required this.legacyDirs});

  final Directory currentDir;
  final List<Directory> legacyDirs;

  final List<Song> playCacheWrites = [];
  final List<String> cancelledKeys = [];

  Completer<void>? _hangTransfer;
  int _fileSeq = 0;

  @override
  Future<Directory> downloadDir() async {
    if (!currentDir.existsSync()) currentDir.createSync(recursive: true);
    return currentDir;
  }

  @override
  Future<List<Directory>> legacyDownloadDirs() async => legacyDirs;

  @override
  String resolveNonCollidingPath(String targetPath, String partPath) =>
      targetPath;

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
  Future<String> download({
    required Song song,
    required AudioQuality quality,
    required String url,
    required void Function(int received, int total) onProgress,
  }) async {
    if (_hangTransfer != null) {
      await _hangTransfer!.future;
    }
    final path = '${currentDir.path}/file_${_fileSeq++}.mp3';
    File(path).writeAsStringSync('downloaded-bytes');
    onProgress(1, 1);
    return path;
  }

  @override
  Future<void> cancel(
    String cacheKey, {
    DownloadTaskKind kind = DownloadTaskKind.download,
  }) async {
    cancelledKeys.add(cacheKey);
    final hang = _hangTransfer;
    _hangTransfer = null;
    if (hang != null && !hang.isCompleted) {
      hang.completeError(
        DioException(
          requestOptions: RequestOptions(path: ''),
          type: DioExceptionType.cancel,
        ),
      );
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  @override
  Future<String> cacheForPlayback({
    required Song song,
    required AudioQuality quality,
    required String url,
  }) async {
    playCacheWrites.add(song);
    final path = '${currentDir.path}/cache_${_fileSeq++}.mp3';
    File(path).writeAsStringSync('cached-bytes');
    return path;
  }

  @override
  Future<void> prunePlayCache(
    List<({String cacheKey, String filePath, DateTime cachedAt})> entries, {
    int? maxBytes,
    Set<String> excludePaths = const {},
  }) async {}

  /// 让下一次 [download] 挂起（取消用例）。
  void hangNextDownload() => _hangTransfer = Completer<void>();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeApi implements MusicApi {
  bool failSongUrl = false;

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async {
    if (failSongUrl) throw Exception('no url');
    return PlayUrl(
      url: 'https://example.com/${song.hash}.mp3',
      hash: song.hash,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
