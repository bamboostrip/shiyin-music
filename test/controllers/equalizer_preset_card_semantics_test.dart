// 音效页卡片化的两条控制器语义：
//   1. applyEqualizerPreset 即点即响：无论此前 EQ 开关状态，应用预设后
//      EQ 自动开启并立即生效（卡片化主界面点预设卡必须听得见变化；
//      启动恢复不走这里，不受影响）；
//   2. disableAllAudioEffects 一键全关：EQ/低音/环绕三个开关同时关闭，
//      曲线与强度保留记忆（重新点任一效果卡即恢复）。
//
// fake api/audioHandler 搭建照搬 audio_effect_profile_apply_test.dart
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
  }) {
    return Future<PlayUrl>.value(PlayUrl(url: song.id, hash: song.hash));
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('applyEqualizerPreset 即点即开：EQ 自动开启并立即应用', () async {
    // 平台 override windows：桌面分支 _applyDesktopAudioFilters 在单测里
    // 无 MediaKitPlayer 登记（空表 no-op），不触达任何通道。
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

    // 构造函数 unawaited 发起 _restoreSettings：先等恢复落定（与
    // audio_effect_profile_apply_test 同款轮询）。
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.equalizerEnabled, isFalse);

    final preset = PlayerController.equalizerPresets
        .firstWhere((p) => p.name == '流行');
    await controller.applyEqualizerPreset(preset);

    expect(controller.equalizerEnabled, isTrue);
    expect(controller.equalizerPresetName, '流行');
    expect(controller.equalizerLevels, preset.levels);

    // 清理持久化，避免污染其它用例。
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  test('disableAllAudioEffects 三件全关且保留曲线与强度记忆', () async {
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

    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    // 先开一个档案：EQ/低音/环绕全开且带非零强度和档案曲线。
    final profile = PlayerController.audioEffectProfiles
        .firstWhere((p) => p.name == '全景环绕');
    await controller.applyAudioEffectProfile(profile);
    expect(controller.equalizerEnabled, isTrue);

    await controller.disableAllAudioEffects();

    expect(controller.equalizerEnabled, isFalse);
    expect(controller.bassBoostEnabled, isFalse);
    expect(controller.surroundEnabled, isFalse);
    // 记忆保留：曲线仍是档案曲线，强度未被清零（重开即恢复）。
    expect(controller.equalizerLevels, profile.eqLevels);
    expect(controller.bassBoostStrength, closeTo(0.3, 0.001));
    expect(controller.surroundStrength, closeTo(0.85, 0.001));

    // 全关后再点任一预设，EQ 自动恢复开启（卡片点选即生效闭环）。
    final flat = PlayerController.equalizerPresets.first;
    await controller.applyEqualizerPreset(flat);
    expect(controller.equalizerEnabled, isTrue);

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });
}
