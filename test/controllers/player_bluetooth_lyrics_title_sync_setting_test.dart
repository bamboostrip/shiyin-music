// 手环/AVRCP 歌词标题同步设置（上游 3.3.0 #134）的持久化链路：
//   1. 默认关闭：无持久化值时字段为 false，且不打扰 handler；
//   2. 启动恢复：两项都开启时把「车载蓝牙歌词 && 标题同步」合成开关下发；
//      只开了标题同步（车载蓝牙歌词关着）时保留偏好但不生效；
//   3. 落盘 + 通知 + 同值幂等；
//   4. 关闭车载蓝牙歌词立即撤销标题覆盖，重新打开后偏好自动恢复。
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

class _RecordingAudioHandler extends Fake implements MusicAudioHandler {
  _RecordingAudioHandler(this._audioPlayer);

  final AudioPlayer _audioPlayer;

  /// setBluetoothLyricsTitleSync 的下发历史（合成开关）。
  final List<bool> titleSyncStates = <bool>[];

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
  void setBluetoothLyricsTitleSync(bool enabled) {
    titleSyncStates.add(enabled);
  }

  @override
  void updateLyricMetadata({
    String? lyricText,
    String? translationText,
    String? romanizationText,
    String? fullLyricLrc,
  }) {}

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

const _bluetoothLyricsPrefsKey = 'settings.bluetooth_lyrics_enabled';
const _titleSyncPrefsKey = 'settings.bluetooth_lyrics_title_sync_enabled';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerController 手环/AVRCP 歌词标题同步设置', () {
    late _FakeAudioPlayer fakeAudioPlayer;
    late _RecordingAudioHandler handler;
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
      handler = _RecordingAudioHandler(fakeAudioPlayer);
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

    test('默认关闭：无持久化值时字段 false 且不向 handler 下发', () async {
      final controller = buildController();
      await settle();

      expect(controller.bluetoothLyricsTitleSyncEnabled, isFalse);
      expect(handler.titleSyncStates, isEmpty);
    });

    test('启动恢复：车载蓝牙歌词+标题同步都开启时下发合成开关 true', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _bluetoothLyricsPrefsKey: true,
        _titleSyncPrefsKey: true,
      });
      final controller = buildController();
      await settle();

      expect(controller.bluetoothLyricsEnabled, isTrue);
      expect(controller.bluetoothLyricsTitleSyncEnabled, isTrue);
      expect(handler.titleSyncStates, [true]);
    });

    test('启动恢复：车载蓝牙歌词关闭时保留偏好但不下发（合成开关为假）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _bluetoothLyricsPrefsKey: false,
        _titleSyncPrefsKey: true,
      });
      final controller = buildController();
      await settle();

      expect(controller.bluetoothLyricsTitleSyncEnabled, isTrue);
      expect(handler.titleSyncStates, isEmpty);
    });

    test('开关落盘并 notifyListeners，同值设置幂等', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _bluetoothLyricsPrefsKey: true,
      });
      final controller = buildController();
      await settle();

      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setBluetoothLyricsTitleSyncEnabled(true);
      final prefs = await SharedPreferences.getInstance();
      expect(controller.bluetoothLyricsTitleSyncEnabled, isTrue);
      expect(prefs.getBool(_titleSyncPrefsKey), isTrue);
      expect(handler.titleSyncStates, [true]);
      expect(notifications, 1);

      // 同值：不重复落盘/通知/下发。
      await controller.setBluetoothLyricsTitleSyncEnabled(true);
      expect(notifications, 1);
      expect(handler.titleSyncStates, [true]);

      await controller.setBluetoothLyricsTitleSyncEnabled(false);
      expect(prefs.getBool(_titleSyncPrefsKey), isFalse);
      expect(handler.titleSyncStates, [true, false]);
      expect(notifications, 2);
    });

    test('关闭车载蓝牙歌词撤销标题覆盖，重新打开后用户偏好自动恢复', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _bluetoothLyricsPrefsKey: true,
        _titleSyncPrefsKey: true,
      });
      final controller = buildController();
      await settle();
      expect(handler.titleSyncStates, [true]);

      await controller.setBluetoothLyricsEnabled(false);
      expect(handler.titleSyncStates, [true, false]);
      expect(controller.bluetoothLyricsTitleSyncEnabled, isTrue);

      await controller.setBluetoothLyricsEnabled(true);
      expect(handler.titleSyncStates, [true, false, true]);
    });
  });
}
