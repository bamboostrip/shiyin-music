import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

/// 打断 / 断连状态机的回归用例（上游 3.3.0 `56d0c9f` + `9426621` + `c7ba1e6`）。
///
/// 这里直接驱动 `handleInterruptionEvent` / `handleBecomingNoisy`：
/// `AudioSession` 是私有构造的单例，单测无法伪造，而容易错的恰恰是
/// 「要不要暂停、要不要恢复」这些决策；真实事件流只是把它们转接过来。
class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _errorController = StreamController<PlayerException>.broadcast();
  final _androidAudioSessionIdController =
      StreamController<int?>.broadcast();

  bool _playing = false;

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
  Duration? get duration => const Duration(seconds: 200);

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  int? get androidAudioSessionId => null;

  void emitPlaying(bool playing) {
    _playing = playing;
    _playerStateController.add(PlayerState(playing, ProcessingState.ready));
  }

  void disposeStreams() {
    _positionController.close();
    _playerStateController.close();
    _processingStateController.close();
    _durationController.close();
    _errorController.close();
    _androidAudioSessionIdController.close();
  }
}

class _RecordingAudioHandler extends Fake implements MusicAudioHandler {
  _RecordingAudioHandler(this._audioPlayer);

  final _FakeAudioPlayer _audioPlayer;
  int playCallCount = 0;
  int pauseCallCount = 0;
  bool autoPaused = false;

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
    playCallCount++;
    _audioPlayer.emitPlaying(true);
  }

  @override
  Future<void> pause({bool userInitiated = true}) async {
    pauseCallCount++;
    if (!userInitiated) autoPaused = true;
    _audioPlayer.emitPlaying(false);
  }

  @override
  Future<void> stop() async {
    _audioPlayer.emitPlaying(false);
  }

  @override
  Future<void> seek(Duration position, [dynamic options]) async {}

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {
  /// 非空时 `songUrl` 挂起，直到测试自己 complete（模拟弱网解析）。
  Completer<void>? gate;

  /// 非空时 `personalFm` 挂起（模拟 FM 首批还在拉取）。
  Completer<void>? fmGate;

  /// `songUrl` 对这些 hash 抛网络错误（模拟首次解析失败，验证重试路径）。
  final Set<String> failSongUrlHashes = <String>{};

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async {
    if (failSongUrlHashes.contains(song.hash)) {
      throw Exception('mock network error');
    }
    final pending = gate;
    if (pending != null) await pending.future;
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];

  @override
  Future<List<Song>> personalFm({
    String? hash,
    String? songId,
    int? playtime,
    bool isOverplay = false,
  }) async {
    final pending = fmGate;
    if (pending != null) await pending.future;
    return [_song(9)];
  }
}

Song _song(int index) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手$index',
  hash: 'hash_$index',
  duration: const Duration(seconds: 200),
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
  });

  /// 用例体内显式收尾：`_verifyInvariants` 早于 tearDown 执行，
  /// 定时器（播后缓存的 15s 表、自动恢复的 500ms 表）必须在用例体内取消。
  void finish() {
    controller.dispose();
    fakeAudioPlayer.disposeStreams();
  }

  /// 让 controller 进入「真的有歌在播」的状态。
  Future<void> startPlaying(WidgetTester tester) async {
    controller.queue = [_song(1), _song(2)];
    await controller.playSong(_song(1));
    await tester.pump();
    expect(controller.isPlaying, isTrue, reason: '前置：应已开始播放');
  }

  group('蓝牙/耳机断开（becomingNoisy）', () {
    testWidgets('默认开关下立刻暂停，且不会自动恢复', (tester) async {
      await startPlaying(tester);
      handler.pauseCallCount = 0;

      controller.handleBecomingNoisy();
      await tester.pump();

      expect(handler.pauseCallCount, 1, reason: '断开必须立刻暂停，否则外放');
      expect(handler.autoPaused, isTrue, reason: '这是流程暂停，不是用户意图');
      expect(controller.isPlaying, isFalse);

      // 关键：断开之后的「打断结束」不得把声音放回扬声器。
      handler.playCallCount = 0;
      controller.handleInterruptionEvent(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      controller.handleInterruptionEvent(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(handler.playCallCount, 0, reason: '断连保护只能由用户显式播放解除');
      expect(controller.isPlaying, isFalse);

      finish();
    });

    testWidgets('用户显式点播放后解除断连保护', (tester) async {
      await startPlaying(tester);
      controller.handleBecomingNoisy();
      await tester.pump();
      expect(controller.isPlaying, isFalse);

      await controller.togglePlay();
      await tester.pump();
      expect(controller.isPlaying, isTrue, reason: '用户点播放应能正常起播');

      finish();
    });

    testWidgets('私人 FM 启动拉取期间断开：拉取完成后不得外放起播', (tester) async {
      // 弱网下 FM 首批可能拉几秒：期间拔耳机建立的保护，不得被拉取完成后
      // 的起播以「用户意图」自居解掉（上游 3.3.0 `9426621` 的 FM 入口处理）。
      api.fmGate = Completer<void>();
      final started = controller.startPersonalFm();
      await tester.pump();

      controller.handleBecomingNoisy();
      await tester.pump();

      api.fmGate!.complete();
      await started;
      await tester.pump();

      expect(
        handler.playCallCount,
        0,
        reason: '断连保护必须拦下拉取后才完成的起播，否则从扬声器外放',
      );
      expect(controller.isPlaying, isFalse);
      // 被保护拦下不是播放失败，不得弹错误态。
      expect(controller.errorMessage, isNull);

      // 用户随后显式点播放仍能正常起播（保护出口不受影响）。
      await controller.togglePlay();
      await tester.pump();
      expect(controller.isPlaying, isTrue, reason: '显式播放应解除保护正常起播');

      finish();
    });

    testWidgets('关闭「断开停止播放」后仍会暂停（防外放是底线）', (tester) async {
      await startPlaying(tester);
      await controller.setAutoPauseOnDeviceDisconnect(false);
      handler.pauseCallCount = 0;

      controller.handleBecomingNoisy();
      await tester.pump();

      expect(handler.pauseCallCount, 1);
      expect(controller.isPlaying, isFalse);

      finish();
    });
  });

  group('私人 FM 启动拉取期间的意图', () {
    testWidgets('拉取期间用户暂停：完成后不得起播，队列预载且显式播放可续', (tester) async {
      // 弱网下 FM 首批要在点按之后才拉回来：期间用户按了暂停，拉取完成
      // 不能把「用户意图」捡回来自己起播。
      await startPlaying(tester);
      handler.playCallCount = 0;
      api.fmGate = Completer<void>();
      final started = controller.startPersonalFm();
      await tester.pump();
      expect(controller.isLoadingPersonalFm, isTrue);

      // 用户暂停：推进企图代次。
      await controller.togglePlay();
      await tester.pump();
      expect(controller.isPlaying, isFalse);

      api.fmGate!.complete();
      final success = await started;
      await tester.pump();

      expect(success, isTrue, reason: '被状态机拦下不是加载失败');
      expect(
        handler.playCallCount,
        0,
        reason: '用户已经暂停，拉取完成不得自动起播',
      );
      expect(controller.isPlaying, isFalse);
      expect(controller.errorMessage, isNull);
      // 队列与音源仍装载：用户按播放能直接从这一首继续。
      expect(controller.currentSong?.hash, 'hash_9');

      await controller.togglePlay();
      await tester.pump();
      expect(controller.isPlaying, isTrue, reason: '显式播放应能续上已预载的 FM 队列');
      expect(handler.playCallCount, 1);

      finish();
    });

    testWidgets('拉取期间用户暂停后又恢复播放：不得用 FM 预载顶掉正在播的歌', (tester) async {
      await startPlaying(tester);
      handler.playCallCount = 0;
      api.fmGate = Completer<void>();
      final started = controller.startPersonalFm();
      await tester.pump();

      await controller.togglePlay(); // 暂停
      await tester.pump();
      // 恢复播放：比点按 FM 更晚的用户意图。
      await controller.togglePlay();
      await tester.pump();
      expect(controller.isPlaying, isTrue);
      expect(handler.playCallCount, 1);

      api.fmGate!.complete();
      final success = await started;
      await tester.pump();

      expect(success, isTrue, reason: '被更晚的播放动作接管，不算加载失败');
      expect(
        controller.currentSong?.hash,
        'hash_1',
        reason: '正在播的歌不能被 FM 预载换掉（否则最后一次操作是播放却变静音）',
      );
      expect(controller.isPlaying, isTrue);
      expect(handler.playCallCount, 1, reason: 'FM 不应再起播');

      finish();
    });

    testWidgets('拉取期间打断结束（默认不自动恢复）：完成后不得起播', (tester) async {
      await startPlaying(tester);
      handler.playCallCount = 0;
      api.fmGate = Completer<void>();
      final started = controller.startPersonalFm();
      await tester.pump();

      // 打完电话：默认「打断结束不自动恢复」会撤销在途起播。
      controller.handleInterruptionEvent(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      controller.handleInterruptionEvent(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await tester.pump();
      expect(controller.isPlaying, isFalse);

      api.fmGate!.complete();
      await started;
      await tester.pump();

      expect(
        handler.playCallCount,
        0,
        reason: '打断结束已撤销在途起播，拉取完成不得自己开始',
      );
      expect(controller.isPlaying, isFalse);
      expect(controller.errorMessage, isNull);

      finish();
    });

    testWidgets('自动重试不得绕过错期的企图代次', (tester) async {
      // 首次解析失败 → 2s 后 playSong 自动重试。重试若重新取当前代次，
      // 就会绕过入口登记（私人 FM 拉取期间暂停/断连正是这条路径）。
      handler.playCallCount = 0;
      api.failSongUrlHashes.add('hash_5');
      final pending = controller.playSong(
        _song(5),
        // 比任何真实代次都早、必然过期：模拟入口登记后已被推进。
        expectedIntent: -1,
        userInitiated: false,
      );
      await tester.pump();

      expect(
        controller.errorMessage,
        '播放失败，正在重试...',
        reason: '前置：首次解析失败并进入 2s 自动重试',
      );

      // 让重试的解析成功：重试若丢掉入口代次就会起播。
      api.failSongUrlHashes.clear();
      await tester.pump(const Duration(seconds: 2));
      await pending;
      await tester.pump();

      expect(
        handler.playCallCount,
        0,
        reason: '自动重试必须沿用入口代次，不能捡回起播权',
      );
      expect(controller.isPlaying, isFalse);
      expect(controller.errorMessage, isNull);

      finish();
    });
  });

  group('打断结束的恢复判据', () {
    testWidgets('打断前在播 + 开了自动恢复 → 结束后恢复', (tester) async {
      await startPlaying(tester);
      await controller.setAutoResumeAfterInterruption(true);
      handler.playCallCount = 0;

      controller.handleInterruptionEvent(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await tester.pump();
      expect(controller.isPlaying, isFalse, reason: '打断开始应由我们自己暂停');

      controller.handleInterruptionEvent(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await tester.pump(const Duration(milliseconds: 600));

      expect(handler.playCallCount, 1, reason: '打断前在播，结束后应恢复');
      expect(controller.isPlaying, isTrue);

      finish();
    });

    testWidgets('用户主动暂停后再遇到打断 → 结束时不恢复（原 bug 的复现点）', (tester) async {
      await startPlaying(tester);
      await controller.setAutoResumeAfterInterruption(true);

      // 用户自己暂停。
      await controller.togglePlay();
      await tester.pump();
      expect(controller.isPlaying, isFalse);

      handler.playCallCount = 0;
      controller.handleInterruptionEvent(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      controller.handleInterruptionEvent(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(
        handler.playCallCount,
        0,
        reason: '打断前本来就没播，结束后不得自动开始播',
      );
      expect(controller.isPlaying, isFalse);

      finish();
    });

    testWidgets('打断期间在途的起播请求不得出声', (tester) async {
      controller.queue = [_song(1)];
      api.gate = Completer<void>();

      // 地址解析挂起中发起播放。
      final pending = controller.playSong(_song(1));
      await tester.pump();

      // 解析还没回来时来电。
      controller.handleInterruptionEvent(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await tester.pump();
      handler.playCallCount = 0;

      // 解析完成：这次起播已经没有授权。
      api.gate!.complete();
      await pending;
      await tester.pump();

      expect(
        handler.playCallCount,
        0,
        reason: '打断期间完成的在途请求不能自己把声音放出来',
      );
      expect(controller.isPlaying, isFalse);

      finish();
    });

    testWidgets('关闭「阻止打断」时打断开始会主动抢回播放', (tester) async {
      await startPlaying(tester);
      await controller.setAudioInterruptionEnabled(false);
      handler.playCallCount = 0;

      controller.handleInterruptionEvent(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      // 阻止打断模式下我们不主动暂停，但系统仍会把引擎停掉：这里模拟那一下。
      fakeAudioPlayer.emitPlaying(false);
      await tester.pump(const Duration(milliseconds: 400));

      expect(handler.playCallCount, 1, reason: '阻止打断模式下应主动恢复');

      finish();
    });

    testWidgets('打断结束事件漏发时，用户显式播放仍能出声（闩锁自愈）', (tester) async {
      await startPlaying(tester);

      // 只收到 begin，永远收不到 end（部分 ROM / 通话被打断的路径会漏发）。
      controller.handleInterruptionEvent(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await tester.pump();
      expect(controller.isPlaying, isFalse);

      handler.playCallCount = 0;
      await controller.togglePlay();
      await tester.pump();

      expect(
        handler.playCallCount,
        1,
        reason: '用户显式播放是比系统事件更强的意图，不能因为漏发 end 永久失效',
      );
      expect(controller.isPlaying, isTrue);

      finish();
    });

    testWidgets('duck 类打断不暂停（音量归响度服务）', (tester) async {
      await startPlaying(tester);
      handler.pauseCallCount = 0;

      controller.handleInterruptionEvent(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      await tester.pump();

      expect(handler.pauseCallCount, 0);
      expect(controller.isPlaying, isTrue);

      finish();
    });
  });

  group('切音质重载的起播守卫', () {
    testWidgets('重载期间断开连接：解析完成后不得把声音放回扬声器', (tester) async {
      await startPlaying(tester);
      api.gate = Completer<void>();

      final pending = controller.setAudioQuality(
        AudioQuality.high,
        reloadCurrent: true,
      );
      await tester.pump();
      // 重载还在解析时拔耳机/蓝牙断开。
      controller.handleBecomingNoisy();
      await tester.pump();
      handler.playCallCount = 0;

      api.gate!.complete();
      await pending;
      await tester.pump();

      expect(handler.playCallCount, 0, reason: '切音质不得绕过断连保护');
      expect(controller.isPlaying, isFalse);

      finish();
    });

    testWidgets('重载期间用户主动暂停：解析完成后不得擅自恢复', (tester) async {
      await startPlaying(tester);
      api.gate = Completer<void>();

      final pending = controller.setAudioQuality(
        AudioQuality.high,
        reloadCurrent: true,
      );
      await tester.pump();
      await controller.togglePlay();
      await tester.pump();
      handler.playCallCount = 0;

      api.gate!.complete();
      await pending;
      await tester.pump();

      expect(handler.playCallCount, 0, reason: '用户暂停必须作废在途的切音质起播');
      expect(controller.isPlaying, isFalse);

      finish();
    });
  });

  group('设置项默认值', () {
    test('断开停止播放默认开启，自动恢复默认关闭', () {
      expect(controller.autoPauseOnDeviceDisconnect, isTrue);
      expect(controller.autoResumeAfterInterruption, isFalse);
      finish();
    });

    testWidgets('设置值会持久化', (tester) async {
      await controller.setAutoPauseOnDeviceDisconnect(false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings.auto_pause_on_device_disconnect'), isFalse);
      finish();
    });
  });
}
