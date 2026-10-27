// 后台切歌不丢 AudioFocus/WakeLock（对齐上游 PR #156 / 2050a8e）回归。
//
// 旧实现切歌时无条件 `_audioHandler.pause()`：audio_service 会广播
// playing=false → Android 释放 WakeLock/撤销 AudioFocus；黑屏后台自动
// 切歌（尤其自然播完自动下一首）后下一曲起播可能拿不回焦点，表现为
// 「下一曲暂停不播、必须点亮屏幕才恢复」。
//
// 新实现：旧歌真实在播时只把引擎音量压到 0（不 pause，播放状态保持
// playing，焦点/WakeLock 不断），新音源加载完成后按 fork 的
// 「userVolume × 响度增益」还原；completed（自然播完）/已暂停/冷启动
// 不做任何 pause/静音动作；异常/提前 return 路径必须代际解除静音，
// 绝不允许引擎永久静音。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

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

  /// 引擎 setVolume 调用序列（静音 / 解除静音的观测点）。
  final List<double> volumeCalls = [];

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

  /// 测试固定返回满音量：解除静音时 LoudnessService 的「当前值≈目标值」
  /// 快路径会直接 setVolume(目标)，便于断言序列。
  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {
    volumeCalls.add(volume);
  }

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

  /// 切歌流程中 `_audioHandler.pause()` 的调用次数（旧实现无条件 1 次）。
  int pauseCalls = 0;

  /// 模拟 loadSong（setUrl）失败，用于异常收尾路径。
  bool failLoadSong = false;

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
    if (failLoadSong) {
      throw Exception('模拟音源加载失败');
    }
    loadedHashes.add(song.hash);
    engine.setState(ProcessingState.loading);
    engine.setState(ProcessingState.ready);
  }

  @override
  Future<void> play() async {
    if (engine.playing) return;
    engine.playing = true;
    engine.emit();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
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
    bool hashOnly = false,
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
  hash: 'hash_bgswitch_$index',
  duration: const Duration(seconds: 300),
);

/// 让控制器内部异步链与 `unawaited` 的收尾跑完。
Future<void> settle([int rounds = 40]) async {
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

  test('旧歌在播时手动切歌：不调用 pause，先静音后恢复音量', () async {
    final a = _song(1);
    final b = _song(2);
    await controller.playSong(a, queue: [a, b]);
    await settle();
    expect(engine.playing, isTrue);
    expect(controller.isPlaying, isTrue, reason: '前置：旧歌必须真实在播');

    player.volumeCalls.clear();
    handler.pauseCalls = 0;

    await controller.playSong(b, queue: [a, b]);
    await settle();

    expect(
      handler.pauseCalls,
      0,
      reason: '切歌不得 pause：pause 会让 audio_service 释放 WakeLock/撤销 AudioFocus',
    );
    expect(
      player.volumeCalls.first,
      0.0,
      reason: '旧歌在播时必须先静音旧音频（不暂停，焦点/WakeLock 不断）',
    );
    expect(
      player.volumeCalls.any((v) => v > 0),
      isTrue,
      reason: '新音源加载后必须按代际解除静音（还原 userVolume×响度增益）',
    );
    expect(controller.currentSong?.hash, b.hash);
  });

  test('completed 自然播完自动下一首：不 pause、不静音', () async {
    final a = _song(3);
    final b = _song(4);
    await controller.playSong(a, queue: [a, b]);
    await settle();

    player.volumeCalls.clear();
    handler.pauseCalls = 0;

    // 模拟自然播完：引擎 completed（移动端 playing 可能仍是陈旧 true，
    // 这里置 false 贴近多数实机），completed 监听会自动切下一首。
    engine.playing = false;
    engine.setState(ProcessingState.completed);
    await settle();

    expect(controller.currentSong?.hash, b.hash, reason: 'completed 应自动切到下一首');
    expect(
      handler.pauseCalls,
      0,
      reason: '自然播完切歌不得 pause（黑屏后台切歌丢 AudioFocus/WakeLock 的根因）',
    );
    expect(
      player.volumeCalls.where((v) => v == 0.0),
      isEmpty,
      reason: '未在播（completed）不应做任何静音动作',
    );
  });

  test('加载异常路径：收尾解除静音，引擎不会永久静音', () async {
    final a = _song(5);
    final b = _song(6);
    await controller.playSong(a, queue: [a, b]);
    await settle();

    player.volumeCalls.clear();
    handler.pauseCalls = 0;
    handler.failLoadSong = true;

    // isRetry=true 跳过 2s 自动重试等待，直接落确定性失败收尾。
    await controller.playSong(b, queue: [a, b], isRetry: true);
    await settle();

    expect(controller.errorMessage, isNotNull);
    expect(
      player.volumeCalls.first,
      0.0,
      reason: '旧歌在播时切歌应先静音',
    );
    expect(
      player.volumeCalls.last,
      greaterThan(0.0),
      reason: '异常收尾必须解除静音，否则引擎永久无声',
    );
    expect(
      handler.pauseCalls,
      greaterThanOrEqualTo(1),
      reason: '失败路径保留原有 pause 收尾（此时已不在后台自动切歌主链路）',
    );
  });

  test('wasPlaying=false（冷启动/已暂停）切歌：不静音不暂停', () async {
    final a = _song(7);
    await controller.playSong(a, queue: [a]);
    await settle();

    expect(
      handler.pauseCalls,
      0,
      reason: '旧实现在这里无条件 pause（会丢 WakeLock），新实现必须跳过',
    );
    expect(
      player.volumeCalls.where((v) => v == 0.0),
      isEmpty,
      reason: '未在播时不需要静音旧音频',
    );
  });
}
