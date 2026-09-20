// 移动端桌面歌词：App 在前台（悬浮窗被原生隐藏）期间，歌词内容缓存必须继续
// 跟随播放推进，回桌面的 show 请求也要自带当前句。
//
// 伴奏/间奏期不会再有任何换句推送，若回桌面重建窗口只能靠“show 之后再补一次
// updateLyrics”，那一次补发一旦丢失（原生服务 stop/start 竞态），悬浮窗就会
// 一直空白到下一句才突然出现 —— 本文件锁定的就是这两条不变量：
//   1. 隐藏期间换句只写缓存（cacheLyrics，原生只缓存不建窗），绝不下发
//      updateLyrics/show（前台推送会把悬浮窗弹到应用之上）；
//   2. 回桌面的 show 请求携带最新一句歌词（窗口一建出来就有字）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  }) async {
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

Song _song() => Song(id: 'song_1', title: '歌曲', artist: '歌手', hash: 'hash_1');

List<LyricLine> _lyrics() => const [
  LyricLine(time: Duration.zero, text: '第一句'),
  LyricLine(time: Duration(seconds: 5), text: '第二句'),
  LyricLine(time: Duration(seconds: 10), text: '第三句'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('shiyin_music/desktop_lyrics');

  late _FakeAudioPlayer fakeAudioPlayer;
  late _FakeAudioHandler handler;
  late PlayerController controller;
  late List<MethodCall> calls;

  /// 排空平台通道往返（show/hide/updateLyrics 都是异步下发）。
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  MethodCall lastCall(String method) =>
      calls.lastWhere((c) => c.method == method);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 伪装移动端形态 + Android 平台：走 MethodChannel 分支（非桌面子窗桥接）。
    debugDesktopFormFactorOverride = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });

    fakeAudioPlayer = _FakeAudioPlayer();
    handler = _FakeAudioHandler(fakeAudioPlayer);
    controller = PlayerController(_MockMusicApi(), handler);
    controller.desktopLyricsEnabled = true;
    controller.currentSong = _song();
    controller.lyrics = _lyrics();
    controller.duration = const Duration(seconds: 30);
  });

  tearDown(() {
    controller.dispose();
    fakeAudioPlayer.disposeStreams();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    debugDesktopFormFactorOverride = null;
  });

  test('隐藏期间换句只更新主窗缓存：不发平台调用，但回桌面的 show 带上新句', () async {
    // App 切后台（悬浮窗该展示）：show 请求携带当前句。
    controller.setAppForeground(false);
    await settle();
    expect(lastCall('show').arguments['current'], '第一句');

    // 回到 App：原生隐藏悬浮窗，且必须是"临时隐藏"（保留原生侧缓存）。
    calls.clear();
    controller.setAppForeground(true);
    await settle();
    expect(lastCall('hide').arguments, {'transient': true});

    // App 在前台，播放推进到第三句：只更新缓存，绝不上屏推送。
    calls.clear();
    fakeAudioPlayer.emitPosition(const Duration(seconds: 12));
    await settle();
    expect(
      calls.map((c) => c.method).toList(),
      ['cacheLyrics'],
      reason: '前台换句只能写缓存：updateLyrics/show 会把悬浮窗建到应用之上',
    );
    expect(lastCall('cacheLyrics').arguments['current'], '第三句');

    // 回桌面：show 自带的必须是第三句（伴奏期没有换句推送兜底）。
    controller.setAppForeground(false);
    await settle();
    expect(lastCall('show').arguments['current'], '第三句');
    expect(lastCall('show').arguments['lyricPayload'], true);
  });

  test('切到无歌词的歌后回桌面：show 带空内容，不让原生画上一首的句子', () async {
    controller.setAppForeground(false);
    await settle();
    expect(lastCall('show').arguments['current'], '第一句');

    controller.setAppForeground(true);
    await settle();

    // 切歌且新歌无歌词：前台期间仅缓存清空。
    calls.clear();
    controller.lyrics = const [];
    controller.currentSong = Song(
      id: 'song_2',
      title: '纯音乐',
      artist: '歌手',
      hash: 'hash_2',
    );
    controller.setAppForeground(false);
    await settle();

    final show = lastCall('show');
    expect(show.arguments['current'], '');
    expect(show.arguments['next'], '');
    expect(show.arguments['lyricPayload'], true);
  });
}
