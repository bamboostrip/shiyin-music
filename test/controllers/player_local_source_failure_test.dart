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
  String? contentUriForPathOverride;

  @override
  Future<void> scanLocalMusic() async {
    scanCalls++;
  }

  @override
  String? contentUriForPath(String path) => contentUriForPathOverride;
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
    // 存在性探测默认假实现：testWidgets 跑在 FakeAsync 里，真实磁盘 IO 的
    // Future 永远等不到完成（预检改异步 File.exists 后必须注入，与上面
    // writeAsBytesSync 的同步写同理）。默认判「不存在」，各用例按需覆盖。
    controller.localFileExistsProbe = (_) async => false;
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

  testWidgets('裸路径读不到但媒体库有 content:// 地址：回退直读，不再判死', (tester) async {
    await pumpToastHost(tester);
    final missing = '${Directory.systemTemp.path}/shiyin_nopath_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final song = Song(
      id: missing,
      title: '媒体库条目',
      artist: '未知艺人',
      hash: missing,
      duration: const Duration(seconds: 30),
      source: SongSource.local,
      localContentUri: 'content://media/external/audio/media/42',
    );
    controller.queue = [song];

    await controller.playSong(song);
    await tester.pump();

    // Android 10 的分区存储会拒绝按裸路径读媒体文件，此时必须回退
    // MediaStore 的 content:// 地址（由引擎直读，不进本地文件代理）。
    expect(handler.loadedUrls, ['content://media/external/audio/media/42']);
    expect(controller.errorMessage, isNull);
    // 该走直读，不该触发"文件缺失"重扫
    expect(localMusic.scanCalls, 0);

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
    // 本用例验证「存在即直读」：覆盖为真实磁盘真相（同步探测，绕开
    // FakeAsync 里永不完成的异步 IO），文件确实创建失败时仍会让用例变红。
    controller.localFileExistsProbe = (_) async => file.existsSync();

    await controller.playSong(song);
    await tester.pump();

    expect(handler.loadedUrls, [file.path]);
    expect(controller.errorMessage, isNull);

    await tearDownController(tester);
  });

  testWidgets('陈旧队列条目：localContentUri 为空但本地库里有地址 → 兜底直读', (tester) async {
    await pumpToastHost(tester);
    final missing =
        '${Directory.systemTemp.path}/shiyin_stale_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final song = _localSong(missing); // 无 localContentUri（升级前的旧记录）
    controller.queue = [song];
    localMusic.contentUriForPathOverride = 'content://media/external/audio/media/7';

    await controller.playSong(song);
    await tester.pump();

    expect(handler.loadedUrls, ['content://media/external/audio/media/7']);
    expect(controller.errorMessage, isNull);
    expect(localMusic.scanCalls, 1); // 仍触发一次重扫收敛库
    await tearDownController(tester);
  });

  testWidgets('本地库也没有地址：维持「文件已不存在」', (tester) async {
    await pumpToastHost(tester);
    final missing =
        '${Directory.systemTemp.path}/shiyin_none_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final song = _localSong(missing);
    controller.queue = [song];
    localMusic.contentUriForPathOverride = null;

    await controller.playSong(song);
    await tester.pump();

    expect(handler.loadedUrls, isEmpty);
    expect(controller.errorMessage, contains('本地文件已不存在'));
    await tearDownController(tester);
  });

  testWidgets('切音质重载本地歌：缺文件时不交给引擎，落可读错误', (tester) async {
    await pumpToastHost(tester);
    final missing =
        '${Directory.systemTemp.path}/shiyin_q_${DateTime.now().microsecondsSinceEpoch}.mp3';
    controller.queue = [_localSong(missing)];
    controller.currentSong = _localSong(missing);

    await controller.setAudioQuality(
      AudioQuality.lossless,
      reloadCurrent: true,
    );
    await tester.pump();

    expect(handler.loadedUrls, isEmpty);
    expect(controller.errorMessage, contains('本地文件已不存在'));
    await tearDownController(tester);
  });

  testWidgets('预检探测挂起期间已切歌：旧流程不得 loadSong 抢引擎', (tester) async {
    await pumpToastHost(tester);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File('${Directory.systemTemp.path}/shiyin_probe_$stamp.mp3');
    file.writeAsBytesSync(const [0, 1, 2, 3]);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    final songA = _localSong(file.path, title: '歌A');
    final songB =
        _localSong('${Directory.systemTemp.path}/shiyin_probe_${stamp}_b.mp3');
    controller.queue = [songA, songB];

    // 探测门闩：A 的存在性探测（本地歌存在性探测可秒级挂起，如 NAS 失联）
    // 用 Completer 控制完成时机，制造「探测在途期间切歌」的竞态窗口。
    final probeGate = Completer<bool>();
    controller.localFileExistsProbe = (_) => probeGate.future;

    final playFuture = controller.playSong(songA);
    await tester.pump();

    // A 的探测仍在途时 currentSong 已被 B 覆盖（B 尚未走 playSong 加载）。
    controller.currentSong = songB;
    probeGate.complete(true);
    await tester.pump();
    await playFuture;
    await tester.pump();

    // A 的预检返回后必须就地丢弃：不得 loadSong 抢走 B 的引擎与媒体会话
    // （B 未经 playSong，这里不应有任何 URL 被加载）。
    expect(handler.loadedUrls, isEmpty);

    await tearDownController(tester);
  });
}
