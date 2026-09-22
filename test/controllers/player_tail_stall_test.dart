// 曲末停滞 watchdog 回归：CDN 尾部断供时引擎位置冻结在曲尾前 1~2 秒、
// completed 永远不来，位置也不再触发新的兜底窗口（remaining > 750ms）——
// 队列此前永久停在曲尾、重启才能恢复。watchdog 必须在「仍在播 + 位置
// 停滞」时按播完强制推进，并在用户暂停时绝不误切。
//
// 另锁定「重新出声作废完成去重」不变式：系统播放键（通知栏/耳机）曲末
// 重播不经 togglePlay（应用内入口会自己清去重标记），去重标记若不随
// 「重新出声」作废，这首第二次播完时 completed 会被当成重复事件吞掉，
// 队列再次停在曲尾。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

/// 忠实现 just_audio 的 Dart 侧状态机（与 player_completion_fallback_test
/// 同构），两处差异让观测更真实：
/// - position 是真实字段（watchdog 依赖「位置冻结」的观测）；
/// - load 重置位置、seek 移动位置（真实引擎行为，也杜绝旧位置串场）。
class _Engine {
  bool playing = false;
  ProcessingState state = ProcessingState.idle;
  Duration position = Duration.zero;
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

  void emitPosition(Duration p) {
    position = p;
    positionCtrl.add(p);
  }

  void emitDuration(Duration? d) => durationCtrl.add(d);

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
  Duration get position => engine.position;

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

  final List<String> loadedHashes = [];

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
    engine.emitPosition(position);
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
    engine.emitPosition(Duration.zero);
    engine.setState(ProcessingState.ready);
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
    await settle();
    controller.dispose();
    await engine.dispose();
  });

  /// 起播第一首进入「播放中」，再把位置推进到曲末兜底窗口
  /// （remaining 400ms ≤ 750ms → 兜底 timer 建立，约 580ms 后到点）。
  Future<void> startPlayingNearEnd(List<Song> songs) async {
    controller.queue = songs;
    controller.currentSong = songs.first;
    await controller.playSong(songs.first, queue: songs);
    await settle();
    engine.emitDuration(const Duration(seconds: 300));
    engine.emitPosition(const Duration(seconds: 1));
    await settle();
    expect(controller.isPlaying, isTrue, reason: '前置：第一首应在播放');

    engine.emitPosition(const Duration(seconds: 299, milliseconds: 600));
    await settle();
  }

  test('曲末位置冻结且引擎不来 completed → watchdog 强制按播完推进下一首', () async {
    final songs = [_song(1), _song(2)];
    await startPlayingNearEnd(songs);

    // 兜底 timer 580ms 后到点（位置冻结在 299.6s，距曲尾 400ms > 220ms
    // 判距 → 原版逻辑在此放弃）；停滞复检 1.5s×4 次后（≈5.1s）强制推进。
    await Future<void>.delayed(const Duration(milliseconds: 5600));
    expect(
      controller.currentSong?.hash,
      songs[1].hash,
      reason: '位置冻结 + 仍在播 + completed 不来，watchdog 必须推进队列',
    );
    expect(handler.loadedHashes, contains(songs[1].hash));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('用户在曲末暂停：位置再怎么冻结也不得被误判为播完而切歌', () async {
    final songs = [_song(1), _song(2)];
    await startPlayingNearEnd(songs);

    // 兜底 timer 建立后用户按下暂停：引擎 playing 收敛为 false。
    await controller.togglePlay();
    await settle();
    expect(controller.isPlaying, isFalse, reason: '前置：用户已暂停');

    // 覆盖兜底 timer 到点 + 全部复检窗口（≈5.1s）：暂停在曲尾必须原地。
    await Future<void>.delayed(const Duration(milliseconds: 6700));
    expect(
      controller.currentSong?.hash,
      songs[0].hash,
      reason: '暂停在曲尾不得被 watchdog 误判为播完',
    );
    expect(
      handler.loadedHashes,
      isNot(contains(songs[1].hash)),
      reason: '不得偷偷加载下一首',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('停滞复检期间位置恢复前进 → watchdog 放弃，交给既有完成链', () async {
    final songs = [_song(1), _song(2)];
    await startPlayingNearEnd(songs);

    // 兜底 timer 到点（进入第一次停滞复检），位置恢复前进，随后引擎正常
    // 走到 EOF：由 completed 主链推进。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    engine.emitPosition(const Duration(seconds: 299, milliseconds: 900));
    await settle();
    engine.setState(ProcessingState.completed);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settle();

    expect(
      controller.currentSong?.hash,
      songs[1].hash,
      reason: '恢复前进后由正常完成链推进，watchdog 不得干扰',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('通知键曲末重播（不经 togglePlay）后去重标记作废：再播完仍能跳下一首', () async {
    final songs = [_song(1), _song(2)];
    await startPlayingNearEnd(songs);

    // 睡眠定时「播完这首再停」：完成处理走暂停分支、不推进，但留下完成
    // 去重标记（_completedSongHash = hash_1），构造「同曲已处理过」现场。
    controller.setSleepTimer(Duration.zero, finishCurrentSong: true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    engine.setState(ProcessingState.completed);
    await settle();
    expect(controller.currentSong?.hash, songs[0].hash, reason: '前置：本轮不推进');
    expect(controller.isPlaying, isFalse);

    // 模拟系统播放键路径（MusicAudioHandler.play 的曲末恢复语义）：
    // pause → seek(0) → play，不经 togglePlay。
    await handler.pause();
    await handler.seek(Duration.zero);
    await handler.play();
    await settle();
    expect(engine.playing, isTrue, reason: '前置：通知键重播应真的起播');

    // 这一遍播完：必须仍能自动跳到下一首（去重标记已随重新出声作废）。
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
  }, timeout: const Timeout(Duration(seconds: 30)));
}
