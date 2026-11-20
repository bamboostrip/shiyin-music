import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/local_music_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

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
    _errorController.close();
    _androidAudioSessionIdController.close();
  }
}

class _RecordingAudioHandler extends Fake implements MusicAudioHandler {
  _RecordingAudioHandler(this._audioPlayer);

  final _FakeAudioPlayer _audioPlayer;
  final List<String> loadedUrls = [];

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
  Future<void> seek(Duration position, [dynamic options]) async {}

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    loadedUrls.add(url);
  }

  @override
  Future<void> play({bool userInitiated = true}) async {}

  @override
  Future<void> pause({bool userInitiated = true}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

class _FakeMusicApi extends Fake implements MusicApi {
  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async => PlayUrl(url: '', hash: song.hash);
}

class _SpyLocalMusicController extends LocalMusicController {
  int scanCalls = 0;

  @override
  Future<void> scanLocalMusic() async {
    scanCalls++;
  }
}

Song _localSong(String path, {String? title}) => Song(
  id: path,
  title: title ?? path.split(RegExp(r'[/\\]')).last,
  artist: '未知艺人',
  hash: path,
  duration: const Duration(seconds: 30),
  source: SongSource.local,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAudioPlayer fakeAudioPlayer;
  late _RecordingAudioHandler handler;
  late PlayerController controller;
  late _SpyLocalMusicController localMusic;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeAudioPlayer = _FakeAudioPlayer();
    handler = _RecordingAudioHandler(fakeAudioPlayer);
    controller = PlayerController(_FakeMusicApi(), handler);
    localMusic = _SpyLocalMusicController();
    controller.localMusic = localMusic;
  });

  Future<void> pumpToastHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: Toast.navigatorKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pump();
  }

  /// 收尾：dispose 后把 Toast 的超时推完。
  ///
  /// **不能用 pumpAndSettle**：起播成功后位置保存的周期定时器每 tick 都会
  /// 触发重建，settle 永远等不到"没有待调度帧"，会一直跑到 10 分钟超时。
  Future<void> tearDownController(WidgetTester tester) async {
    controller.dispose();
    fakeAudioPlayer.disposeStreams();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('本地文件不存在：不交给引擎，给出可读原因并触发一次本地重扫', (tester) async {
    await pumpToastHost(tester);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final missing = '${Directory.systemTemp.path}/shiyin_missing_$stamp.mp3';
    final second = _localSong('${Directory.systemTemp.path}/shiyin_missing_${stamp}_2.mp3');
    final song = _localSong(missing);
    controller.queue = [song, second];

    await controller.playSong(song, isRetry: true);
    await tester.pump();

    // 关键：不再把不存在的文件交给引擎（旧实现会白等一轮引擎超时）
    expect(handler.loadedUrls, isEmpty);
    expect(controller.errorMessage, contains('本地文件已不存在'));
    expect(find.textContaining('本地文件已不存在'), findsOneWidget);
    expect(controller.lastPlaybackFailureToast, contains('本地文件已不存在'));
    expect(localMusic.scanCalls, 1);

    // 同一 streak 内第二首也缺失：重扫闸门已关，不重复扫
    await controller.playSong(second, isRetry: true);
    await tester.pump();
    expect(localMusic.scanCalls, 1);

    await tearDownController(tester);
  });

  testWidgets('内核不支持的格式：不交给引擎，提示点名格式', (tester) async {
    await pumpToastHost(tester);
    // 能力边界只在移动端显形（桌面 mpv 几乎全格式），这里显式钉住 Android。
    // 断言失败时也要走 finally 还原：foundation 的调试变量非空会被框架判为
    // 测试污染，反而盖掉真正的失败原因。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final song = _localSong('/storage/emulated/0/Music/整轨.ape');
      controller.queue = [song];

      await controller.playSong(song, isRetry: true);
      await tester.pump();

      expect(handler.loadedUrls, isEmpty);
      expect(controller.errorMessage, contains('.ape'));
      expect(find.text('《${song.title}》格式不受支持'), findsOneWidget);
      // 格式不支持与库内容无关，不该触发重扫
      expect(localMusic.scanCalls, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }

    await tearDownController(tester);
  });

  testWidgets('文件存在且格式支持：照常把文件路径交给引擎', (tester) async {
    await pumpToastHost(tester);
    final file = File(
      '${Directory.systemTemp.path}/shiyin_local_${DateTime.now().microsecondsSinceEpoch}.mp3',
    );
    // 必须同步写：testWidgets 跑在 FakeAsync 里，真实磁盘 IO 的 Future
    // 永远等不到完成（await 会挂到用例超时）。
    file.writeAsBytesSync(const [0, 1, 2, 3]);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    final song = _localSong(file.path);
    controller.queue = [song];

    await controller.playSong(song);
    await tester.pump();

    expect(handler.loadedUrls, [file.path]);
    expect(controller.errorMessage, isNull);

    await tearDownController(tester);
  });
}
