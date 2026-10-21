// applyAudioEffectProfile 的核心语义（issue #1 音效档案）：
//   1. EQ/低音/环绕一次性落到位：档案的四项状态同时成为控制器状态，
//      不存在"应用了一半"的中间态；
//   2. 预设名置为档案名：后续用户微调 EQ 走既有「自定义」路径前，
//      均衡器页展示的是档案名而非上一次的预设；
//   3. EQ 曲线按 10 段标准倍频程定义，设备为 fallback 10 段配置时
//      直接命中，levelsForBandCount 输出与档案曲线一致。
//
// fake api/audioHandler 搭建照搬 loudness_neutral_reset_test.dart
// （_FakeAudioPlayer/_RecordingAudioHandler/_MockMusicApi）。
import 'dart:async';

import 'package:flutter/foundation.dart';
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
  }

  @override
  Future<void> pause() async {
    callLogs.add('pause');
  }

  @override
  Future<void> stop() async {
    callLogs.add('stop');
  }

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('applyAudioEffectProfile 一次性落 EQ/低音/环绕并置自定义前预设名', () async {
    // 桌面分支锁定：windows 下 isSurroundSupported 为 true，apply 走桌面
    // 分支 _applyDesktopAudioFilters；单测没有 MediaKitPlayer 登记（实例
    // 登记表为空），自然 no-op 不触达任何通道；与 loudness_neutral_reset_test
    // 同款平台 override，并在测试体内复位（plain test 无 fake_async 兜底）。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final fakeAudioPlayer = _FakeAudioPlayer();
    final handler = _RecordingAudioHandler(fakeAudioPlayer);
    final api = _MockMusicApi();
    final controller = PlayerController(api, handler);
    addTearDown(() {
      controller.dispose();
      fakeAudioPlayer.disposeStreams();
    });

    // 构造函数 unawaited 发起 _restoreSettings：先等恢复落定再应用档案，
    // 否则恢复与应用两条 SharedPreferences 读写链会交错，EQ 等级可能被
    // 恢复流程的默认值拷贝覆盖（与 loudness 测试先轮询等恢复完成同理）。
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    final profile = PlayerController.audioEffectProfiles
        .firstWhere((p) => p.name == '全景环绕');
    await controller.applyAudioEffectProfile(profile);

    expect(controller.equalizerEnabled, isTrue);
    expect(controller.equalizerPresetName, '全景环绕');
    // 10 段标准曲线直接命中 fallback 配置的 10 段。
    expect(controller.equalizerLevels, profile.eqLevels);
    expect(controller.bassBoostEnabled, isTrue);
    expect(controller.bassBoostStrength, closeTo(0.3, 0.001));
    expect(controller.surroundEnabled, isTrue);
    // 曲线调优后全景环绕环绕强度 0.8→0.85。
    expect(controller.surroundStrength, closeTo(0.85, 0.001));

    // 清理持久化，避免污染其它用例。
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  test('档案清零强度后开启开关回退字段默认强度，非零强度不被改动', () async {
    // 桌面分支锁定机制同上：空登记表 no-op，不触达通道。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final fakeAudioPlayer = _FakeAudioPlayer();
    final handler = _RecordingAudioHandler(fakeAudioPlayer);
    final api = _MockMusicApi();
    final controller = PlayerController(api, handler);
    addTearDown(() {
      controller.dispose();
      fakeAudioPlayer.disposeStreams();
    });

    // 等构造函数 unawaited 的 _restoreSettings 落定（同上）。
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    // 纯净人声档案不启用低音/环绕且强度为 0：此后直接打开开关若不回退
    // 默认强度，会是开着却 0% 的死控件（须拖滑条才生效）。
    final profile = PlayerController.audioEffectProfiles
        .firstWhere((p) => p.name == '纯净人声');
    await controller.applyAudioEffectProfile(profile);
    expect(controller.bassBoostEnabled, isFalse);
    expect(controller.bassBoostStrength, closeTo(0, 0.001));
    expect(controller.surroundEnabled, isFalse);
    expect(controller.surroundStrength, closeTo(0, 0.001));

    await controller.setSurroundEnabled(true);
    await controller.setBassBoostEnabled(true);
    expect(controller.surroundStrength, closeTo(0.6, 0.001));
    expect(controller.bassBoostStrength, closeTo(0.45, 0.001));

    // 非零强度时开关往返不动用户强度：全景环绕的 0.85 关再开仍在。
    final surroundProfile = PlayerController.audioEffectProfiles
        .firstWhere((p) => p.name == '全景环绕');
    await controller.applyAudioEffectProfile(surroundProfile);
    await controller.setSurroundEnabled(false);
    await controller.setSurroundEnabled(true);
    expect(controller.surroundStrength, closeTo(0.85, 0.001));

    // 清理持久化，避免污染其它用例。
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });
}
