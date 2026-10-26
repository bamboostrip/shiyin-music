// 「搜索 / 听歌识曲点单曲 = 插入当前播放队列并起播」（issue #6-3）的
// PlayerController 契约：
//   1. 非空队列：插到当前曲**之后**并立即起播，原队列顺序完整保留；
//   2. 空队列：退化为普通单曲播放（有回退队列时用回退队列）；
//   3. 歌曲已在队列：按原位置起播，不重排、不重复；
//   4. 点的就是当前在播歌曲：不重新载入（不打断进度）；
//   5. 与「下一首播放」（addToQueue：只插不播）语义区分。
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
  ProcessingState get processingState => ProcessingState.ready;

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

  /// 每次真正进入引擎加载的歌曲 hash（是否重新加载的观测点）。
  final List<String> loadedHashes = [];

  List<Song>? lastQueueSongs;
  int? lastQueueIndex;

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
    lastQueueSongs = List<Song>.of(queueSongs);
    lastQueueIndex = queueIndex;
  }

  @override
  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
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

class _MockMusicApi extends Fake implements MusicApi {
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
}

Song _song(int index) =>
    Song(id: 'song_$index', title: '歌曲$index', artist: '歌手', hash: 'hash_$index');

List<String> _hashes(List<Song> songs) =>
    songs.map((song) => song.hash).toList();

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
  });

  tearDown(() async {
    // 播放态落盘/历史记录等都是一跳微任务，dispose 前先放行，避免
    // 延迟回调通知已销毁对象。
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    controller.dispose();
    fakeAudioPlayer.disposeStreams();
  });

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('非空队列：插入到当前曲之后并立即起播，原队列顺序保留', () async {
    await controller.playSong(
      _song(0),
      queue: [_song(0), _song(1), _song(2)],
    );
    await settle();
    handler.loadedHashes.clear();

    await controller.playSongKeepingQueue(_song(9));
    await settle();

    expect(_hashes(controller.queue), ['hash_0', 'hash_9', 'hash_1', 'hash_2']);
    expect(controller.currentSong?.hash, 'hash_9');
    expect(controller.currentIndex, 1);
    expect(handler.loadedHashes, ['hash_9']);
    expect(_hashes(handler.lastQueueSongs!), _hashes(controller.queue));
    expect(handler.lastQueueIndex, 1);
  });

  test('空队列：退化为单曲播放（队列只有该曲）', () async {
    await controller.playSongKeepingQueue(_song(5));
    await settle();

    expect(_hashes(controller.queue), ['hash_5']);
    expect(controller.currentSong?.hash, 'hash_5');
    expect(controller.currentIndex, 0);
    expect(handler.loadedHashes, ['hash_5']);
  });

  test('空队列 + 回退队列：用回退队列起播（保留搜索/识曲连续试听）', () async {
    await controller.playSongKeepingQueue(
      _song(5),
      fallbackQueue: [_song(5), _song(6)],
    );
    await settle();

    expect(_hashes(controller.queue), ['hash_5', 'hash_6']);
    expect(controller.currentSong?.hash, 'hash_5');
    expect(controller.currentIndex, 0);
  });

  test('歌曲已在队列：按原位置起播，不重排、不产生重复项', () async {
    await controller.playSong(
      _song(0),
      queue: [_song(0), _song(1), _song(2)],
    );
    await settle();
    handler.loadedHashes.clear();

    await controller.playSongKeepingQueue(_song(2));
    await settle();

    expect(_hashes(controller.queue), ['hash_0', 'hash_1', 'hash_2']);
    expect(controller.currentSong?.hash, 'hash_2');
    expect(controller.currentIndex, 2);
    expect(handler.loadedHashes, ['hash_2']);
  });

  test('点的就是当前在播歌曲：不重新载入（不打断进度）', () async {
    await controller.playSong(_song(0), queue: [_song(0), _song(1)]);
    await settle();
    handler.loadedHashes.clear();

    await controller.playSongKeepingQueue(_song(0));
    await settle();

    expect(_hashes(controller.queue), ['hash_0', 'hash_1']);
    expect(controller.currentSong?.hash, 'hash_0');
    expect(handler.loadedHashes, isEmpty);
  });

  test('与「下一首播放」区分：addToQueue 只插不播，当前曲不变', () async {
    await controller.playSong(_song(0), queue: [_song(0), _song(1)]);
    await settle();
    handler.loadedHashes.clear();

    await controller.addToQueue(_song(9));
    await settle();

    expect(_hashes(controller.queue), ['hash_0', 'hash_9', 'hash_1']);
    expect(controller.currentSong?.hash, 'hash_0');
    expect(handler.loadedHashes, isEmpty);
  });
}
