// 下载音质设置（issue #8）：设置值存取、生效档位解析、无源降级回归。
//
// 口径（见 docs/superpowers/plans/2026-11-02-download-quality-setting.md）：
// - 设置页「下载音质」的覆盖值存在 DownloadController 内（null = 跟随播放
//   音质），下载入口仍传 player.audioQuality，由控制器内部解析，避免改
//   动 11 处 UI 调用点；
// - 失败重试按条目原档位重下，必须绕过覆盖值（respectQualityOverride）；
// - 无源降级只发生在「空地址 / 需要 VIP」，网络异常不降级——否则弱网
//   会被伪装成「这首歌只有低音质」。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/services/music_api.dart';

const _qualityKey = 'settings.download_quality';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late Directory currentDir;
  late _FakeDownloadService service;
  late _FakeApi api;
  late DownloadController controller;

  Song song({String hash = 'quality_song'}) => Song(
    id: '1',
    title: '音质歌',
    artist: '歌手',
    hash: hash,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpRoot = await Directory.systemTemp.createTemp('shiyin_download_quality_');
    currentDir = Directory('${tmpRoot.path}/current')
      ..createSync(recursive: true);
    service = _FakeDownloadService(currentDir: currentDir);
    api = _FakeApi();
    controller = DownloadController(service, api);
    await controller.initialize();
  });

  tearDown(() async {
    // 给在途的批量 worker 一点时间落地，避免目录删除与写文件竞态。
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    try {
      await tmpRoot.delete(recursive: true);
    } catch (_) {}
  });

  group('Task 1 设置值存取与生效档位解析', () {
    test('默认（未设置）跟随播放音质', () async {
      expect(controller.downloadQualityOverride, isNull);
      expect(
        controller.resolveDownloadQuality(AudioQuality.lossless),
        AudioQuality.lossless,
      );
      expect(
        controller.resolveDownloadQuality(AudioQuality.standard),
        AudioQuality.standard,
      );
    });

    test('设置覆盖值后不再跟随播放音质', () async {
      await controller.setDownloadQuality(AudioQuality.high);
      expect(controller.downloadQualityOverride, AudioQuality.high);
      expect(
        controller.resolveDownloadQuality(AudioQuality.lossless),
        AudioQuality.high,
      );
    });

    test('设置持久化：新 controller initialize 后仍生效', () async {
      await controller.setDownloadQuality(AudioQuality.lossless);
      final another = DownloadController(
        _FakeDownloadService(currentDir: currentDir),
        _FakeApi(),
      );
      await another.initialize();
      expect(another.downloadQualityOverride, AudioQuality.lossless);
    });

    test('清除设置（null）恢复跟随播放音质', () async {
      await controller.setDownloadQuality(AudioQuality.high);
      await controller.setDownloadQuality(null);
      expect(controller.downloadQualityOverride, isNull);
      expect(
        controller.resolveDownloadQuality(AudioQuality.lossless),
        AudioQuality.lossless,
      );
      // 持久层也要清掉，否则重启后又变回固定 320K。
      final another = DownloadController(
        _FakeDownloadService(currentDir: currentDir),
        _FakeApi(),
      );
      await another.initialize();
      expect(another.downloadQualityOverride, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_qualityKey), isNull);
    });

    test('脏值（"abc" / "follow" / 空串）按跟随处理', () async {
      for (final raw in ['abc', 'follow', '']) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_qualityKey, raw);
        final another = DownloadController(
          _FakeDownloadService(currentDir: currentDir),
          _FakeApi(),
        );
        await another.initialize();
        expect(
          another.downloadQualityOverride,
          isNull,
          reason: '脏值 "$raw" 应回落到跟随播放音质',
        );
      }
    });
  });

  group('Task 2 下载入口接入覆盖值 + 重试旁路', () {
    test('设置 320K 后单曲下载按设置取地址、落盘与条目记 320K', () async {
      await controller.setDownloadQuality(AudioQuality.high);
      // 调用点仍传播放音质（无损），由控制器解析成设置档位。
      await controller.download(song(), AudioQuality.lossless);

      expect(api.requested, [AudioQuality.high]);
      expect(service.downloadRequests.single.quality, AudioQuality.high);
      final entry = controller.entryFor(song())!;
      expect(entry.quality, AudioQuality.high);
      expect(entry.status, DownloadStatus.downloaded);
      // 扩展名跟着实际档位走：320K 必须是 mp3。
      expect(entry.filePath, endsWith('.mp3'));
    });

    test('跟随播放音质（未设置）时仍按调用点传入档位（默认行为不变）', () async {
      await controller.download(song(), AudioQuality.lossless);

      expect(api.requested, [AudioQuality.lossless]);
      final entry = controller.entryFor(song())!;
      expect(entry.quality, AudioQuality.lossless);
      expect(entry.filePath, endsWith('.flac'));
    });

    test('失败重试 respectQualityOverride:false 时按条目原档位（不被设置改写）', () async {
      await controller.setDownloadQuality(AudioQuality.high);
      await controller.download(
        song(),
        AudioQuality.lossless,
        respectQualityOverride: false,
      );

      expect(api.requested, [AudioQuality.lossless]);
      final entry = controller.entryFor(song())!;
      expect(entry.quality, AudioQuality.lossless);
      expect(entry.filePath, endsWith('.flac'));
    });

    test('批量下载同样按设置档位解析', () async {
      await controller.setDownloadQuality(AudioQuality.high);
      final result = await controller.enqueueBatch(
        [song(hash: 'batch_a'), song(hash: 'batch_b')],
        AudioQuality.lossless,
      );
      await _drain();

      expect(result.enqueued, 2);
      expect(api.requested, everyElement(AudioQuality.high));
      expect(
        service.downloadRequests.map((r) => r.quality),
        everyElement(AudioQuality.high),
      );
      expect(controller.downloadEntries.singleWhere(
        (e) => e.song.hash == 'batch_a',
      ).quality, AudioQuality.high);
    });
  });

  group('Task 3 无源自动降档', () {
    test('无损返回 VIP 异常时降级到 320 并记录实际档位', () async {
      api.behavior[AudioQuality.lossless] = 'vip';
      await controller.download(song(), AudioQuality.lossless);

      expect(api.requested, [AudioQuality.lossless, AudioQuality.high]);
      final entry = controller.entryFor(song())!;
      expect(entry.status, DownloadStatus.downloaded);
      // 条目记实际档位，扩展名才跟着对（不是「flac 名字的 mp3」）。
      expect(entry.quality, AudioQuality.high);
      expect(entry.filePath, endsWith('.mp3'));
    });

    test('无损地址为空时降级；320 也为空则降到 128', () async {
      api.behavior[AudioQuality.lossless] = 'empty';
      api.behavior[AudioQuality.high] = 'empty';
      await controller.download(song(), AudioQuality.lossless);

      expect(api.requested, [
        AudioQuality.lossless,
        AudioQuality.high,
        AudioQuality.standard,
      ]);
      final entry = controller.entryFor(song())!;
      expect(entry.status, DownloadStatus.downloaded);
      expect(entry.quality, AudioQuality.standard);
      expect(entry.filePath, endsWith('.mp3'));
    });

    test('网络异常不降级，直接失败（不伪装成没音源）', () async {
      api.behavior[AudioQuality.lossless] = 'network';
      await controller.download(song(), AudioQuality.lossless);

      // 只请求过 flac：弱网/超时不能触发降档，否则用户会以为歌只有 320K。
      expect(api.requested, [AudioQuality.lossless]);
      final entry = controller.entryFor(song())!;
      expect(entry.status, DownloadStatus.failed);
      expect(entry.error, isNotNull);
      expect(service.downloadRequests, isEmpty);
    });

    test('设置 320 且 320 无源时降到 128（覆盖值与降级链共同生效）', () async {
      await controller.setDownloadQuality(AudioQuality.high);
      api.behavior[AudioQuality.high] = 'empty';
      await controller.download(song(), AudioQuality.lossless);

      expect(api.requested, [AudioQuality.high, AudioQuality.standard]);
      final entry = controller.entryFor(song())!;
      expect(entry.quality, AudioQuality.standard);
      expect(entry.status, DownloadStatus.downloaded);
    });

    test('整条降级链都无源时进入失败列表（可重试）', () async {
      api.behavior[AudioQuality.lossless] = 'vip';
      api.behavior[AudioQuality.high] = 'empty';
      api.behavior[AudioQuality.standard] = 'empty';
      await controller.download(song(), AudioQuality.lossless);

      expect(api.requested, hasLength(3));
      final entry = controller.entryFor(song())!;
      expect(entry.status, DownloadStatus.failed);
      expect(entry.error, contains('可播放地址'));
      expect(service.downloadRequests, isEmpty);
    });

    test('批量下载同样走降级链', () async {
      api.behavior[AudioQuality.lossless] = 'vip';
      final result = await controller.enqueueBatch(
        [song(hash: 'batch_degrade')],
        AudioQuality.lossless,
      );
      await _drain();

      expect(result.enqueued, 1);
      expect(result.failed, 0);
      expect(api.requested, [AudioQuality.lossless, AudioQuality.high]);
      final entry = controller.downloadEntries.singleWhere(
        (e) => e.song.hash == 'batch_degrade',
      );
      expect(entry.quality, AudioQuality.high);
      expect(entry.status, DownloadStatus.downloaded);
    });
  });
}

/// 让批量下载的 unawaited 传输任务在断言前落地。
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 真实临时目录驱动的下载服务替身：只覆写控制器实际调用的成员。
///
/// 与 download_hash_normalization_test.dart 的同名替身同源（那边已验证
/// initialize/reconcile 用到的成员集），额外记录每次传输的档位，并让落盘
/// 扩展名跟着档位走，便于断言「无损存 .flac / 降档后存 .mp3」。
class _FakeDownloadService implements DownloadService {
  _FakeDownloadService({required this.currentDir});

  final Directory currentDir;

  /// 每次 download 请求的（歌曲, 档位），按调用顺序记录。
  final List<({Song song, AudioQuality quality})> downloadRequests = [];

  int _fileSeq = 0;

  @override
  Future<Directory> downloadDir() async {
    if (!currentDir.existsSync()) currentDir.createSync(recursive: true);
    return currentDir;
  }

  @override
  Future<List<Directory>> legacyDownloadDirs() async => const [];

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
    downloadRequests.add((song: song, quality: quality));
    final ext = quality == AudioQuality.lossless ? 'flac' : 'mp3';
    final path = '${currentDir.path}/file_${_fileSeq++}.$ext';
    File(path).writeAsStringSync('downloaded-bytes');
    onProgress(1, 1);
    return path;
  }

  @override
  Future<void> cancel(
    String cacheKey, {
    DownloadTaskKind kind = DownloadTaskKind.download,
  }) async {}

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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 播放地址接口替身：按档位配置「正常 / 空地址 / VIP / 网络错误」。
class _FakeApi implements MusicApi {
  /// 档位 -> 响应模式；缺省 = 正常返回地址。
  /// - `'empty'`：返回空地址（服务端明确没有该档音源）；
  /// - `'vip'`：抛 [VipRequiredException]；
  /// - `'network'`：抛超时异常（必须不触发降级）。
  final Map<AudioQuality, String> behavior = {};

  /// 实际请求过的档位，按顺序记录。
  final List<AudioQuality> requested = [];

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async {
    requested.add(quality);
    switch (behavior[quality]) {
      case 'vip':
        throw const VipRequiredException();
      case 'network':
        throw DioException(
          requestOptions: RequestOptions(path: '/song/url'),
          type: DioExceptionType.connectionTimeout,
        );
      case 'empty':
        return PlayUrl(url: '', hash: song.hash);
    }
    return PlayUrl(
      url: 'https://example.com/${song.hash}_${quality.apiValue}.mp3',
      hash: song.hash,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
