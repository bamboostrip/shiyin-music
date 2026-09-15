// 响度均衡切歌缓存未命中的增益中性化（回归：新歌增益未知时不得残留
// 上一首的增益）。hashA 缓存命中 instant 应用 -6dB（引擎音量 ≈0.5），
// 切到无缓存的 hashB 时必须先渐变回用户音量（≈1.0），等真实分析出来
// 再渐变到目标——期间不携带旧增益播放。
//
// hashB 的分析用 RustLib.initMock 挂起（不发事件也不关流），模拟 PC
// 网络源下载/流式分析需要数秒的窗口：若修复缺失，旧增益会在整个窗口
// 内残留（本测试随即失败）；分析瞬间失败返回 null 的路径无法区分修复
// 前后（null 分支也会重置），故必须挂起。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';
import 'package:shiyin_music/src/rust/api.dart' as rust;
import 'package:shiyin_music/src/rust/frb_generated.dart';

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();
  final _errorController = StreamController<PlayerException>.broadcast();
  final _androidAudioSessionIdController = StreamController<int?>.broadcast();

  /// 记录所有 setVolume 调用值，用于断言 instant 应用与 250ms 渐变序列。
  final volumes = <double>[];
  double _volume = 1.0;

  bool _playing = false;
  ProcessingState _processingState = ProcessingState.idle;

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
  double get volume => _volume;

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    volumes.add(volume);
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Duration get position => Duration.zero;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => _processingState;

  @override
  int? get androidAudioSessionId => null;

  void setProcessingState(ProcessingState state) {
    _processingState = state;
    _processingStateController.add(state);
  }

  void emitPlaying(bool playing) {
    _playing = playing;
    _playerStateController.add(PlayerState(playing, _processingState));
  }

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

  final _FakeAudioPlayer _audioPlayer;
  final List<String> callLogs = [];

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
  Future<void> seek(Duration position, [dynamic options]) async {
    callLogs.add('seek:${position.inSeconds}');
  }

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    callLogs.add('loadSong:${song.hash}');
  }

  @override
  Future<void> play() async {
    callLogs.add('play');
    _audioPlayer.emitPlaying(true);
  }

  @override
  Future<void> pause() async {
    callLogs.add('pause');
    _audioPlayer.emitPlaying(false);
  }

  @override
  Future<void> stop() async {
    callLogs.add('stop');
    _audioPlayer.emitPlaying(false);
  }

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {
  // 本地源歌曲不走 songUrl（url = song.id），songClimax/lyrics 兜底为空。
  @override
  Future<SongClimax?> songClimax(String hash) async => null;

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    return PlayUrl(url: song.id, hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

/// RustLib mock：响度分析流挂起（既不发事件也不关流），模拟 PC 网络源
/// "分析仍在途"的窗口。取消不终结本次分析（真实 Rust 取消会让流关闭，
/// 但那会让 analyzeAndComputeGain 立刻返回 null，测不出残留窗口）。
class _HangingLoudnessRustApi extends Fake implements RustLibApi {
  final StreamController<rust.LoudnessEvent> _analysis =
      StreamController<rust.LoudnessEvent>();

  int analyzeCallCount = 0;

  @override
  Stream<rust.LoudnessEvent> crateApiAnalyzeLoudness({required String url}) {
    analyzeCallCount++;
    return _analysis.stream;
  }

  @override
  Future<void> crateApiCancelLoudnessAnalysis() async {}

  /// 收尾：关流 → onDone → _analyzeViaRust 按被取消返回 null。
  Future<void> resolveAsCancelled() => _analysis.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('切歌缓存未命中时旧响度增益先中性化（渐变回用户音量），不残留到新歌开头', (tester) async {
    // 桌面（mpv 后端）分支语义：衰减/中性化都走 setVolume 渐变。
    // testWidgets 的不变量校验要求 override 在测试体返回前复位，
    // 用 try/finally 包裹（与 settings_desktop_gate_test 同款做法）。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      // hashB 的分析挂起在途，模拟 PC 网络源分析窗口。
      final rustApi = _HangingLoudnessRustApi();
      RustLib.initMock(api: rustApi);

      // 本地文件源歌曲（id = 文件路径）绕过 _resolvePlayUrl；Fake 引擎不会真解码。
      final tmpDir = Directory.systemTemp.createTempSync('loudness_neutral');
      addTearDown(() {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final audioFile = File('${tmpDir.path}${Platform.pathSeparator}fake.mp3');
      audioFile.writeAsStringSync('not really audio');

      // hashA 实测 LUFS=-8 → 增益 = -14-(-8) = -6dB → 引擎音量 ≈0.5。
      // hashB 无缓存 → 切过去时增益未知，必须先中性化。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'loudness_enabled': true,
        'loudness_cache': '{"hashA": -8.0}',
      });

      final fakeAudioPlayer = _FakeAudioPlayer();
      final handler = _RecordingAudioHandler(fakeAudioPlayer);
      final api = _MockMusicApi();
      final controller = PlayerController(api, handler);

      // 构造函数 unawaited 发起 _loudness.init()：轮询直到开关从
      // SharedPreferences 恢复完成，避免 playSong 时缓存查询早于 init。
      for (var i = 0; i < 50 && !controller.loudnessEnabled; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(controller.loudnessEnabled, isTrue, reason: '响度开关应已从持久化恢复');

      final songA = Song(
        id: audioFile.path,
        title: '歌曲A',
        artist: '歌手A',
        hash: 'hashA',
        source: SongSource.local,
      );
      final songB = Song(
        id: audioFile.path,
        title: '歌曲B',
        artist: '歌手B',
        hash: 'hashB',
        source: SongSource.local,
      );
      controller.queue = [songA, songB];

      // 1) hashA 缓存命中：instant 应用 -6dB 衰减（引擎音量 ≈0.5）。
      await controller.playSong(songA);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        fakeAudioPlayer.volumes.last,
        closeTo(0.5012, 0.01),
        reason: 'hashA 缓存命中(-6dB)应把引擎音量衰减到约 0.5',
      );
      expect(rustApi.analyzeCallCount, 0, reason: 'hashA 缓存命中不应触发原生分析');

      // 2) 切到 hashB（缓存未命中）：旧增益先中性化，250ms 渐变回用户音量。
      //    分析挂起在途（窗口内不得有任何来自分析的增益修正）。
      final volumeCountBeforeReset = fakeAudioPlayer.volumes.length;
      await controller.playSong(songB);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 50));

      expect(rustApi.analyzeCallCount, 1, reason: 'hashB 缓存未命中应触发原生分析');
      expect(
        fakeAudioPlayer.volumes.last,
        closeTo(1.0, 0.01),
        reason: '缓存未命中应中性化旧增益，渐变回用户音量 1.0（分析在途时不得残留 -6dB）',
      );

      // 对照断言：重置确实走了渐变（而非未发生或直设）——新增的调用里
      // 应存在从 0.5 附近向 1.0 爬升的 ramp 中间值。
      final rampVolumes = fakeAudioPlayer.volumes.sublist(
        volumeCountBeforeReset,
      );
      expect(rampVolumes, isNotEmpty, reason: '中性化应产生 setVolume 调用');
      expect(
        rampVolumes.first,
        allOf(lessThan(1.0), greaterThan(0.5)),
        reason: 'ramp 应从 0.5 附近起步',
      );
      expect(
        rampVolumes.any((v) => v > 0.55 && v < 0.95),
        isTrue,
        reason: '应存在 0.5→1.0 的渐变中间值，证明走的是 ramp 而非直设',
      );
      expect(rampVolumes.last, greaterThan(rampVolumes.first));

      // 收尾：终结挂起的分析（关流 → 按被取消返回 null，此时 _pendingGainDb
      // 已为 null，null 分支 no-op），再释放控制器。
      await rustApi.resolveAsCancelled();
      await tester.pump(const Duration(milliseconds: 50));

      // dispose 必须在测试体内完成（addTearDown 晚于 fake_async 的
      // pending-timer 不变量校验，会留下听歌时长统计的周期定时器）。
      controller.dispose();
      fakeAudioPlayer.disposeStreams();
      await tester.pump(const Duration(milliseconds: 50));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
