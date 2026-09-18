// 起播确认超时复核回归。
//
// `_requestPlayback` 给 Android `play(Result)` 挂起设了 2s 上限：
// - 超时但引擎已在播（`hangPlayUntilCompleted` 模拟的实机行为）→ 等同成功，
//   必须清失败计数、记历史（老行为，改错会把每次正常起播都算失败）；
// - 超时且引擎静默（会话被抢/未 ready 又不抛错）→ 不得按成功记账，
//   否则失败计数被误清、自动跳过失效，且历史里多一条没出声的歌。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';
import 'package:shiyin_music/services/playback_history_service.dart';

class _Engine {
  bool playing = false;
  ProcessingState state = ProcessingState.idle;
  final stateCtrl = StreamController<PlayerState>.broadcast();
  final processingCtrl = StreamController<ProcessingState>.broadcast();
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration?>.broadcast();
  final errorCtrl = StreamController<PlayerException>.broadcast();

  void emit() {
    processingCtrl.add(state);
    stateCtrl.add(PlayerState(playing, state));
  }

  void setState(ProcessingState s) {
    state = s;
    emit();
  }

  Future<void> dispose() async {
    await stateCtrl.close();
    await processingCtrl.close();
    await positionCtrl.close();
    await durationCtrl.close();
    await errorCtrl.close();
  }
}

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  _FakeAudioPlayer(this.engine);

  final _Engine engine;

  @override
  Stream<Duration> get positionStream => engine.positionCtrl.stream;

  @override
  Stream<Duration?> get durationStream => engine.durationCtrl.stream;

  @override
  Stream<PlayerState> get playerStateStream => engine.stateCtrl.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      engine.processingCtrl.stream;

  @override
  Stream<PlayerException> get errorStream => engine.errorCtrl.stream;

  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Duration get position => Duration.zero;

  @override
  bool get playing => engine.playing;

  @override
  ProcessingState get processingState => engine.state;

  @override
  int? get androidAudioSessionId => null;
}

class _EngineAudioHandler extends Fake implements MusicAudioHandler {
  _EngineAudioHandler(this.engine, this.player);

  final _Engine engine;
  final _FakeAudioPlayer player;

  /// Android 实机行为：`play()` 置 playWhenReady 后 Future 挂到曲末才回执，
  /// 但引擎侧 playing 已为 true。
  bool hangPlayUntilCompleted = false;

  /// 未来风险路径：`play()` 既不回执也不起播（会话被抢/未 ready 又不抛错），
  /// 引擎侧 playing 保持 false。
  bool hangPlaySilent = false;

  final List<Completer<void>> _playBlockers = [];

  @override
  AudioPlayer get audioPlayer => player;

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {}

  @override
  void detachTransportControls() {}

  @override
  Future<void> seek(Duration position, [dynamic options]) async {
    if (engine.state != ProcessingState.ready) {
      engine.setState(ProcessingState.ready);
    }
  }

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    engine.setState(ProcessingState.loading);
    engine.setState(ProcessingState.ready);
  }

  void releaseAllBlocked() {
    for (final blocker in _playBlockers) {
      if (!blocker.isCompleted) blocker.complete();
    }
  }

  @override
  Future<void> play() async {
    if (hangPlaySilent) {
      final blocker = Completer<void>();
      _playBlockers.add(blocker);
      await blocker.future;
      return;
    }
    if (engine.playing) return;
    engine.playing = true;
    engine.emit();
    if (hangPlayUntilCompleted) {
      final blocker = Completer<void>();
      _playBlockers.add(blocker);
      await blocker.future;
    }
  }

  @override
  Future<void> pause() async {
    if (!engine.playing) return;
    engine.playing = false;
    engine.emit();
  }

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
  artist: '歌手$index',
  hash: 'hash_confirm_$index',
  duration: const Duration(seconds: 300),
);

/// 让控制器内部异步链与 `unawaited` 的历史写入跑完。
Future<void> settle([int rounds = 30]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Engine engine;
  late _FakeAudioPlayer player;
  late _EngineAudioHandler handler;
  late PlayerController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    engine = _Engine();
    player = _FakeAudioPlayer(engine);
    handler = _EngineAudioHandler(engine, player);
    controller = PlayerController(_MockMusicApi(), handler);
  });

  tearDown(() async {
    handler.releaseAllBlocked();
    await settle();
    controller.dispose();
    await engine.dispose();
  });

  test('超时但引擎已在播 → 按成功记账（记历史）', () async {
    final song = _song(1);
    handler.hangPlayUntilCompleted = true;
    await controller.playSong(song, queue: [song]);
    await settle();
    await settle();

    final history = await PlaybackHistoryService().getHistory();
    expect(
      history.map((s) => s.hash),
      contains(song.hash),
      reason: 'Android 挂起是已知行为，超时+在播必须等同成功记历史',
    );
    expect(controller.errorMessage, isNull);
  });

  test('超时且引擎静默 → 不按成功记账（不记历史、不落错误）', () async {
    final song = _song(2);
    handler.hangPlaySilent = true;
    await controller.playSong(song, queue: [song]);
    await settle();
    await settle();

    final history = await PlaybackHistoryService().getHistory();
    expect(
      history.map((s) => s.hash),
      isNot(contains(song.hash)),
      reason: '没出声的歌不得进播放历史；同分支也不清失败计数',
    );
    // 不是失败，只是“未确认”：不落错误态，等后续真实错误接管。
    expect(controller.errorMessage, isNull);
    expect(controller.currentSong?.hash, song.hash);
  });
}
