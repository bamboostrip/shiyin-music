// 播放进度持久化（全局单点：最后在播那首 + 位置）的回归测试。
//
// 移植上游 3.3.0 `c113193` + `165eb46` 的语义：
//   1. 恢复进度必须与歌曲 hash 匹配，不能串到别的歌；
//   2. 尾 3 秒内不恢复（否则一开播就撞曲末跳歌）；
//   3. 归属守卫：音源没换成当前歌 / 还在加载定位时不写；归属成立后合法的 0
//      也要写（否则暂停在开头会残留上一次的旧进度）；
//   4. resumePlayback 只在第一首带进度，失败换下一首不带。
import 'dart:async';
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
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

  @override
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

  /// 引擎当前的处理态：冷启动恢复后无音源时应为 idle。
  ProcessingState state = ProcessingState.ready;

  @override
  ProcessingState get processingState => state;

  @override
  int? get androidAudioSessionId => null;

  void emitPlaying(bool value) {
    playing = value;
    _playerStateController.add(PlayerState(value, ProcessingState.ready));
  }

  /// 模拟引擎位置上报，让 controller 的 position/smoothPosition 跟上。
  void emitPosition(Duration value) {
    currentPosition = value;
    _positionController.add(value);
  }

  /// 模拟引擎状态上报（冷启动无音源时是 `playing=false/processing=idle`）。
  void emitState({required bool playing, required ProcessingState processing}) {
    state = processing;
    this.playing = playing;
    _playerStateController.add(PlayerState(playing, processing));
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
  /// 非空时挂起地址解析，用于构造「加载中被暂停」的时序。
  Completer<void>? gate;

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async {
    final pending = gate;
    if (pending != null) await pending.future;
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

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
  late _MockMusicApi api;
  late List<PlayerController> controllers;

  PlayerController buildController() {
    final controller = PlayerController(api, handler);
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
    api = _MockMusicApi();
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

    test('当前歌 hash 为空时拒绝任何记录（无法归属）', () {
      expect(parseSavedPosition('{"hash":"h1","ms":90000}', ''), isNull);
      expect(parseSavedPosition('{"hash":"h1","ms":90000}', null), isNull);
      expect(parseSavedPosition(90000, ''), isNull);
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

    test('恢复到开头后暂停：合法的 0 要落盘，不能残留上次的 90s', () async {
      final song = _song(1);
      seedSnapshot(song);
      final controller = buildController();
      await settle();

      controller.queue = [song];
      fakeAudioPlayer.currentPosition = Duration.zero;
      await controller.playSong(song);
      await settle();
      await controller.togglePlay(); // 用户暂停在 0:00
      await settle();

      final prefs = await SharedPreferences.getInstance();
      final record =
          jsonDecode(prefs.getString(_positionKey)!) as Map<String, dynamic>;
      expect(record['ms'], 0, reason: '用户主动回到开头必须覆盖旧记录');
    });

    test('加载中被暂停：落盘 0，不残留这首歌上一次的进度', () async {
      final song = _song(1);
      seedSnapshot(song); // 磁盘上已有 90s
      final controller = buildController();
      await settle();

      await controller.playSong(song); // 先进入在播态，用户才有「暂停」可点
      await settle();

      api.gate = Completer<void>();
      final pending = controller.playSong(song); // 再次选歌，解析挂起
      await settle();
      await controller.togglePlay(); // 解析还没回来就暂停
      api.gate!.complete();
      await pending;
      await settle();

      final prefs = await SharedPreferences.getInstance();
      final record =
          jsonDecode(prefs.getString(_positionKey)!) as Map<String, dynamic>;
      expect(record['ms'], 0, reason: '这次选歌从未出声，不能恢复到上次的 90s');
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

    test('引擎被 stop 成 idle（音源已释放）后 flush：不得用 0 抹掉磁盘进度', () async {
      final song = _song(1);
      seedSnapshot(song); // 磁盘上已有 90s
      final controller = buildController();
      await settle();

      controller.queue = [song];
      await controller.playSong(song); // 归属建立，_positionOwnerHash = hash
      await settle();
      fakeAudioPlayer.emitPosition(const Duration(seconds: 42));
      await settle();

      // 系统 stop / 前台服务被回收：引擎释放音源，position 归 0。
      fakeAudioPlayer.currentPosition = Duration.zero;
      fakeAudioPlayer.emitState(
        playing: false,
        processing: ProcessingState.idle,
      );
      await settle();
      await controller.flushPlaybackState();
      await settle();

      final prefs = await SharedPreferences.getInstance();
      final record =
          jsonDecode(prefs.getString(_positionKey)!) as Map<String, dynamic>;
      expect(
        record['ms'],
        isNot(0),
        reason: '空载引擎的 0 不是用户听到的位置，不能覆盖磁盘上的记录',
      );
    });

    test('切音质重载被状态机拦下：已归属/已定位的进度仍要落盘', () async {
      final song = _song(1);
      final controller = buildController();
      await settle();

      controller.queue = [song];
      await controller.playSong(song);
      await settle();
      fakeAudioPlayer.emitPosition(const Duration(seconds: 42));
      await settle();

      api.gate = Completer<void>();
      final pending = controller.setAudioQuality(
        AudioQuality.high,
        reloadCurrent: true,
      );
      await settle();

      // 打断开始只设闩锁、不推进企图代次：重载会走完加载，但起播会被拒。
      controller.handleInterruptionEvent(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );

      api.gate!.complete();
      await pending;
      await settle();

      final prefs = await SharedPreferences.getInstance();
      final record =
          jsonDecode(prefs.getString(_positionKey)!) as Map<String, dynamic>;
      expect(record['hash'], song.hash);
      expect(
        record['ms'],
        greaterThan(40000),
        reason: '重载被拦下时 isPreparing 仍为 true，必须显式豁免才能落盘',
      );
    });
  });

  // 回归：手机没有「开机自播」时，用户是点播放按钮续播的。
  // 冷启动恢复后引擎无音源（idle），音频服务绑定/通知栏媒体键/后台服务重建
  // 都会让引擎上报一次 `position=0` 的空载状态；旧实现把它当成真实位置写进
  // 内存基准，界面立刻变 00:00，点播放也从 0 起播——车机走 resumePlayback
  // 不经过内存 position，所以只有手机暴露（issue #38）。
  group('手机冷启动：引擎空载回调不得冲掉恢复位置', () {
    test('空载状态回调后位置仍是上次的位置', () async {
      final song = _song(1);
      seedSnapshot(song);
      fakeAudioPlayer.state = ProcessingState.idle;
      final controller = buildController();
      await settle();
      expect(controller.position, const Duration(seconds: 90));

      fakeAudioPlayer.currentPosition = Duration.zero;
      fakeAudioPlayer.emitState(
        playing: false,
        processing: ProcessingState.idle,
      );
      await settle();

      expect(
        controller.position,
        const Duration(seconds: 90),
        reason: '引擎 idle 上报的 0 不是真实进度，界面必须保持「上次听到 01:30」',
      );
    });

    test('手动点播放从恢复位置续（不依赖内存里的 position）', () async {
      final song = _song(1);
      seedSnapshot(song);
      fakeAudioPlayer.state = ProcessingState.idle;
      final controller = buildController();
      await settle();

      // 内存基准被抹掉也不影响续播：_resumePosition 才是恢复的真相。
      fakeAudioPlayer.currentPosition = Duration.zero;
      fakeAudioPlayer.emitState(
        playing: false,
        processing: ProcessingState.idle,
      );
      await settle();

      await controller.togglePlay();
      await settle();

      expect(
        handler.seeks,
        contains(const Duration(seconds: 90)),
        reason: '手机手动播放必须从上次位置续，而不是从 0 起播',
      );
      expect(controller.isPlaying, isTrue);
      expect(controller.hasPendingResumePosition, isFalse);
    });
  });
}
