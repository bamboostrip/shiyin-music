import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 下载索引对账（reconcileDownloads）：
/// - 外部删除：文件到处不存在 → 移除条目并持久化；
/// - 历史目录迁移：文件仍在旧目录 → 搬入当前目录并重写路径；
/// - 改名错位找回：索引指向 shiyin 名目录、文件留在 ka_music 目录；
/// - 当前目录同名采用 / 同名冲突（同大小采用、异大小换名保留）；
/// - 在播文件与下载中条目不受对账影响。
void main() {
  late Directory tmpRoot;
  late Directory currentDir;
  late Directory legacyDir;
  late Directory legacyKaDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpRoot = await Directory.systemTemp.createTemp('shiyin_reconcile_');
    currentDir = Directory('${tmpRoot.path}/current')
      ..createSync(recursive: true);
    legacyDir = Directory('${tmpRoot.path}/legacy_shiyin')
      ..createSync(recursive: true);
    legacyKaDir = Directory('${tmpRoot.path}/legacy_ka')
      ..createSync(recursive: true);
  });

  tearDown(() async {
    try {
      await tmpRoot.delete(recursive: true);
    } catch (_) {}
  });

  File writeFile(String path, [String content = 'audio-bytes']) {
    final file = File(path);
    file.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  /// 以真实磁盘目录驱动对账：当前目录 + 两个历史目录候选。
  DownloadController buildController({bool withLegacyDirs = true}) {
    return DownloadController(
      _FakeDownloadService(
        currentDir: currentDir,
        legacyDirs: withLegacyDirs ? [legacyDir, legacyKaDir] : const [],
      ),
      _FakeApi(),
    );
  }

  /// 预置下载索引（一条已下载记录，[filePath] 任意，不必存在）。
  Future<void> seedIndex(Song song, String filePath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'shiyin_downloads_index',
      jsonEncode([
        {
          'song': song.toCache(),
          'quality': '128',
          'filePath': filePath,
          'downloadedAt': '2026-09-01T00:00:00.000',
        },
      ]),
    );
  }

  Future<String> readIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('shiyin_downloads_index') ?? '';
  }

  test('外部删除：文件到处不存在 → 移除条目并持久化', () async {
    // 目录仍在、文件被删才是可判定的「外部删除」；目录整个不可见
    // （卷离线口径）走下面的保留用例。
    final goneDir = Directory('${tmpRoot.path}/gone')..createSync();
    File('${goneDir.path}/a.mp3').writeAsBytesSync([1, 2, 3]);
    File('${goneDir.path}/a.mp3').deleteSync();
    final controller = buildController();
    await seedIndex(_song, '${goneDir.path}/a.mp3');

    await controller.initialize();

    expect(controller.downloadEntries, isEmpty);
    expect(jsonDecode(await readIndex()), isEmpty);
    // 幂等：再次对账无新变化
    expect(await controller.reconcileDownloads(), 0);
  });

  test('目录整体不可见（外置盘/NAS 离线口径）→ 保留条目不移除', () async {
    // 条目指向的目录不存在时无法区分「文件被删」与「整个卷离线」：
    // 保守保留等卷恢复后再判，否则换过下载位置+拔盘再启动会把文件
    // 仍在盘上的下载从索引里清掉（存储恢复后「下载全丢」）。
    final controller = buildController();
    await seedIndex(_song, '${tmpRoot.path}/offline_volume/a.mp3');

    await controller.initialize();

    final entry = controller.entryFor(_song);
    expect(entry?.status, DownloadStatus.downloaded);
    expect(entry?.filePath, '${tmpRoot.path}/offline_volume/a.mp3');
  });

  test('历史目录迁移：文件仍在旧目录 → 搬入当前目录并重写路径', () async {
    final legacyPath = writeFile('${legacyDir.path}/a.mp3').path;
    final controller = buildController();
    await seedIndex(_song, legacyPath);

    await controller.initialize();

    final entry = controller.entryFor(_song);
    expect(entry?.status, DownloadStatus.downloaded);
    expect(entry?.filePath, '${currentDir.path}/a.mp3');
    expect(File('${currentDir.path}/a.mp3').existsSync(), isTrue);
    expect(File(legacyPath).existsSync(), isFalse);
  });

  test('改名错位找回：索引指向 shiyin 名目录、文件留在 ka_music 目录', () async {
    // 索引路径（legacyDir）不存在，同名文件在旧名目录（legacyKaDir）
    final kaPath = writeFile('${legacyKaDir.path}/a.mp3').path;
    final controller = buildController();
    await seedIndex(_song, '${legacyDir.path}/a.mp3');

    await controller.initialize();

    final entry = controller.entryFor(_song);
    expect(entry?.filePath, '${currentDir.path}/a.mp3');
    expect(File(kaPath).existsSync(), isFalse);
    expect(File('${currentDir.path}/a.mp3').existsSync(), isTrue);
  });

  test('当前目录同名采用：索引路径失效但当前目录已有同名文件 → 直接采用', () async {
    writeFile('${currentDir.path}/a.mp3');
    final controller = buildController();
    await seedIndex(_song, '${tmpRoot.path}/elsewhere/a.mp3');

    await controller.initialize();

    final entry = controller.entryFor(_song);
    expect(entry?.status, DownloadStatus.downloaded);
    expect(entry?.filePath, '${currentDir.path}/a.mp3');
  });

  test('同名同大小冲突：索引指向现有文件，历史目录源文件保留', () async {
    writeFile('${currentDir.path}/a.mp3', 'same-len');
    final legacyPath = writeFile('${legacyDir.path}/a.mp3', 'same-len').path;
    final controller = buildController();
    await seedIndex(_song, legacyPath);

    await controller.initialize();

    final entry = controller.entryFor(_song);
    expect(entry?.filePath, '${currentDir.path}/a.mp3');
    // 绝不自动删除用户数据：源文件原地保留
    expect(File(legacyPath).existsSync(), isTrue);
  });

  test('同名不同大小：换 "(2)" 名搬入，两份都在', () async {
    writeFile('${currentDir.path}/a.mp3', 'x');
    final legacyPath = writeFile(
      '${legacyDir.path}/a.mp3',
      'much-longer-content',
    ).path;
    final controller = buildController();
    await seedIndex(_song, legacyPath);

    await controller.initialize();

    final entry = controller.entryFor(_song);
    expect(entry?.filePath, '${currentDir.path}/a (2).mp3');
    expect(File('${currentDir.path}/a.mp3').existsSync(), isTrue);
    expect(File('${currentDir.path}/a (2).mp3').existsSync(), isTrue);
    expect(File(legacyPath).existsSync(), isFalse);
  });

  test('在播文件不搬移：条目与文件保持原位', () async {
    final legacyPath = writeFile('${legacyDir.path}/a.mp3').path;
    final controller = buildController()..playingPathProvider = () => legacyPath;
    await seedIndex(_song, legacyPath);

    await controller.initialize();

    final entry = controller.entryFor(_song);
    expect(entry?.filePath, legacyPath);
    expect(File(legacyPath).existsSync(), isTrue);
  });

  test('下载中条目不受对账影响', () async {
    final service = _FakeDownloadService(
      currentDir: currentDir,
      legacyDirs: const [],
      hangTransfers: true,
    );
    final controller = DownloadController(service, _FakeApi());

    // 地址解析挂起 → 条目停留在 downloading
    final downloadFuture = controller.download(_song, AudioQuality.standard);
    await _drain();

    final removed = await controller.reconcileDownloads();

    expect(removed, 0);
    expect(
      controller.entryFor(_song)?.status,
      DownloadStatus.downloading,
    );
    // 收尾：让挂起的下载完成，避免测试泄漏
    service.completeHang();
    await downloadFuture;
  });

  test('移动端口径：无历史目录时仅做外部删除同步', () async {
    // legacyDirs 为空（对应移动端 legacyDownloadDirs 返回空列表）
    final controller = buildController(withLegacyDirs: false);
    await seedIndex(_song, '${legacyDir.path}/a.mp3');
    // 文件确实存在于旧路径（移动端旧路径原地可用的等价模拟）
    final legacyPath = writeFile('${legacyDir.path}/a.mp3').path;

    await controller.initialize();

    // 无历史目录候选 → 不判定为"历史目录"，条目原样保留
    final entry = controller.entryFor(_song);
    expect(entry?.filePath, legacyPath);
    expect(File(legacyPath).existsSync(), isTrue);
  });

  test('同 hash 重复条目：丢失文件的后条不顶掉好条', () async {
    final goodPath = writeFile('${currentDir.path}/a.mp3').path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'shiyin_downloads_index',
      jsonEncode([
        {
          'song': _song.toCache(),
          'quality': '128',
          'filePath': goodPath,
        },
        // 同 hash 后条：文件已不存在，不得覆盖前条
        {
          'song': _song.toCache(),
          'quality': '320',
          'filePath': '${tmpRoot.path}/gone/a.mp3',
        },
      ]),
    );
    final controller = buildController();

    await controller.initialize();

    expect(controller.entryFor(_song)?.filePath, goodPath);
    expect(controller.downloadedSongs, hasLength(1));
  });

  test('同 hash 重复条目：两条文件都在 → 沿用后条覆盖语义', () async {
    writeFile('${currentDir.path}/a.mp3');
    final laterPath = writeFile('${currentDir.path}/b.mp3').path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'shiyin_downloads_index',
      jsonEncode([
        {
          'song': _song.toCache(),
          'quality': '128',
          'filePath': '${currentDir.path}/a.mp3',
        },
        {
          'song': _song.toCache(),
          'quality': '320',
          'filePath': laterPath,
        },
      ]),
    );
    final controller = buildController();

    await controller.initialize();

    expect(controller.entryFor(_song)?.filePath, laterPath);
  });

  test('索引路径带反斜杠分隔符（Windows 混合分隔）：按文件名在当前目录找回', () async {
    // 跨平台构造"必然不存在"的索引路径：Windows 上 Z: 盘/子目录不存在，
    // Linux 上反斜杠是普通字符同样不存在；文件名提取需先归一分隔符
    writeFile('${currentDir.path}/a.mp3');
    final controller = buildController();
    await seedIndex(_song, r'Z:\nonexistent_shiyin\a.mp3');

    await controller.initialize();

    expect(
      controller.entryFor(_song)?.filePath,
      '${currentDir.path}/a.mp3',
    );
  });

  test('下载根不可用（卷断开/共享盘失联）：不裁剪，条目保留', () async {
    // downloadDir 抛错 → canPrune=false：全表 exists()==false 也不得清空
    final controller = DownloadController(
      _FakeDownloadService(
        currentDir: currentDir,
        legacyDirs: const [],
        failDownloadDir: true,
      ),
      _FakeApi(),
    );
    await seedIndex(_song, '${tmpRoot.path}/gone/a.mp3');

    await controller.initialize();

    final entry = controller.entryFor(_song);
    expect(entry?.status, DownloadStatus.downloaded);
    expect(entry?.filePath, '${tmpRoot.path}/gone/a.mp3');
  });
}

const _song = Song(id: '1', title: '测试歌曲', artist: '测试歌手', hash: 'h1');

Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 真实磁盘目录驱动的服务替身；纯函数委托给真实 [DownloadService]。
class _FakeDownloadService implements DownloadService {
  _FakeDownloadService({
    required this.currentDir,
    required this.legacyDirs,
    this.hangTransfers = false,
    this.failDownloadDir = false,
  });

  final Directory currentDir;
  final List<Directory> legacyDirs;
  final bool hangTransfers;

  /// 模拟下载根解析失败（下载卷未挂载/共享盘断开时 downloadDir 抛错）。
  final bool failDownloadDir;

  final Completer<void> _hangCompleter = Completer<void>();
  final DownloadService _real = DownloadService();

  void completeHang() => _hangCompleter.complete();

  @override
  Future<Directory> downloadDir() async {
    if (failDownloadDir) throw const FileSystemException('volume offline');
    if (!currentDir.existsSync()) currentDir.createSync(recursive: true);
    return currentDir;
  }

  @override
  Future<List<Directory>> legacyDownloadDirs() async => legacyDirs;

  @override
  String resolveNonCollidingPath(String targetPath, String partPath) =>
      _real.resolveNonCollidingPath(targetPath, partPath);

  @override
  Future<int> fileSize(String path) async {
    final file = File(path);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  @override
  Future<void> prunePlayCache(
    List<({String cacheKey, String filePath, DateTime cachedAt})> entries, {
    int? maxBytes,
    Set<String> excludePaths = const {},
  }) async {}

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
    if (hangTransfers) {
      await _hangCompleter.future;
    }
    return '${currentDir.path}/${song.hash}.mp3';
  }

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
  }) async {
    // hangTransfers 场景由 service 层挂起；此处立即返回即可
    return PlayUrl(url: 'http://fake/${song.hash}.mp3', hash: song.hash);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
