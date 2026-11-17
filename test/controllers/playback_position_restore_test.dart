// 播放进度持久化（全局单点：最后在播那首 + 位置）的回归测试。
//
// 移植上游 3.3.0 `c113193` + `165eb46` 的语义：
//   1. 恢复进度必须与歌曲 hash 匹配，不能串到别的歌；
//   2. 尾 3 秒内不恢复（否则一开播就撞曲末跳歌）；
//   3. 归属守卫：音源没换成当前歌时不写、读到 0ms 不写（不覆盖真实进度）；
//   4. resumePlayback 只在第一首带进度，失败换下一首不带。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

const _positionKey = 'playback.current_position';

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();
  final _errorController = StreamController<PlayerException>.broadcast();
  final _androidAudioSessionIdController =
      StreamController<int?>.broadcast();

  bool playing = false;
  Duration currentPosition = Duration.zero;

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
  Stream<PlayerException> get errorStream => _errorController.stream;

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Duration get position => currentPosition;

  @override
  Duration? get duration => const Duration(seconds: 200);

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  int? get androidAudioSessionId => null;

  void emitPlaying(bool value) {
    playing = value;
    _playerStateController.add(PlayerState(value, ProcessingState.ready));
  }

  void disposeStreams() {
    _positionController.close();
    _durationController.close();
    _playerStateController.close();
    _processingStateController.close();
    _errorController.close();
    _androidAudioSessionIdController.close();
  }
}

class _FakeAudioHandler extends Fake implements MusicAudioHandler {
  _FakeAudioHandler(this._audioPlayer);

  final _FakeAudioPlayer _audioPlayer;

  /// 记录引擎收到的 seek：验证「恢复进度真的进了引擎」而不是只改了 UI。
  final List<Duration> seeks = [];
  int playCalls = 0;

  @override
  AudioPlayer get audioPlayer => _audioPlayer;

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
    void Function()? onPlay,
    void Function()? onPause,
  }) {}

  @override
  void detachTransportControls() {}

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {}

  @override
  Future<void> play({bool userInitiated = true}) async {
    playCalls++;
    _audioPlayer.emitPlaying(true);
  }

  @override
  Future<void> pause({bool userInitiated = true}) async {
    _audioPlayer.emitPlaying(false);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position, [dynamic options]) async {
    seeks.add(position);
    _audioPlayer.currentPosition = position;
  }

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {
  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async =>
      PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

Song _song(int i, {Duration duration = const Duration(seconds: 200)}) => Song(
  id: '$i',
  title: '歌曲$i',
  artist: '歌手',
  hash: 'hash$i',
  duration: duration,
);

/// 造一份「上次退出时正在放 song 1」的磁盘状态。
void seedSnapshot(Song song) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'playback_state': jsonEncode({
      'queue': [song.toCache()],
      'currentIndex': 0,
      'currentSongHash': song.hash,
      'playbackMode': PlaybackMode.playlistLoop.name,
    }),
    _positionKey: jsonEncode({'hash': song.hash, 'ms': 90000}),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAudioPlayer fakeAudioPlayer;
  late _FakeAudioHandler handler;
  late List<PlayerController> controllers;

  PlayerController buildController() {
    final controller = PlayerController(_MockMusicApi(), handler);
    controllers.add(controller);
    return controller;
  }

  Future<void> settle() async {
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fakeAudioPlayer = _FakeAudioPlayer();
    handler = _FakeAudioHandler(fakeAudioPlayer);
    controllers = <PlayerController>[];
  });

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
    fakeAudioPlayer.disposeStreams();
    debugDefaultTargetPlatformOverride = null;
  });

  group('parseSavedPosition（格式与归属）', () {
    test('hash 匹配才采用；不匹配返回 null', () {
      expect(
        parseSavedPosition('{"hash":"h1","ms":90000}', 'h1'),
        const Duration(seconds: 90),
      );
      expect(parseSavedPosition('{"hash":"h1","ms":90000}', 'h2'), isNull);
    });

    test('兼容旧的裸毫秒格式', () {
      expect(parseSavedPosition(90000, 'h1'), const Duration(seconds: 90));
      expect(parseSavedPosition(0, 'h1'), isNull);
    });

    test('坏数据一律返回 null 而不是抛异常', () {
      expect(parseSavedPosition('not-json', 'h1'), isNull);
      expect(parseSavedPosition('{"hash":"h1"}', 'h1'), isNull);
      expect(parseSavedPosition('{"hash":"h1","ms":-1}', 'h1'), isNull);
      expect(parseSavedPosition(null, 'h1'), isNull);
    });
  });

  group('启动恢复', () {
    test('同一首歌：恢复到上次位置，并留下待应用标记', () async {
      final song = _song(1);
      seedSnapshot(song);
      final controller = buildController();
      await settle();

      expect(controller.currentSong?.hash, song.hash);
      expect(controller.position, const Duration(seconds: 90));
      expect(controller.hasPendingResumePosition, isTrue);
    });

    test('位置属于另一首歌：不恢复', () async {
      final song = _song(1);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'playback_state': jsonEncode({
          'queue': [song.toCache()],
          'currentIndex': 0,
          'currentSongHash': song.hash,
          'playbackMode': PlaybackMode.playlistLoop.name,
        }),
        _positionKey: jsonEncode({'hash': 'other', 'ms': 90000}),
      });
      final controller = buildController();
      await settle();

      expect(controller.position, Duration.zero);
      expect(controller.hasPendingResumePosition, isFalse);
    });

    test('剩不足 3 秒就播完的位置不恢复（避免一进来就跳下一首）', () async {
      final song = _song(1, duration: const Duration(seconds: 100));
      SharedPreferences.setMockInitialValues(<String, Object>{
        'playback_state': jsonEncode({
          'queue': [song.toCache()],
          'currentIndex': 0,
          'currentSongHash': song.hash,
          'playbackMode': PlaybackMode.playlistLoop.name,
        }),
        _positionKey: jsonEncode({'hash': song.hash, 'ms': 98500}),
      });
      final controller = buildController();
      await settle();

      expect(controller.position, Duration.zero);
      expect(controller.hasPendingResumePosition, isFalse);
    });

    test('resumePlayback 把进度作为 initialPosition 送进引擎，且只用一次', () async {
      final song = _song(1);
      seedSnapshot(song);
      final controller = buildController();
      await settle();

      await controller.resumePlayback();
      await settle();

      expect(
        handler.seeks,
        contains(const Duration(seconds: 90)),
        reason: '恢复进度必须经过引擎 seek，而不是只把 UI 进度条画到 90s',
      );
      expect(controller.isPlaying, isTrue);
      expect(controller.hasPendingResumePosition, isFalse);
    });
  });

  group('进度保存', () {
    test('播放中落盘：写入 {hash, ms}', () async {
      final song = _song(1);
      seedSnapshot(song);
      final controller = buildController();
      await settle();

      controller.queue = [song];
      fakeAudioPlayer.currentPosition = const Duration(seconds: 42);
      await controller.playSong(song);
      await settle();

      await controller.flushPlaybackState();
      await settle();

      final prefs = await SharedPreferences.getInstance();
      final record =
          jsonDecode(prefs.getString(_positionKey)!) as Map<String, dynamic>;
      expect(record['hash'], song.hash);
      expect(record['ms'], const Duration(seconds: 42).inMilliseconds);
    });

    test('还没起播过（音源不属于当前歌）时绝不用 0 覆盖已有记录', () async {
      final song = _song(1);
      seedSnapshot(song); // 磁盘上已有 90s
      final controller = buildController();
      await settle();

      // 没播过：owner 为 null，即便退出钩子触发也不该写 0。
      await controller.flushPlaybackState();
      await settle();

      final prefs = await SharedPreferences.getInstance();
      final record =
          jsonDecode(prefs.getString(_positionKey)!) as Map<String, dynamic>;
      expect(record['ms'], 90000, reason: '原记录必须原样保留');
    });
  });
}
