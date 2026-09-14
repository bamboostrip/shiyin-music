// 连续播放失败自动前进：坏源/断网时播放器不得永久卡在同一首的错误态。
// 覆盖阈值前不跳、达阈值跳下一首、单曲队列不跳、跳过次数有上限（不扫光队列）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();
  final _errorController = StreamController<PlayerException>.broadcast();
  final _androidAudioSessionIdController = StreamController<int?>.broadcast();

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
  Duration get position => Duration.zero;

  @override
  bool get playing => false;

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
    _errorController.close();
  }
}

class _RecordingAudioHandler extends Fake implements MusicAudioHandler {
  _RecordingAudioHandler(this._audioPlayer);

  final AudioPlayer _audioPlayer;

  /// 每次真正进入引擎加载的歌曲 hash（自动前进的观测点）。
  final List<String> loadedHashes = [];

  /// 非 null 时 loadSong 抛出该错误，模拟坏源。
  Object? loadError;

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
  }) async {
    loadedHashes.add(song.hash);
    final error = loadError;
    if (error != null) throw error;
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {
  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

Song _song(int index) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手',
  hash: 'hash_$index',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAudioPlayer fakeAudioPlayer;
  late _RecordingAudioHandler handler;
  late _MockMusicApi api;
  late PlayerController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeAudioPlayer = _FakeAudioPlayer();
    handler = _RecordingAudioHandler(fakeAudioPlayer);
    api = _MockMusicApi();
    controller = PlayerController(api, handler);
    handler.loadError = Exception('bad source');
  });

  tearDown(() async {
    // 自动前进是脱离调用栈的级联（下一首失败还会继续跳）：dispose 前先让
    // 有界级联（上限 min(队列长度, 5) 次）跑完，避免延迟回调通知已销毁对象。
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    controller.dispose();
    fakeAudioPlayer.disposeStreams();
  });

  /// 以 isRetry=true 直接触发"最终失败"路径（跳过 2s 的自动重试等待）。
  Future<void> failOnce(Song song) =>
      controller.playSong(song, queue: controller.queue, isRetry: true);

  /// 让自动前进（Future.delayed(Duration.zero) → next()）跑完。
  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('阈值前不跳：连续两次失败仍停在同一首', () async {
    final songs = [_song(1), _song(2), _song(3)];
    controller.queue = songs;
    controller.currentSong = songs[0];

    await failOnce(songs[0]);
    await failOnce(songs[0]);
    await settle();

    expect(controller.currentSong?.hash, songs[0].hash);
    // 只尝试过第一首（每次 playSong 一次 loadSong）。
    expect(handler.loadedHashes.every((h) => h == songs[0].hash), isTrue);
  });

  test('达阈值自动跳到下一首（不再卡在错误态）', () async {
    final songs = [_song(1), _song(2), _song(3)];
    controller.queue = songs;
    controller.currentSong = songs[0];

    await failOnce(songs[0]);
    await failOnce(songs[0]);
    await failOnce(songs[0]);
    await settle();

    // 阈值前只尝试过第一首。
    expect(
      handler.loadedHashes.take(3).every((h) => h == songs[0].hash),
      isTrue,
      reason: '前两次失败不应跳转',
    );
    // 达阈值后跳到第二首（此后第二/三首也失败，级联会继续，属预期）。
    expect(
      handler.loadedHashes,
      contains(songs[1].hash),
      reason: '连续失败达阈值后应尝试下一首',
    );
    expect(handler.loadedHashes, contains(songs[2].hash));
  });

  test('单曲队列不跳（无处可去，保持错误态）', () async {
    final songs = [_song(1)];
    controller.queue = songs;
    controller.currentSong = songs[0];

    for (var i = 0; i < 6; i++) {
      await failOnce(songs[0]);
      await settle();
    }

    expect(controller.currentSong?.hash, songs[0].hash);
    expect(controller.errorMessage, isNotNull);
  });

  test('跳过次数有上限：持续失败不会无限扫队列', () async {
    // 两首队列：上限 = min(2, 5) = 2 次跳过，之后停下报错。
    final songs = [_song(1), _song(2)];
    controller.queue = songs;
    controller.currentSong = songs[0];

    var changes = 0;
    String? last = controller.currentSong?.hash;
    controller.addListener(() {
      final current = controller.currentSong?.hash;
      if (current != last) {
        changes++;
        last = current;
      }
    });

    // 触发首次跳过（3 次最终失败），随后让级联跑完。
    await failOnce(songs[0]);
    await failOnce(songs[0]);
    await failOnce(songs[0]);
    await settle();
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await settle();
    }

    expect(changes, lessThanOrEqualTo(2));
    expect(controller.errorMessage, isNotNull);
  });
}
