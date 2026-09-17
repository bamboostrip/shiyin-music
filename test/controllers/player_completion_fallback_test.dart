// 移动端曲末自动切歌回归。
//
// 3.0.3 起 `isPlaying` 在 completed 收敛为 false（为修 PC 端陈旧 playing 引入）。
// 曲末兜底 timer 若仍以 isPlaying 判活，就会在「引擎已到曲尾、主推进被
// completed 分支守卫挡掉」时失效，队列永久停在当前曲（进度停在曲尾）——
// 3.0.2 靠的是陈旧却仍为 true 的 playing，所以同一条队列在老版本上能推进。
//
// 另覆盖：同曲重播（曲末点播放，3.0.3 起不再走 playSong）后完成去重标记残留，
// 导致这首歌第二次播完时 completed 被静默吞掉、不再前进。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

/// 忠实现 just_audio 的 Dart 侧状态机（Android 原生实现从不回写 playing）：
/// - play() 首行 `if (playing) return;`
/// - pause() 首行 `if (!playing) return;`
/// - EOF 只把 processingState 置 completed，playing 保持 true
/// - 只有 seek / 重新 load 才会离开 completed
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

  void emitPosition(Duration p) => positionCtrl.add(p);
  void emitDuration(Duration? d) => durationCtrl.add(d);
  void emitError(PlayerException e) => errorCtrl.add(e);

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

  /// 每次真正进入引擎加载的歌曲 hash（自动推进的观测点）。
  final List<String> loadedHashes = [];

  /// 命中这些 hash 的 loadSong 挂起（模拟弱网解析/在途换源不返回），
  /// 用来把 `_isChangingSource` 卡在 true。
  final Set<String> blockedHashes = {};
  final List<Completer<void>> _blockers = [];

  /// 模拟 Android 原生 just_audio：play(Result) 只在 playWhenReady 本已为真
  /// 或曲目走到 STATE_ENDED 时回执（AudioPlayer.java:971-986），因此我们
  /// pause 后发起的 `play()` Future 实测会挂到曲末。置 true 复现该行为。
  bool hangPlayUntilCompleted = false;
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
    // seek 离开 completed（与 just_audio / ExoPlayer 一致）。
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
    loadedHashes.add(song.hash);
    engine.setState(ProcessingState.loading);
    if (blockedHashes.contains(song.hash)) {
      final blocker = Completer<void>();
      _blockers.add(blocker);
      await blocker.future;
      return;
    }
    engine.setState(ProcessingState.ready);
  }

  void releaseAllBlocked() {
    for (final blocker in _blockers) {
      if (!blocker.isCompleted) blocker.complete();
    }
    for (final blocker in _playBlockers) {
      if (!blocker.isCompleted) blocker.complete();
    }
  }

  @override
  Future<void> play() async {
    if (engine.playing) return; // just_audio: if (playing) return;
    engine.playing = true;
    if (engine.state != ProcessingState.ready) {
      engine.setState(ProcessingState.ready);
    } else {
      engine.emit();
    }
    if (hangPlayUntilCompleted) {
      final blocker = Completer<void>();
      _playBlockers.add(blocker);
      await blocker.future;
    }
  }

  @override
  Future<void> pause() async {
    if (!engine.playing) return; // just_audio: if (!playing) return;
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
  hash: 'hash_$index',
  duration: const Duration(seconds: 300),
);

/// 让 controller 内部的异步链（地址解析 / 加载 / 通知）跑完。
Future<void> settle([int rounds = 20]) async {
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

  /// 起播第一首并让它处于"播放中"。
  Future<void> startPlaying(List<Song> songs) async {
    controller.queue = songs;
    controller.currentSong = songs.first;
    await controller.playSong(songs.first, queue: songs);
    await settle();
    engine.emitDuration(const Duration(seconds: 300));
    engine.emitPosition(const Duration(seconds: 1));
    await settle();
    expect(controller.isPlaying, isTrue, reason: '前置：第一首应在播放');
    expect(engine.playing, isTrue, reason: '前置：引擎 playing 应为 true');
  }

  test('曲末 completed 被在途换源挡掉时，兜底仍应推进下一首', () async {
    final songs = [_song(1), _song(2)];
    await startPlaying(songs);

    // 位置进入曲末兜底窗口（remaining 400ms ≤ 750ms）→ 建兜底 timer
    // （delay = remaining + 180ms ≈ 580ms）。
    engine.emitPosition(const Duration(seconds: 299, milliseconds: 600));
    await settle();

    // 同曲换源在途且不返回（弱网）：currentSong 仍是第一首、位置仍在曲尾，
    // 但 _isChangingSource 为 true —— completed 分支的 `!_isChangingSource`
    // 会把它整条挡掉；而 _reloadCurrentSongForQuality 不会取消兜底 timer。
    handler.blockedHashes.add(songs[0].hash);
    unawaited(
      controller.setAudioQuality(AudioQuality.lossless, reloadCurrent: true),
    );
    await settle();
    expect(
      controller.currentSong?.hash,
      songs[0].hash,
      reason: '前置：在途换源期间当前曲不变',
    );

    // Android 原生在 EOF 只把 processingState 置 completed：
    // 3.0.3 起 isPlaying 随之收敛为 false，主推进又被在途换源挡掉。
    engine.setState(ProcessingState.completed);
    await settle();
    expect(controller.isPlaying, isFalse, reason: 'completed 后 isPlaying 应收敛');

    // 等兜底 timer 到点：它必须接管并推进队列。3.0.2 时 playing 陈旧为 true
    // 所以能推进；3.0.3 若以 isPlaying 判活就会失效——即手机上的"不跳转"。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    handler.blockedHashes.clear();
    handler.releaseAllBlocked();
    await settle();

    expect(
      controller.currentSong?.hash,
      songs[1].hash,
      reason: '曲末兜底必须推进到下一首，而不是永久停在曲尾',
    );
    expect(handler.loadedHashes, contains(songs[1].hash));
  });

  test('Android：play 确认挂到曲末时，completed 主分支仍能推进下一首', () async {
    final songs = [_song(1), _song(2)];
    // 复现实机：起播前 pause 过 → play(Result) 拖到曲末才回执。
    handler.hangPlayUntilCompleted = true;
    await startPlaying(songs);
    engine.emitDuration(const Duration(seconds: 300));
    engine.emitPosition(const Duration(seconds: 5));
    await settle();

    // 位置远未到曲尾 → 曲末兜底 timer 根本没建立，唯一能推进的就是
    // completed 主分支（它要求 !_isChangingSource）。
    engine.setState(ProcessingState.completed);
    await settle();

    expect(
      controller.currentSong?.hash,
      songs[1].hash,
      reason: '起播确认不得把换源深度钉到曲末，否则 completed 主分支永远被挡',
    );
    expect(handler.loadedHashes, contains(songs[1].hash));
  });

  test('Android：play 确认挂到曲末时，播放中途错误不得被静默吞掉', () async {
    final songs = [_song(1), _song(2)];
    handler.hangPlayUntilCompleted = true;
    await startPlaying(songs);
    engine.emitDuration(const Duration(seconds: 300));
    engine.emitPosition(const Duration(seconds: 10));
    await settle();

    // 中途断流/解码失败：处理条件是 !isPreparing && !_isChangingSource，
    // 若换源深度被 play() 钉在 1，这里会被静默吞掉（界面假播放、无提示）。
    engine.emitError(PlayerException(1, 'Error decoding audio.', 0));
    await settle();

    expect(
      controller.errorMessage,
      '播放中断，请稍后重试',
      reason: '起播确认不得把换源深度钉到曲末，否则中途错误全被忽略',
    );
  });

  test('同曲重播（曲末点播放）播完后仍应自动跳下一首', () async {
    final songs = [_song(1), _song(2)];
    await startPlaying(songs);
    engine.emitPosition(const Duration(seconds: 299));
    await settle();

    // 睡眠定时「播完这首再停」：完成处理走暂停分支、不推进，
    // 但会留下完成去重标记（_completedSongHash = 第一首），复现重播现场。
    controller.setSleepTimer(Duration.zero, finishCurrentSong: true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    engine.setState(ProcessingState.completed);
    await settle();
    expect(controller.currentSong?.hash, songs[0].hash, reason: '前置：本轮不推进');
    expect(controller.isPlaying, isFalse);

    // 用户点播放：3.0.3 起走 pause→seek(0)→play（不经 playSong），
    // 必须同时清掉上一轮的完成去重标记。
    await controller.togglePlay();
    await settle();
    expect(engine.playing, isTrue, reason: '前置：重播应真的起播');

    // 这一遍正常播完：应能自动跳到下一首。
    engine.emitPosition(const Duration(seconds: 299, milliseconds: 900));
    await settle();
    engine.setState(ProcessingState.completed);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await settle();

    expect(
      controller.currentSong?.hash,
      songs[1].hash,
      reason: '同曲重播播完必须仍能自动切歌（去重标记不得跨轮残留）',
    );
    expect(handler.loadedHashes, contains(songs[1].hash));
  });
}
