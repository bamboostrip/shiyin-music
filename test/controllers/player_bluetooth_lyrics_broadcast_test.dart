// 车载蓝牙歌词广播（issue #22）的控制器接线：
//   1. 行变化广播携带当前行与整首 LRC（fullLyric），车机端按 position 自行
//      滚动高亮需要全量时间轴；只发单行纯文本时车机端滚不动且易解析乱码；
//   2. 同一歌词行内按 [_kBluetoothLyricHeartbeat] 节流补发位置心跳，
//      position 随进度推进；暂停/无歌词时不发；
//   3. 切歌清零蓝牙行缓存：新歌首句广播不得被上一首的索引 dedup 吞掉。
//
// 测试用 Fake AudioPlayer + Fake MusicAudioHandler + Mock MethodChannel，
// 禁止创建真实 AudioPlayer（参照 player_media_session_lyric_test.dart）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/bluetooth_lyrics_service.dart';
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

class _RecordingAudioHandler extends Fake implements MusicAudioHandler {
  _RecordingAudioHandler(this._audioPlayer);

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
  void setBluetoothLyricsTitleSync(bool enabled) {}

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
  Future<List<LyricLine>> lyrics(Song song) async {
    if (song.hash == 'hash_2') return _lyricsSong2;
    return _lyrics;
  }
}

const _btChannel = MethodChannel('shiyin_music/bluetooth_lyrics');

Song _song(int index) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手',
  hash: 'hash_$index',
);

const _lyrics = [
  LyricLine(time: Duration.zero, text: '第一句'),
  LyricLine(time: Duration(seconds: 5), text: '第二句'),
  LyricLine(time: Duration(seconds: 10), text: '第三句'),
];

const _lyricsSong2 = [
  LyricLine(time: Duration.zero, text: '新歌第一句'),
  LyricLine(time: Duration(seconds: 5), text: '新歌第二句'),
];

const _fullLrc1 = '[00:00.00]第一句\n[00:05.00]第二句\n[00:10.00]第三句';

/// 一次蓝牙广播调用的可断言视图。
class _BtCall {
  _BtCall(this.call);

  final MethodCall call;

  bool get isMetaChanged => call.method == 'broadcastMetaChanged';

  Map<dynamic, dynamic> get args => call.arguments as Map<dynamic, dynamic>;

  String get lyric => args['lyric'] as String;

  String? get fullLyric => args['fullLyric'] as String?;

  int get positionMs => args['positionMs'] as int;

  bool get playing => args['playing'] as bool;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerController 车载蓝牙歌词广播', () {
    late _FakeAudioPlayer fakeAudioPlayer;
    late _RecordingAudioHandler handler;
    late _MockMusicApi api;
    late PlayerController controller;

    final btCalls = <_BtCall>[];

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

    List<_BtCall> metas() => btCalls.where((c) => c.isMetaChanged).toList();

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      debugDesktopFormFactorOverride = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // 广播记录是 group 级共享 list，必须逐用例清空，否则上一个用例的
      // 广播会串进下一个用例的断言（隔离性问题，不是产品行为）。
      btCalls.clear();
      fakeAudioPlayer = _FakeAudioPlayer();
      handler = _RecordingAudioHandler(fakeAudioPlayer);
      api = _MockMusicApi();
      controller = PlayerController(api, handler);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_btChannel, (call) async {
        btCalls.add(_BtCall(call));
        return null;
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_btChannel, null);
      await settle();
      controller.dispose();
      fakeAudioPlayer.disposeStreams();
      debugDefaultTargetPlatformOverride = null;
      debugDesktopFormFactorOverride = null;
    });

    test('行变化广播携带当前行与整首 LRC，position 为当前位置', () async {
      preparePlayingSong();
      await controller.setBluetoothLyricsEnabled(true);
      await emitPosition(const Duration(seconds: 5, milliseconds: 200));

      final calls = metas();
      expect(calls, hasLength(2), reason: '开关 force 首行 + 换行各一条');
      expect(calls.first.lyric, '第一句');
      expect(calls.first.fullLyric, _fullLrc1);
      expect(calls.last.lyric, '第二句');
      expect(calls.last.fullLyric, _fullLrc1, reason: '整首 LRC 随行刷新');
      expect(calls.last.positionMs, 5200);
      expect(calls.last.playing, isTrue);
    });

    test('同一行内按节流窗口补发位置心跳，position 随进度前进', () async {
      preparePlayingSong();
      var fakeNow = DateTime(2026, 1, 1, 12);
      controller.bluetoothLyricNow = () => fakeNow;

      await controller.setBluetoothLyricsEnabled(true);
      expect(metas(), hasLength(1), reason: '开关 force 首行');

      // 同一行内、节流窗口内：不得重复广播。
      fakeNow = fakeNow.add(const Duration(milliseconds: 500));
      await emitPosition(const Duration(milliseconds: 200));
      expect(metas(), hasLength(1), reason: '行内心跳被节流');

      // 跨过节流窗口：补发心跳，带前进的 position 与整首 LRC。
      fakeNow = fakeNow.add(const Duration(milliseconds: 700));
      await emitPosition(const Duration(milliseconds: 300));
      expect(metas(), hasLength(2), reason: '节流窗口到期补发心跳');
      expect(metas().last.lyric, '第一句', reason: '心跳仍在同一行');
      expect(metas().last.positionMs, 300, reason: '心跳携带实时进度');
      expect(metas().last.fullLyric, _fullLrc1);
      expect(metas().last.playing, isTrue);
    });

    test('暂停不发歌词广播与心跳，恢复播放后心跳补推当前行', () async {
      preparePlayingSong();
      var fakeNow = DateTime(2026, 1, 1, 12);
      controller.bluetoothLyricNow = () => fakeNow;

      await controller.setBluetoothLyricsEnabled(true);
      fakeNow = fakeNow.add(const Duration(milliseconds: 1100));
      await emitPosition(const Duration(seconds: 5, milliseconds: 200));
      expect(metas(), hasLength(2), reason: '开关首行 + 换行');

      // 暂停：行未变 → 只发播放态广播，不重发歌词行。
      controller.isPlaying = false;
      fakeNow = fakeNow.add(const Duration(milliseconds: 1100));
      await emitPosition(const Duration(seconds: 6));
      expect(metas(), hasLength(2), reason: '暂停不重发歌词行');
      expect(
        btCalls.where((c) => c.call.method == 'broadcastPlayStateChanged'),
        hasLength(1),
        reason: '暂停必须发一次播放态广播（同时刻的 metachanged 不重复）',
      );

      fakeNow = fakeNow.add(const Duration(seconds: 2));
      await emitPosition(const Duration(seconds: 7));
      expect(metas(), hasLength(2), reason: '暂停期间心跳不得发送');

      // 恢复播放：心跳窗口已过，补推当前行让车机端重新对齐。
      controller.isPlaying = true;
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      await emitPosition(const Duration(seconds: 6, milliseconds: 100));
      expect(metas(), hasLength(3), reason: '恢复播放后心跳补推当前行');
      expect(metas().last.lyric, '第二句');
      expect(metas().last.fullLyric, _fullLrc1);
    });

    test('无歌词时不发心跳，空行广播只在开关/切歌边界发出', () async {
      preparePlayingSong(lyrics: const []);
      await controller.setBluetoothLyricsEnabled(true);
      expect(metas(), hasLength(1), reason: '开关 force 广播一次空行');

      await emitPosition(const Duration(seconds: 1));
      await emitPosition(const Duration(seconds: 2));
      expect(metas(), hasLength(1), reason: '无歌词不得每 tick 刷广播');
    });

    test('切歌清零蓝牙行缓存：新歌首句广播不被上一首索引吞掉', () async {
      preparePlayingSong(song: _song(1));
      await controller.setBluetoothLyricsEnabled(true);
      await emitPosition(Duration.zero);
      expect(metas(), hasLength(1));
      expect(metas().last.lyric, '第一句');

      // 切到第二首：playSong 同步清零蓝牙行缓存，loadLyrics 异步换新歌词。
      await controller.playSong(_song(2), queue: [_song(2)]);
      await emitPosition(const Duration(milliseconds: 300));
      await emitPosition(Duration.zero);

      final last = metas().last;
      expect(last.lyric, '新歌第一句', reason: '新歌首句必须广播出来');
      expect(
        last.fullLyric,
        '[00:00.00]新歌第一句\n[00:05.00]新歌第二句',
        reason: '新歌整首 LRC 一起下发',
      );
    });
  });

  group('BluetoothLyricsService 整首 LRC 长度保护', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_btChannel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_btChannel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    Future<void> send(String? fullLyric) => BluetoothLyricsService()
        .broadcastMetaChanged(
          title: '歌名',
          artist: '歌手',
          lyric: '当前行',
          fullLyric: fullLyric,
          position: const Duration(seconds: 3),
          duration: const Duration(seconds: 30),
          playing: true,
          trackIndex: 0,
          listSize: 1,
        );

    test('常规长度整首 LRC 照常下发', () async {
      await send(_fullLrc1);

      expect(calls, hasLength(1));
      expect(calls.single.arguments['fullLyric'], _fullLrc1);
    });

    test('超过上限时省略整首 LRC（截断即乱码，宁可退回只发当前行）', () async {
      final huge = 'x' * (BluetoothLyricsService.maxFullLyricChars + 1);
      await send(huge);

      expect(calls, hasLength(1));
      expect(
        calls.single.arguments['fullLyric'],
        '',
        reason: '超长不下发，原生层据空串省略该字段',
      );
      expect(calls.single.arguments['lyric'], '当前行', reason: '当前行仍照常广播');
    });

    test('恰好等于上限仍下发（边界包含）', () async {
      final edge = 'y' * BluetoothLyricsService.maxFullLyricChars;
      await send(edge);

      expect(calls.single.arguments['fullLyric'], edge);
    });

    test('未提供整首 LRC 时传空串（兼容旧调用方）', () async {
      await send(null);

      expect(calls.single.arguments['fullLyric'], '');
    });
  });
}
