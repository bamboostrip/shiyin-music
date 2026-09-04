import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/desktop_system_integration.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 下载完成通知（桌面）：
/// - 单曲下载 → 每首成功一条"下载完成 + 歌名"；
/// - 批量下载 → 整个任务结束只弹一条（成功/失败计数），不逐曲刷屏。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('单曲下载通知', () {
    test('成功后通知一次，标题"下载完成"+歌名', () async {
      final notifier = _FakeDownloadNotifier();
      final controller = DownloadController(_FakeDownloadService(), _FakeApi());
      controller.desktopNotifier = notifier;

      await controller.download(_song, AudioQuality.standard);
      await _pumpUntil(() => notifier.calls.isNotEmpty);

      expect(notifier.calls, hasLength(1));
      expect(notifier.calls.single.title, '下载完成');
      expect(notifier.calls.single.body, '测试歌曲 - 测试歌手');
      expect(controller.isDownloaded(_song), isTrue);
    });

    test('单曲失败不弹通知', () async {
      final notifier = _FakeDownloadNotifier();
      final api = _FakeApi()..failSongUrl = true;
      final controller = DownloadController(_FakeDownloadService(), api);
      controller.desktopNotifier = notifier;

      await controller.download(_song, AudioQuality.standard);
      await _drain();

      expect(notifier.calls, isEmpty);
      expect(
        controller.entryFor(_song)?.status,
        DownloadStatus.failed,
      );
    });

    test('未注入 notifier（移动端）时全程不弹', () async {
      final controller = DownloadController(_FakeDownloadService(), _FakeApi());
      await controller.download(_song, AudioQuality.standard);
      await _drain();
      expect(controller.isDownloaded(_song), isTrue);
      // 无 notifier 时无任何通知路径（desktopNotifier 为 null 零开销跳过）。
    });
  });

  group('批量下载通知（整个任务一条）', () {
    test('3 首全部成功：仅一条批量通知', () async {
      final notifier = _FakeDownloadNotifier();
      final service = _FakeDownloadService();
      final controller = DownloadController(service, _FakeApi());
      controller.desktopNotifier = notifier;

      final songs = [
        _song,
        _song2,
        const Song(id: '3', title: '第三首', artist: '甲', hash: 'h3'),
      ];
      await controller.enqueueBatch(songs, AudioQuality.standard);
      // 批量传输是 unawaited 的：等所有文件落盘 + 通知到达。
      await _pumpUntil(() => service.transfers.length == 3);
      await _pumpUntil(() => notifier.calls.isNotEmpty);
      await _drain();

      expect(service.transfers, hasLength(3));
      expect(notifier.calls, hasLength(1));
      expect(notifier.calls.single.title, '下载完成');
      expect(notifier.calls.single.body, '已成功下载 3 首歌曲');
    });

    test('部分失败（含地址解析失败）：一条通知合并计数', () async {
      final notifier = _FakeDownloadNotifier();
      final service = _FakeDownloadService();
      final api = _FakeApi()..failHashes = {'h2'};
      final controller = DownloadController(service, api);
      controller.desktopNotifier = notifier;

      final songs = [_song, _song2];
      await controller.enqueueBatch(songs, AudioQuality.standard);
      await _pumpUntil(() => notifier.calls.isNotEmpty);
      await _drain();

      expect(service.transfers, hasLength(1)); // 只有第一首真正传输
      expect(notifier.calls, hasLength(1));
      expect(notifier.calls.single.body, '成功下载 1 首，失败 1 首');
    });

    test('全部被跳过（已下载）时不通知', () async {
      final notifier = _FakeDownloadNotifier();
      final service = _FakeDownloadService();
      final controller = DownloadController(service, _FakeApi());
      controller.desktopNotifier = notifier;

      // 先下载第一首建立"已下载"状态。
      await controller.download(_song, AudioQuality.standard);
      await _pumpUntil(() => notifier.calls.isNotEmpty);
      notifier.calls.clear();

      final result = await controller.enqueueBatch(
        [_song],
        AudioQuality.standard,
      );
      await _drain();

      expect(result.skipped, 1);
      expect(notifier.calls, isEmpty);
    });
  });
}

const _song = Song(id: '1', title: '测试歌曲', artist: '测试歌手', hash: 'h1');
const _song2 = Song(id: '2', title: '第二首', artist: '乙', hash: 'h2');

/// 反复泵事件循环直到 [condition] 满足（批量传输为 unawaited）。
Future<void> _pumpUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待通知/传输完成的超时');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeDownloadNotifier implements DesktopDownloadNotifier {
  final List<({String title, String body})> calls = [];

  @override
  void notifyDownloadCompleted({required String title, required String body}) {
    calls.add((title: title, body: body));
  }
}

class _FakeDownloadService implements DownloadService {
  final List<Song> transfers = [];

  @override
  Future<String> download({
    required Song song,
    required AudioQuality quality,
    required String url,
    required void Function(int received, int total) onProgress,
  }) async {
    transfers.add(song);
    return 'C:/fake/${song.hash}.mp3';
  }

  @override
  Future<int> fileSize(String path) async => 1024;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeApi implements MusicApi {
  bool failSongUrl = false;
  Set<String> failHashes = {};

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    if (failSongUrl || failHashes.contains(song.hash)) {
      throw Exception('no url');
    }
    return PlayUrl(url: 'http://fake/${song.hash}.mp3', hash: song.hash);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
