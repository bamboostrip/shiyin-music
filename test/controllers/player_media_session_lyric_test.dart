// 系统媒体会话歌词（LyricInfo）与手环/AVRCP 标题同步的控制器接线：
//   1. 位置流推进时按「行变化 / 歌词换新 / 恢复播放 / 切歌」推送当前行、
//      翻译、音译与整首 LRC；同一行重复 tick 不得重复重建 MediaItem；
//   2. 暂停 / 切歌 / 播放中无歌词时清空（幂等，不每 tick 重复 add）；
//   3. 系统歌词推送**不依赖**车载蓝牙歌词开关（通用系统能力）；
//   4. 手环标题同步 = 「车载蓝牙歌词 && 标题同步」的合成开关，切换后立即
//      补推当前行；关闭车载蓝牙歌词立即撤销标题覆盖；
//   5. 非 Android 平台短路（桌面 SMTC/MPRIS 无歌词消费方）。
//
// 测试用 Fake AudioPlayer + Fake MusicAudioHandler，禁止创建真实 AudioPlayer
// （参照 test/controllers/player_lyric_offset_test.dart 的模式）。
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

  void emitPosition(Duration value) => _positionController.add(value);

  void disposeStreams() {
    _positionController.close();
    _durationController.close();
    _playerStateController.close();
    _processingStateController.close();
    _androidAudioSessionIdController.close();
    _errorController.close();
  }
}

typedef _LyricMetadataCall = ({
  String? lyricText,
  String? translationText,
  String? romanizationText,
  String? fullLyricLrc,
});

class _RecordingAudioHandler extends Fake implements MusicAudioHandler {
  _RecordingAudioHandler(this._audioPlayer);

  final AudioPlayer _audioPlayer;

  /// updateLyricMetadata 的调用记录（null 字段 = 清空）。
  final List<_LyricMetadataCall> lyricCalls = <_LyricMetadataCall>[];

  /// setBluetoothLyricsTitleSync 的历史值（合成开关下发记录）。
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
  }) {
    lyricCalls.add((
      lyricText: lyricText,
      translationText: translationText,
      romanizationText: romanizationText,
      fullLyricLrc: fullLyricLrc,
    ));
  }

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

Song _song(int index) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手',
  hash: 'hash_$index',
);

const _lyrics = [
  LyricLine(
    time: Duration.zero,
    text: '第一句',
    translation: 'first line',
    romanization: 'dai yi ju',
  ),
  LyricLine(
    time: Duration(seconds: 5),
    text: '第二句',
    translation: 'second line',
  ),
  LyricLine(time: Duration(seconds: 10), text: '第三句'),
];

const _lyricsSong2 = [
  LyricLine(time: Duration.zero, text: '新歌第一句'),
  LyricLine(time: Duration(seconds: 5), text: '新歌第二句'),
];

const _fullLrc1 = '[00:00.00]第一句\n[00:05.00]第二句\n[00:10.00]第三句';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerController 系统媒体会话歌词同步', () {
    late _FakeAudioPlayer fakeAudioPlayer;
    late _RecordingAudioHandler handler;
    late PlayerController controller;

    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// 推进播放进度：位置流回调 → 平滑位置/歌词行落定 → 各歌词通道同步。
    Future<void> emitPosition(Duration value) async {
      fakeAudioPlayer.emitPosition(value);
      await settle();
    }

    /// 让当前歌进入「播放中 + 有歌词」的常规状态。
    void preparePlayingSong({Song? song, List<LyricLine> lyrics = _lyrics}) {
      controller.currentSong = song ?? _song(1);
      controller.lyrics = lyrics;
      controller.duration = const Duration(seconds: 30);
      controller.isPlaying = true;
    }

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // 移动端 + Android：系统歌词同步的平台门控生效。
      debugDesktopFormFactorOverride = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fakeAudioPlayer = _FakeAudioPlayer();
      handler = _RecordingAudioHandler(fakeAudioPlayer);
      controller = PlayerController(_MockMusicApi(), handler);
    });

    tearDown(() {
      controller.dispose();
      fakeAudioPlayer.disposeStreams();
      debugDefaultTargetPlatformOverride = null;
      debugDesktopFormFactorOverride = null;
    });

    test('蓝牙歌词关闭时也推送系统歌词（系统能力不依赖蓝牙开关）', () async {
      expect(controller.bluetoothLyricsEnabled, isFalse);
      preparePlayingSong();

      await emitPosition(Duration.zero);

      expect(handler.lyricCalls, hasLength(1));
      final call = handler.lyricCalls.single;
      expect(call.lyricText, '第一句');
      expect(call.translationText, 'first line');
      expect(call.romanizationText, 'dai yi ju');
      expect(call.fullLyricLrc, _fullLrc1, reason: '整首标准 LRC 随行推送');
    });

    test('同一行重复 tick 不重复推送（避免每 tick 重建 MediaItem）', () async {
      preparePlayingSong();
      await emitPosition(Duration.zero);
      await emitPosition(const Duration(seconds: 1));
      await emitPosition(const Duration(milliseconds: 2500));

      expect(handler.lyricCalls, hasLength(1), reason: '行未变化必须直接返回');
    });

    test('行变化推送新行（原文/翻译/音译/整首 LRC 一起刷新）', () async {
      preparePlayingSong();
      await emitPosition(Duration.zero);
      await emitPosition(const Duration(seconds: 5, milliseconds: 200));

      expect(handler.lyricCalls, hasLength(2));
      final call = handler.lyricCalls.last;
      expect(call.lyricText, '第二句');
      expect(call.translationText, 'second line');
      expect(call.romanizationText, isNull, reason: '该行无音译，不写空字段');
      expect(call.fullLyricLrc, _fullLrc1);
    });

    test('暂停清空一次；暂停期间重复 tick 不重复 add；恢复播放重推当前行', () async {
      preparePlayingSong();
      await emitPosition(Duration.zero);
      await emitPosition(const Duration(seconds: 5, milliseconds: 200));
      expect(handler.lyricCalls, hasLength(2));

      controller.isPlaying = false;
      await emitPosition(const Duration(seconds: 6));
      expect(handler.lyricCalls, hasLength(3));
      final cleared = handler.lyricCalls.last;
      expect(cleared.lyricText, isNull);
      expect(cleared.translationText, isNull);
      expect(cleared.romanizationText, isNull);
      expect(cleared.fullLyricLrc, isNull, reason: '暂停整组歌词字段一起清空');

      await emitPosition(const Duration(seconds: 7));
      expect(handler.lyricCalls, hasLength(3), reason: '已清空后暂停态不再重复 add');

      controller.isPlaying = true;
      await emitPosition(const Duration(seconds: 6, milliseconds: 100));
      expect(handler.lyricCalls, hasLength(4));
      expect(handler.lyricCalls.last.lyricText, '第二句', reason: '恢复播放重推当前行');
      expect(handler.lyricCalls.last.fullLyricLrc, _fullLrc1);
    });

    test('切歌先清空旧歌歌词，再推新歌当前行', () async {
      preparePlayingSong();
      await emitPosition(Duration.zero);
      expect(handler.lyricCalls, hasLength(1));

      controller.currentSong = _song(2);
      controller.lyrics = _lyricsSong2;
      await emitPosition(const Duration(milliseconds: 500));

      expect(handler.lyricCalls, hasLength(3));
      expect(handler.lyricCalls[1].lyricText, isNull, reason: '旧歌歌词必须先清空');
      expect(handler.lyricCalls[2].lyricText, '新歌第一句');
      expect(
        handler.lyricCalls[2].fullLyricLrc,
        '[00:00.00]新歌第一句\n[00:05.00]新歌第二句',
        reason: 'LRC 缓存随歌词列表换新',
      );
    });

    test('切到无歌词的歌：清空旧歌词且不再重复推送', () async {
      preparePlayingSong();
      await emitPosition(Duration.zero);
      expect(handler.lyricCalls, hasLength(1));

      controller.currentSong = _song(2);
      controller.lyrics = const [];
      await emitPosition(const Duration(milliseconds: 500));
      expect(handler.lyricCalls, hasLength(2));
      expect(handler.lyricCalls.last.lyricText, isNull);

      await emitPosition(const Duration(seconds: 2));
      expect(handler.lyricCalls, hasLength(2), reason: '无歌词不应每 tick 反复清空');
    });

    test('歌词列表换新（翻译/音译后到）会重推当前行', () async {
      preparePlayingSong();
      await emitPosition(Duration.zero);
      expect(handler.lyricCalls, hasLength(1));

      // 模拟缓存歌词先到、带翻译/音译的在线歌词后到：行号假设不变。
      controller.lyrics = const [
        LyricLine(
          time: Duration.zero,
          text: '第一句',
          translation: '在线翻译',
          romanization: 'zaixian',
        ),
        LyricLine(time: Duration(seconds: 5), text: '第二句'),
      ];
      await emitPosition(const Duration(seconds: 1));

      expect(handler.lyricCalls, hasLength(2));
      expect(handler.lyricCalls.last.lyricText, '第一句');
      expect(handler.lyricCalls.last.translationText, '在线翻译');
      expect(handler.lyricCalls.last.romanizationText, 'zaixian');
    });

    test('手环标题同步开启：下发合成开关（标题由 handler 用歌词快照即时重建）', () async {
      preparePlayingSong();
      await emitPosition(Duration.zero);
      expect(handler.lyricCalls, hasLength(1));

      await controller.setBluetoothLyricsEnabled(true);
      expect(handler.titleSyncStates, isEmpty, reason: '标题同步未开，合成开关不应下发');

      await controller.setBluetoothLyricsTitleSyncEnabled(true);
      expect(handler.titleSyncStates, [true]);
      expect(
        handler.lyricCalls,
        hasLength(1),
        reason: '标题重建在 handler 内部完成，控制器无需重复推歌词',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('settings.bluetooth_lyrics_title_sync_enabled'),
        isTrue,
      );
    });

    test('关闭车载蓝牙歌词立即撤销标题覆盖（开关隐藏后仍可关掉）', () async {
      preparePlayingSong();
      await emitPosition(Duration.zero);
      await controller.setBluetoothLyricsEnabled(true);
      await controller.setBluetoothLyricsTitleSyncEnabled(true);
      expect(handler.titleSyncStates, [true]);

      await controller.setBluetoothLyricsEnabled(false);

      expect(handler.titleSyncStates, [true, false]);
      expect(
        controller.bluetoothLyricsTitleSyncEnabled,
        isTrue,
        reason: '用户偏好保留，重新开启车载蓝牙歌词后自动恢复',
      );
      expect(
        handler.lyricCalls,
        hasLength(1),
        reason: '标题回落由 handler 按开关用快照重建，不重新推歌词',
      );
    });

    test('非 Android 平台短路：不推系统歌词（桌面 SMTC/MPRIS 无消费方）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      preparePlayingSong();

      await emitPosition(Duration.zero);

      expect(handler.lyricCalls, isEmpty);
    });

    test('无当前歌曲时不推送（系统媒体会话尚未建立）', () async {
      controller.lyrics = _lyrics;
      controller.isPlaying = true;
      await emitPosition(Duration.zero);

      expect(handler.lyricCalls, isEmpty);
    });
  });
}
