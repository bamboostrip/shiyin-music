// 播放状态快照的回归测试：
//   1. 长队列（>200）保存时以当前歌为中心取窗口，重启后仍恢复到同一首；
//   2. 旧格式快照（无 queueBaseIndex/currentSongHash、只存前 200 首）仍能恢复，
//      且不会越界（沿用旧语义退化到窗口内最后一首）；
//   3. 短队列（<=200）行为不变。
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
import 'package:shiyin_music/ui/form_factor.dart';

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

class _FakeAudioHandler extends Fake implements MusicAudioHandler {
  _FakeAudioHandler(this._audioPlayer);

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
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {}
  @override
  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {}
  @override
  Future<void> seek(Duration position, [dynamic options]) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {}

const _playbackStateKey = 'playback_state';

Song _song(int i) => Song(
  id: '$i',
  title: '歌曲$i',
  artist: '歌手',
  hash: 'hash$i',
  duration: const Duration(seconds: 100),
);

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
    debugDesktopFormFactorOverride = false;
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
    debugDesktopFormFactorOverride = null;
  });

  test('250 首队列播到第 250 首：重启后恢复到同一首', () async {
    final first = buildController();
    await settle();
    first.queue = List<Song>.generate(250, _song);
    first.currentSong = first.queue[249];

    await first.flushPlaybackState();
    final prefs = await SharedPreferences.getInstance();
    final state =
        jsonDecode(prefs.getString(_playbackStateKey)!) as Map<String, dynamic>;
    expect((state['queue'] as List).length, lessThanOrEqualTo(200));
    expect(state['queueBaseIndex'], 50, reason: '窗口应围绕第 250 首（0 基 249）');
    expect(state['currentSongHash'], 'hash249');

    controllers.remove(first);
    first.dispose();

    final second = buildController();
    await settle();
    expect(second.currentSong?.hash, 'hash249');
    expect(second.currentIndex, greaterThanOrEqualTo(0));
  });

  test('旧格式快照（只存前 200 首 + 绝对下标）仍可恢复且不越界', () async {
    final legacy = {
      'queue': List<Song>.generate(200, _song).map((s) => s.toCache()).toList(),
      'currentIndex': 249,
      'playbackMode': PlaybackMode.playlistLoop.name,
    };
    SharedPreferences.setMockInitialValues(<String, Object>{
      _playbackStateKey: jsonEncode(legacy),
    });

    final controller = buildController();
    await settle();
    expect(controller.queue.length, 200);
    // 旧语义：绝对下标越界时收敛到最后一首，不抛异常。
    expect(controller.currentIndex, 199);
  });

  test('短队列（<=200）不受窗口逻辑影响', () async {
    final first = buildController();
    await settle();
    first.queue = List<Song>.generate(30, _song);
    first.currentSong = first.queue[10];
    await first.flushPlaybackState();

    final prefs = await SharedPreferences.getInstance();
    final state =
        jsonDecode(prefs.getString(_playbackStateKey)!) as Map<String, dynamic>;
    expect(state['queueBaseIndex'], 0);
    expect((state['queue'] as List).length, 30);

    controllers.remove(first);
    first.dispose();

    final second = buildController();
    await settle();
    expect(second.currentSong?.hash, 'hash10');
  });

  test('洗牌模式 + 长队列：窗口恢复后仍是当前歌且模式保留', () async {
    final first = buildController();
    await settle();
    first.queue = List<Song>.generate(260, _song);
    first.currentSong = first.queue[200];
    first.playbackMode = PlaybackMode.shuffle;
    await first.flushPlaybackState();

    controllers.remove(first);
    first.dispose();

    final second = buildController();
    await settle();
    expect(second.playbackMode, PlaybackMode.shuffle);
    expect(second.currentSong?.hash, 'hash200');
    expect(second.queue.length, lessThanOrEqualTo(200));
  });

  test('当前歌不在队列里（currentIndex=-1）：恢复退化到队列首，不抛异常', () async {
    final first = buildController();
    await settle();
    first.queue = List<Song>.generate(250, _song);
    // 当前歌不在队列中（例如从搜索点歌但队列仍是旧歌单）。
    first.currentSong = Song(
      id: 'outsider',
      title: '队列外',
      artist: 'x',
      hash: 'hash-outsider',
    );
    await first.flushPlaybackState();

    final prefs = await SharedPreferences.getInstance();
    final state =
        jsonDecode(prefs.getString(_playbackStateKey)!) as Map<String, dynamic>;
    expect(state['currentIndex'], -1);

    controllers.remove(first);
    first.dispose();

    final second = buildController();
    await settle();
    // 旧语义：越界/找不到时收敛到队首。
    expect(second.currentSong?.hash, 'hash0');
    expect(second.queue.length, lessThanOrEqualTo(200));
  });
}
