// 歌词页切歌键设置（issue #3）的持久化链路：
//   1. 默认关：无持久化值时保持 QQ 原版底栏；
//   2. 启动恢复：prefs 为 true 时 _restoreSettings 后开关为 true；
//   3. 落盘 + 通知：set 后写 prefs 并 notifyListeners，同值幂等。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';
import 'package:shiyin_music/ui/form_factor.dart';

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
  double get volume => 1.0;

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

class _FakeAudioHandler extends Fake implements MusicAudioHandler {
  _FakeAudioHandler(this._audioPlayer);

  final AudioPlayer _audioPlayer;

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
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {}

  @override
  Future<void> seek(Duration position, [dynamic options]) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {}

const _skipButtonsPrefsKey = 'settings.lyric_page_skip_buttons';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerController 歌词页切歌键设置', () {
    late _FakeAudioPlayer fakeAudioPlayer;
    late _FakeAudioHandler handler;
    late List<PlayerController> controllers;

    PlayerController buildController() {
      final controller = PlayerController(_MockMusicApi(), handler);
      controllers.add(controller);
      return controller;
    }

    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      debugDesktopFormFactorOverride = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fakeAudioPlayer = _FakeAudioPlayer();
      handler = _FakeAudioHandler(fakeAudioPlayer);
      controllers = <PlayerController>[];
    });

    tearDown(() {
      for (final controller in controllers) {
        controller.dispose();
      }
      fakeAudioPlayer.disposeStreams();
      debugDefaultTargetPlatformOverride = null;
      debugDesktopFormFactorOverride = null;
    });

    test('默认关闭：无持久化值时保持 false（QQ 原版底栏）', () async {
      final controller = buildController();
      await settle();

      expect(controller.lyricPageSkipButtonsEnabled, isFalse);
    });

    test('启动恢复：prefs 为 true 时 restore 结束后开关为 true', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _skipButtonsPrefsKey: true,
      });
      final controller = buildController();
      await settle();

      expect(controller.lyricPageSkipButtonsEnabled, isTrue);
    });

    test('开关落盘并 notifyListeners，同值设置幂等', () async {
      final controller = buildController();
      await settle();

      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setLyricPageSkipButtonsEnabled(true);
      final prefs = await SharedPreferences.getInstance();
      expect(controller.lyricPageSkipButtonsEnabled, isTrue);
      expect(prefs.getBool(_skipButtonsPrefsKey), isTrue);
      expect(notifications, 1);

      // 重复设置同值：不重复落盘也不重复通知。
      await controller.setLyricPageSkipButtonsEnabled(true);
      expect(notifications, 1);

      await controller.setLyricPageSkipButtonsEnabled(false);
      expect(controller.lyricPageSkipButtonsEnabled, isFalse);
      expect(prefs.getBool(_skipButtonsPrefsKey), isFalse);
      expect(notifications, 2);
    });
  });
}
