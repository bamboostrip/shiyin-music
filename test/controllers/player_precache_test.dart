import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

class _FakeDownloadService implements DownloadService {
  @override
  String cacheKeyFor(Song song, AudioQuality quality) {
    return '${song.hash}_${quality.apiValue}';
  }

  @override
  Future<int> fileSize(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      return file.lengthSync();
    }
    return 0;
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

class _FakeApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();
  final _androidAudioSessionIdController = StreamController<int?>.broadcast();

  final Duration _position = Duration.zero;
  final bool _playing = false;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      _processingStateController.stream;

  @override
  Stream<int?> get androidAudioSessionIdStream =>
      _androidAudioSessionIdController.stream;

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Duration get position => _position;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => ProcessingState.idle;

  @override
  int? get androidAudioSessionId => null;

  void disposeStreams() {
    _positionController.close();
    _durationController.close();
    _playerStateController.close();
    _processingStateController.close();
    _androidAudioSessionIdController.close();
  }
}

class _FakeMusicAudioHandler extends Fake implements MusicAudioHandler {
  _FakeMusicAudioHandler(this._audioPlayer);

  final AudioPlayer _audioPlayer;

  @override
  AudioPlayer get audioPlayer => _audioPlayer;

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {}

  @override
  void detachTransportControls() {}

  @override
  Future<void> seek(Duration position, [dynamic options]) async {}

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

class _TestMusicApi extends Fake implements MusicApi {
  int songUrlCallCount = 0;
  int lyricsCallCount = 0;
  final List<Song> songUrlRequestedSongs = [];
  final List<Song> lyricsRequestedSongs = [];

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    songUrlCallCount++;
    songUrlRequestedSongs.add(song);
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async {
    lyricsCallCount++;
    lyricsRequestedSongs.add(song);
    return const [LyricLine(text: 'test lyrics', time: Duration.zero)];
  }
}

class _SpyDownloadController extends DownloadController {
  _SpyDownloadController(super.service, super.api);

  final List<Song> cachedSongs = [];
  final Map<String, String> localFiles = {};

  @override
  String? localPathFor(Song song, AudioQuality quality) {
    return localFiles[song.hash];
  }

  @override
  Future<void> cacheForPlayback(
    Song song,
    AudioQuality quality,
    String url,
  ) async {
    cachedSongs.add(song);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeDownloadService fakeService;
  late _FakeApi fakeApi;

  const testSong = Song(
    id: 'song_1',
    title: 'Test Song',
    artist: 'Test Artist',
    hash: 'hash_123',
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('precache_test_');
    fakeService = _FakeDownloadService();
    fakeApi = _FakeApi();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('DownloadController.localPathForAnyQuality', () {
    test('when exact preferred quality matches, returns that path', () async {
      final downloadedFile = File('${tempDir.path}/exact_download.mp3')
        ..writeAsStringSync('audio-data-download');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ka_music_downloads_index',
        jsonEncode([
          {
            'song': testSong.toCache(),
            'quality': AudioQuality.standard.apiValue,
            'filePath': downloadedFile.path,
            'downloadedAt': DateTime.now().toIso8601String(),
          }
        ]),
      );

      final controller = DownloadController(fakeService, fakeApi);
      await controller.initialize();

      final result = controller.localPathForAnyQuality(
        testSong,
        preferredQuality: AudioQuality.standard,
      );

      expect(result, downloadedFile.path);
    });

    test(
      'when preferred quality does NOT match, but there is a downloaded file with different quality, returns downloaded path',
      () async {
        final downloadedFile = File('${tempDir.path}/standard_download.mp3')
          ..writeAsStringSync('audio-data-standard');

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'ka_music_downloads_index',
          jsonEncode([
            {
              'song': testSong.toCache(),
              'quality': AudioQuality.standard.apiValue,
              'filePath': downloadedFile.path,
              'downloadedAt': DateTime.now().toIso8601String(),
            }
          ]),
        );

        final controller = DownloadController(fakeService, fakeApi);
        await controller.initialize();

        // 请求 lossless，但本地只有 standard
        final result = controller.localPathForAnyQuality(
          testSong,
          preferredQuality: AudioQuality.lossless,
        );

        expect(result, downloadedFile.path);
      },
    );

    test(
      'when preferred quality does NOT match, but there is a play cache entry with different quality, returns play cache path',
      () async {
        final cachedFile = File('${tempDir.path}/cached_standard.mp3')
          ..writeAsStringSync('audio-data-cache');

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'ka_music_play_cache_index',
          jsonEncode([
            {
              'cacheKey': fakeService.cacheKeyFor(testSong, AudioQuality.standard),
              'song': testSong.toCache(),
              'quality': AudioQuality.standard.apiValue,
              'filePath': cachedFile.path,
              'cachedAt': DateTime.now().toIso8601String(),
            }
          ]),
        );

        final controller = DownloadController(fakeService, fakeApi);
        await controller.initialize();

        // 请求 high，但本地播放缓存只有 standard
        final result = controller.localPathForAnyQuality(
          testSong,
          preferredQuality: AudioQuality.high,
        );

        expect(result, cachedFile.path);
      },
    );

    test(
      'when exact preferred quality matches in play cache (no download), returns play cache path',
      () async {
        final cachedFile = File('${tempDir.path}/cached_high.mp3')
          ..writeAsStringSync('audio-data-high');

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'ka_music_play_cache_index',
          jsonEncode([
            {
              'cacheKey': fakeService.cacheKeyFor(testSong, AudioQuality.high),
              'song': testSong.toCache(),
              'quality': AudioQuality.high.apiValue,
              'filePath': cachedFile.path,
              'cachedAt': DateTime.now().toIso8601String(),
            }
          ]),
        );

        final controller = DownloadController(fakeService, fakeApi);
        await controller.initialize();

        final result = controller.localPathForAnyQuality(
          testSong,
          preferredQuality: AudioQuality.high,
        );

        expect(result, cachedFile.path);
      },
    );

    test(
      'when preferred quality does not match and both download and cache exist with other qualities, download takes precedence',
      () async {
        final downloadedFile = File('${tempDir.path}/standard_download.mp3')
          ..writeAsStringSync('download-data');
        final cachedFile = File('${tempDir.path}/super_cache.mp3')
          ..writeAsStringSync('cache-data');

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'ka_music_downloads_index',
          jsonEncode([
            {
              'song': testSong.toCache(),
              'quality': AudioQuality.standard.apiValue,
              'filePath': downloadedFile.path,
              'downloadedAt': DateTime.now().toIso8601String(),
            }
          ]),
        );
        await prefs.setString(
          'ka_music_play_cache_index',
          jsonEncode([
            {
              'cacheKey': fakeService.cacheKeyFor(testSong, AudioQuality.high),
              'song': testSong.toCache(),
              'quality': AudioQuality.high.apiValue,
              'filePath': cachedFile.path,
              'cachedAt': DateTime.now().toIso8601String(),
            }
          ]),
        );

        final controller = DownloadController(fakeService, fakeApi);
        await controller.initialize();

        // preferred is lossless, downloads is standard, cache is high -> should return download
        final result = controller.localPathForAnyQuality(
          testSong,
          preferredQuality: AudioQuality.lossless,
        );

        expect(result, downloadedFile.path);
      },
    );

    test(
      'when preferredQuality is omitted/null, returns available download or cache path',
      () async {
        final cachedFile = File('${tempDir.path}/cached_any.mp3')
          ..writeAsStringSync('audio-data-any');

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'ka_music_play_cache_index',
          jsonEncode([
            {
              'cacheKey': fakeService.cacheKeyFor(testSong, AudioQuality.standard),
              'song': testSong.toCache(),
              'quality': AudioQuality.standard.apiValue,
              'filePath': cachedFile.path,
              'cachedAt': DateTime.now().toIso8601String(),
            }
          ]),
        );

        final controller = DownloadController(fakeService, fakeApi);
        await controller.initialize();

        final result = controller.localPathForAnyQuality(testSong);

        expect(result, cachedFile.path);
      },
    );

    test('when no file exists on disk, returns null', () async {
      final nonExistentFile = File('${tempDir.path}/removed.mp3');
      // 创建后删除，模拟文件被外部删除或失效
      nonExistentFile.writeAsStringSync('will-be-deleted');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ka_music_downloads_index',
        jsonEncode([
          {
            'song': testSong.toCache(),
            'quality': AudioQuality.standard.apiValue,
            'filePath': nonExistentFile.path,
            'downloadedAt': DateTime.now().toIso8601String(),
          }
        ]),
      );

      final controller = DownloadController(fakeService, fakeApi);
      await controller.initialize();

      // 删除磁盘物理文件
      if (nonExistentFile.existsSync()) {
        nonExistentFile.deleteSync();
      }

      final result = controller.localPathForAnyQuality(
        testSong,
        preferredQuality: AudioQuality.standard,
      );

      expect(result, isNull);
    });

    test('when song has no downloaded or cached entries, returns null', () async {
      final controller = DownloadController(fakeService, fakeApi);
      await controller.initialize();

      final result = controller.localPathForAnyQuality(
        testSong,
        preferredQuality: AudioQuality.standard,
      );

      expect(result, isNull);
    });
  });

  group('PlayerController 智能预缓存流水线 (Player Precache)', () {
    late _FakeAudioPlayer fakePlayer;
    late _FakeMusicAudioHandler fakeAudioHandler;
    late _TestMusicApi testApi;
    late _SpyDownloadController spyDownloadController;
    late PlayerController player;

    const song1 = Song(
      id: 's1',
      title: 'Song 1',
      artist: 'Artist 1',
      hash: 'hash_1',
    );
    const song2 = Song(
      id: 's2',
      title: 'Song 2',
      artist: 'Artist 2',
      hash: 'hash_2',
    );
    const song3 = Song(
      id: 's3',
      title: 'Song 3',
      artist: 'Artist 3',
      hash: 'hash_3',
    );
    const localSong = Song(
      id: '/local/path/song.mp3',
      title: 'Local Song',
      artist: 'Local Artist',
      hash: 'hash_local',
      source: SongSource.local,
    );

    setUp(() async {
      fakePlayer = _FakeAudioPlayer();
      fakeAudioHandler = _FakeMusicAudioHandler(fakePlayer);
      testApi = _TestMusicApi();
      spyDownloadController = _SpyDownloadController(fakeService, testApi);
      player = PlayerController(testApi, fakeAudioHandler);
      player.downloadController = spyDownloadController;
    });

    tearDown(() {
      player.dispose();
      fakePlayer.disposeStreams();
    });

    Future<void> startPlayback(
      Song song, {
      List<Song>? queue,
      Duration? duration,
    }) async {
      await player.playSong(song, queue: queue);
      await pumpEventQueue();
      player.duration = duration ?? const Duration(seconds: 100);
      spyDownloadController.cachedSongs.clear();
      testApi.songUrlCallCount = 0;
      testApi.lyricsCallCount = 0;
      testApi.songUrlRequestedSongs.clear();
      testApi.lyricsRequestedSongs.clear();
    }

    group('Test 1: _maybePrecacheNext 触发条件与防抖', () {
      test('position < 15s 不触发预缓存', () async {
        await startPlayback(song1, queue: [song1, song2]);

        player.maybePrecacheNext(const Duration(seconds: 10));
        await pumpEventQueue();

        expect(player.precachedForSongHash, isNull);
        expect(spyDownloadController.cachedSongs, isEmpty);
      });

      test('progress < 70% 且 remain > 25s 不触发预缓存', () async {
        await startPlayback(song1, queue: [song1, song2]);

        player.maybePrecacheNext(const Duration(seconds: 50));
        await pumpEventQueue();

        expect(player.precachedForSongHash, isNull);
        expect(spyDownloadController.cachedSongs, isEmpty);
      });

      test('position >= 15s 且 progress >= 70% 触发预缓存', () async {
        await startPlayback(song1, queue: [song1, song2]);

        player.maybePrecacheNext(const Duration(seconds: 70));
        await pumpEventQueue();

        expect(player.precachedForSongHash, song1.hash);
        expect(spyDownloadController.cachedSongs, contains(song2));
      });

      test('position >= 15s 且 remain <= 25s 触发预缓存（短音频或剩余时间触发）', () async {
        await startPlayback(
          song1,
          queue: [song1, song2],
          duration: const Duration(seconds: 30),
        );

        player.maybePrecacheNext(const Duration(seconds: 16));
        await pumpEventQueue();

        expect(player.precachedForSongHash, song1.hash);
        expect(spyDownloadController.cachedSongs, contains(song2));
      });

      test('同一首歌只触发一次预缓存（防抖守卫，防止每 tick 重复触发）', () async {
        await startPlayback(song1, queue: [song1, song2]);

        player.maybePrecacheNext(const Duration(seconds: 70));
        await pumpEventQueue();
        expect(spyDownloadController.cachedSongs.length, 1);

        player.maybePrecacheNext(const Duration(seconds: 71));
        player.maybePrecacheNext(const Duration(seconds: 72));
        player.maybePrecacheNext(const Duration(seconds: 75));
        await pumpEventQueue();

        expect(spyDownloadController.cachedSongs.length, 1);
        expect(testApi.songUrlCallCount, 1);
      });

      test('切歌后重置预缓存守卫，新歌播放达到阈值可再次触发预缓存', () async {
        await startPlayback(song1, queue: [song1, song2, song3]);

        player.maybePrecacheNext(const Duration(seconds: 75));
        await pumpEventQueue();
        expect(player.precachedForSongHash, song1.hash);
        expect(spyDownloadController.cachedSongs, [song2]);

        await startPlayback(song2, queue: [song1, song2, song3]);
        expect(player.precachedForSongHash, isNull);

        player.maybePrecacheNext(const Duration(seconds: 80));
        await pumpEventQueue();

        expect(player.precachedForSongHash, song2.hash);
        expect(spyDownloadController.cachedSongs, [song3]);
      });

      test('通过 positionStream 进度流自动驱动 maybePrecacheNext', () async {
        await startPlayback(song1, queue: [song1, song2]);

        fakePlayer._positionController.add(const Duration(seconds: 75));
        await pumpEventQueue();

        expect(player.precachedForSongHash, song1.hash);
        expect(spyDownloadController.cachedSongs, contains(song2));
      });
    });

    group('Test 2: PlaybackMode.shuffle 随机播放模式感知', () {
      test('随机播放模式下，预缓存对象严格为 _shuffleQueue 中的下一首', () async {
        player.playbackMode = PlaybackMode.shuffle;
        final queue = [song1, song2, song3];
        await startPlayback(song1, queue: queue);

        final expectedNext = player.nextSong(peek: true);
        expect(expectedNext, isNotNull);
        expect(expectedNext!.hash, isNot(equals(song1.hash)));

        player.maybePrecacheNext(const Duration(seconds: 75));
        await pumpEventQueue();

        expect(player.precachedForSongHash, song1.hash);
        expect(spyDownloadController.cachedSongs, [expectedNext]);

        // 预缓存后游标未被意外推进：此时调用 nextSong() 与预缓存的一致
        final actualNext = player.nextSong();
        expect(actualNext?.hash, expectedNext.hash);
      });
    });

    group('Test 3: 本地缓存与本地音源跳过网络解析并确保歌词预取', () {
      test('下一首已有本地文件时，跳过网络解析与音频下载，但预拉取歌词', () async {
        spyDownloadController.localFiles[song2.hash] =
            '${tempDir.path}/cached_song2.mp3';

        await startPlayback(song1, queue: [song1, song2]);

        player.maybePrecacheNext(const Duration(seconds: 75));
        await pumpEventQueue();

        expect(testApi.lyricsCallCount, 1);
        expect(testApi.lyricsRequestedSongs, contains(song2));
        expect(testApi.songUrlCallCount, 0);
        expect(spyDownloadController.cachedSongs, isEmpty);
      });

      test('下一首为本地歌曲 (SongSource.local) 时，跳过网络解析与音频下载', () async {
        await startPlayback(song1, queue: [song1, localSong]);

        player.maybePrecacheNext(const Duration(seconds: 75));
        await pumpEventQueue();

        // 本地歌曲无需网络 API 解析与下载
        expect(testApi.lyricsCallCount, 0);
        expect(testApi.songUrlCallCount, 0);
        expect(spyDownloadController.cachedSongs, isEmpty);
      });

      test('下一首为网络歌曲且无本地缓存时，拉取歌词并解析网络 URL 提交下载', () async {
        await startPlayback(song1, queue: [song1, song2]);

        player.maybePrecacheNext(const Duration(seconds: 75));
        await pumpEventQueue();

        expect(testApi.lyricsCallCount, 1);
        expect(testApi.lyricsRequestedSongs, contains(song2));
        expect(testApi.songUrlCallCount, 1);
        expect(testApi.songUrlRequestedSongs, contains(song2));
        expect(spyDownloadController.cachedSongs, [song2]);
      });
    });
  });
}
