// 下载收尾的调用顺序（`5ccfac2` 的防回归）。
//
// 为什么需要这组用例：`5ccfac2` 把媒体库扫描从 `DownloadService._executeTask`
// 挪到 `DownloadController._enrichDownload` 的写标签之后，但当时没有任何测试
// 引用 `scanForMediaLibrary`/`scanFile`——把整次提交回滚，现有测试仍全绿，
// 顺序被改回去只有真机 MediaStore / 车机蓝牙列表才能发现。
//
// 三个约定：
// 1. 顺序必须是 download → writeDownloadMetadata → scanForMediaLibrary：
//    MediaStore 在扫描当刻快照艺人/专辑/封面，先扫后写会长期显示「未知艺人」；
// 2. 写标签失败也要扫描：文件至少得先被系统看见，标签稍后由「修复已下载
//    文件」补写并重扫；漏扫则连条目都没有；
// 3. 扫描/写标签的异常都不能把已下载成功的歌判为失败。
import 'dart:async';
import 'dart:io';

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
  late _RecordingService service;
  late DownloadController controller;

  const song = Song(id: '1', title: '顺序歌', artist: '歌手', hash: 'order_song');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('shiyin_scan_order_');
    service = _RecordingService(dir: tmpDir);
    controller = DownloadController(service, _FakeApi());
    await controller.initialize();
  });

  tearDown(() async {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  test('新下载：落盘 → 写标签 → 扫媒体库', () async {
    await controller.download(song, AudioQuality.standard);

    expect(service.calls, [
      'download',
      'writeDownloadMetadata',
      'scanForMediaLibrary',
    ]);
    expect(controller.entryFor(song)?.status, DownloadStatus.downloaded);
    // 索引记录的是收尾之后的最终路径
    expect(controller.entryFor(song)?.filePath, isNotNull);
  });

  test('写标签抛异常：仍然扫描，且下载仍算成功', () async {
    service.failTagWrite = true;

    await controller.download(song, AudioQuality.standard);

    // 顺序不变，扫描依然在写标签之后发生（写失败也要让文件进媒体库）
    expect(service.calls, [
      'download',
      'writeDownloadMetadata',
      'scanForMediaLibrary',
    ]);
    expect(controller.entryFor(song)?.status, DownloadStatus.downloaded);
  });

  test('扫描抛异常：不影响下载结果（不计为失败）', () async {
    service.failScan = true;

    await controller.download(song, AudioQuality.standard);

    final entry = controller.entryFor(song);
    expect(entry?.status, DownloadStatus.downloaded);
    expect(entry?.filePath, isNotNull);
  });

  test('传输期间销毁：不写标签、不扫描、不写索引', () async {
    service.downloadGate = Completer<void>();
    final future = controller.download(song, AudioQuality.standard);
    await _drain();
    expect(service.calls, ['download']);

    controller.dispose();
    service.downloadGate!.complete();
    await future;

    expect(service.calls, ['download'], reason: '销毁后不应再进入收尾链路');
    // 条目停留在下载态、没有最终路径（结果被丢弃，不复活也不落索引）
    expect(controller.entryFor(song)?.filePath, isNull);
  });
}

/// 让地址解析等异步步骤在断言前落地。
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 记录收尾调用顺序的服务替身。
///
/// 与 `download_quality_test.dart` 的替身不同：这里必须**真实实现**
/// `writeDownloadMetadata` 与 `scanForMediaLibrary`。那边用 `noSuchMethod`
/// 抛错，`_enrichDownload` 会把异常吞掉，永远走不到写标签/扫描，顺序也就
/// 无从断言。
class _RecordingService implements DownloadService {
  _RecordingService({required this.dir});

  final Directory dir;

  /// 按调用顺序记录 `download` / `writeDownloadMetadata` /
  /// `scanForMediaLibrary`。
  final List<String> calls = [];

  bool failTagWrite = false;
  bool failScan = false;

  /// 非空时 `download()` 挂起，供「传输期间销毁」用例控制时序。
  Completer<void>? downloadGate;

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
    calls.add('download');
    final gate = downloadGate;
    if (gate != null) await gate.future;
    final path = '${dir.path}/${song.hash}.mp3';
    File(path).writeAsStringSync('fake-audio-bytes');
    onProgress(1, 1);
    return path;
  }

  @override
  Future<DownloadMetadataResult> writeDownloadMetadata({
    required String filePath,
    required Song song,
    String? lyricsText,
    bool saveLyricsFile = false,
  }) async {
    calls.add('writeDownloadMetadata');
    if (failTagWrite) throw StateError('模拟写标签失败');
    return const DownloadMetadataResult(
      tagsWritten: true,
      lyricsEmbedded: false,
      sidecarWritten: false,
    );
  }

  @override
  Future<void> scanForMediaLibrary(String filePath) async {
    // 先记账再抛：用例要断言「抛错的这一次也算扫描发生过」。
    calls.add('scanForMediaLibrary');
    if (failScan) throw StateError('模拟扫描失败');
  }

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

/// 地址解析替身：歌词返回空（收尾不联网等待），地址正常。
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
