// 「听歌时长跨会话累计」回归（上游 3.3.0 e9dde17 #151 的回移实现）。
//
// 背景：fork 此前与上游 3.2.0 逐字相同——30min 上报 / 1min 检查，且
// `_pendingListenTime` 只在内存里；进程被杀（尤其移动端后台）时，未满
// 一个上报周期的听歌时长直接丢失。本实现改为 5min/15s，并把余量持久化到
// `settings.pending_listen_time_ms`，重启后接着累计。
//
// 覆盖点：
//   1) 启动时读回未上报余量；
//   2) 播放中暂停（与切歌/dispose 同路径）→ 本段时长并入余量并落盘；
//   3) 上报成功 → 同步一次、本地统计 +5min、剩余余量落盘；
//   4) 关闭开关（重置）→ 清零并落盘（否则下次启动读回旧值继续上报）；
//   5) 上报失败（网络异常）→ 余量不丢、不写脏数据、不崩溃；
//   6) 余量不足一个上报周期 → 不发起上报。
//
// 说明：听歌时长由 Timer(15s) + DateTime 驱动，单测无法真实等待 5min；
// 这里通过预置持久化余量把 `_trackedListeningTime()` 推过阈值，再用
// `@visibleForTesting` 的单次上报触发点确定性验证上报/失败路径。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';
import 'package:shiyin_music/services/playback_stats_service.dart';

const _pendingKey = 'settings.pending_listen_time_ms';

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
  Future<void> seek(Duration position, [dynamic options]) async {}

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
  int addListeningTimeCalls = 0;

  /// 非 null 时 `addListeningTime` 抛该异常（模拟断网/服务端失败）。
  Object? addListeningTimeError;

  @override
  Future<void> addListeningTime() async {
    addListeningTimeCalls++;
    final error = addListeningTimeError;
    if (error != null) throw error;
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

Song _song(int index) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手$index',
  hash: 'hash_listen_$index',
  duration: const Duration(seconds: 300),
);

/// 让控制器内部异步链（_restoreSettings/unawaited 落盘）跑完。
Future<void> settle([int rounds = 40]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _Engine? engine;
  _MockMusicApi? api;
  PlayerController? controller;

  PlayerController create() {
    final e = _Engine();
    final player = _FakeAudioPlayer(e);
    final handler = _EngineAudioHandler(e, player);
    final a = _MockMusicApi();
    engine = e;
    api = a;
    final c = PlayerController(a, handler);
    controller = c;
    return c;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    engine = null;
    api = null;
    controller = null;
  });

  tearDown(() async {
    await settle();
    controller?.dispose();
    controller = null;
    await engine?.dispose();
    engine = null;
  });

  test('启动时读回未上报余量（跨会话累计）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _pendingKey: 123456,
    });
    final c = create();
    await settle();

    expect(
      c.pendingListenTimeForTest,
      const Duration(milliseconds: 123456),
      reason: '重启后必须接着上次的余量累计，而不是从 0 起算',
    );
  });

  test('播放中暂停：本段时长并入余量并落盘', () async {
    final c = create();
    await settle();

    // 模拟引擎进入播放态（真实链路里由 playerStateStream 驱动）。
    c.currentSong = _song(1);
    engine!.playing = true;
    engine!.emit();
    await settle();

    expect(c.isPlaying, isTrue, reason: '引擎状态应已同步为播放中');
    expect(
      c.pendingListenTimeForTest,
      Duration.zero,
      reason: '播放中时长尚未结算，不应提前并入余量',
    );

    await Future<void>.delayed(const Duration(milliseconds: 80));
    engine!.playing = false;
    engine!.emit();
    await settle();

    final pending = c.pendingListenTimeForTest;
    expect(pending, greaterThan(Duration.zero), reason: '暂停时本段时长必须并入余量');

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(_pendingKey),
      pending.inMilliseconds,
      reason: '暂停后余量必须落盘，进程被杀也不丢',
    );
  });

  test('上报成功：同步 5min、本地统计累加、剩余余量落盘', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _pendingKey: 10 * 60 * 1000,
    });
    final c = create();
    await settle();
    expect(c.pendingListenTimeForTest, const Duration(minutes: 10));

    await c.reportListeningTimeForTest();
    await settle();

    expect(api!.addListeningTimeCalls, 1, reason: '超过周期应上报一次');
    final stats = await PlaybackStatsService().getStats();
    expect(
      stats.totalListenTime,
      const Duration(minutes: 5),
      reason: '一次上报只把 5 分钟计入本地统计（与上报周期一致）',
    );

    final remainder = c.pendingListenTimeForTest;
    expect(
      remainder,
      greaterThanOrEqualTo(const Duration(minutes: 5)),
      reason: '10min 余量上报 5min 后应剩约 5min',
    );
    expect(
      remainder,
      lessThan(const Duration(minutes: 5, seconds: 2)),
      reason: '余量不应超过预置值减去一个周期',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(_pendingKey),
      remainder.inMilliseconds,
      reason: '上报成功后的余量必须落盘',
    );
  });

  test('关闭听歌时长开关（重置）清零并落盘', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _pendingKey: 123456,
    });
    final c = create();
    await settle();
    expect(c.pendingListenTimeForTest, const Duration(milliseconds: 123456));

    await c.setAddListeningTimeEnabled(false);
    await settle();

    expect(c.pendingListenTimeForTest, Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(_pendingKey),
      0,
      reason: '重置必须写 0；只清内存的话下次启动会读回旧余量继续上报',
    );
  });

  test('上报失败：余量不丢、不写脏数据、不崩溃', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _pendingKey: 10 * 60 * 1000,
    });
    final c = create();
    await settle();
    api!.addListeningTimeError = Exception('network down');

    await c.reportListeningTimeForTest();
    await settle();

    expect(api!.addListeningTimeCalls, 1);
    expect(
      c.pendingListenTimeForTest,
      const Duration(minutes: 10),
      reason: '上报失败不得扣减/清零余量，等下次检查再重试',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(_pendingKey),
      10 * 60 * 1000,
      reason: '失败路径不应改写已落盘的余量',
    );
  });

  test('余量不足一个上报周期：不发上报', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _pendingKey: 4 * 60 * 1000,
    });
    final c = create();
    await settle();

    await c.reportListeningTimeForTest();
    await settle();

    expect(api!.addListeningTimeCalls, 0, reason: '未满 5min 不应触发上报');
    expect(c.pendingListenTimeForTest, const Duration(minutes: 4));
  });
}
