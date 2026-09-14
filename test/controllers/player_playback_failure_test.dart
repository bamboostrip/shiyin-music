import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  bool _playing = false;
  final ProcessingState _processingState = ProcessingState.idle;

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
  bool get playing => _playing;

  @override
  ProcessingState get processingState => _processingState;

  @override
  int? get androidAudioSessionId => null;

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
  int pauseCallCount = 0;
  int playCallCount = 0;
  Object? loadError;

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
    final error = loadError;
    if (error != null) throw error;
  }

  @override
  Future<void> play() async {
    playCallCount++;
    callLogs.add('play');
    _audioPlayer.emitPlaying(true);
  }

  @override
  Future<void> pause() async {
    pauseCallCount++;
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
  Object? songUrlError;
  bool returnEmptyUrl = false;

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    if (songUrlError != null) throw songUrlError!;
    if (returnEmptyUrl) return PlayUrl(url: '', hash: song.hash);
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

Song _song(int index, {Duration? duration}) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手$index',
  hash: 'hash_$index',
  duration: duration ?? Duration(seconds: 180 + index * 10),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAudioPlayer fakeAudioPlayer;
  late _RecordingAudioHandler handler;
  late _MockMusicApi api;
  late PlayerController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeAudioPlayer = _FakeAudioPlayer();
    handler = _RecordingAudioHandler(fakeAudioPlayer);
    api = _MockMusicApi();
    controller = PlayerController(api, handler);
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

  Future<void> cleanUpToastAndSettle(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  group('切歌与播放失败状态同步', () {
    testWidgets('切换新歌立即暂停旧歌，且 pause 调用早于新歌 loadSong', (tester) async {
      await pumpToastHost(tester);

      final song1 = _song(1);
      final song2 = _song(2);
      controller.queue = [song1, song2];

      // 先起播第一首歌
      await controller.playSong(song1);
      await tester.pump();
      expect(controller.isPlaying, isTrue);
      expect(handler.playCallCount, 1);

      // 清空调用日志，准备观察切歌
      handler.callLogs.clear();
      handler.pauseCallCount = 0;

      // 切换到第二首歌
      await controller.playSong(song2);
      await tester.pump();

      // 验证切换新歌时立即调用了 pause
      expect(handler.pauseCallCount, greaterThanOrEqualTo(1));
      final pauseIndex = handler.callLogs.indexOf('pause');
      final loadIndex = handler.callLogs.indexOf('loadSong:${song2.hash}');
      expect(pauseIndex, greaterThanOrEqualTo(0));
      expect(loadIndex, greaterThan(pauseIndex),
          reason: '切新歌时应先 pause 旧音频，再 loadSong 新音频');

      controller.dispose();
      fakeAudioPlayer.disposeStreams();
      await cleanUpToastAndSettle(tester);
    });

    testWidgets('地址解析失败时重置进度、停止播放、显示 Toast.error 且不遗留播放', (tester) async {
      await pumpToastHost(tester);

      final song1 = _song(1, duration: const Duration(seconds: 200));
      final song2 = _song(2, duration: const Duration(seconds: 240));
      controller.queue = [song1, song2];

      // 模拟旧歌正在播放中，且进度非零
      await controller.playSong(song1);
      await tester.pump();
      controller.position = const Duration(seconds: 50);
      expect(controller.isPlaying, isTrue);
      expect(controller.position, const Duration(seconds: 50));

      handler.pauseCallCount = 0;
      // 设置解析失败
      api.songUrlError = Exception('网络异常无法获取音源');

      // 切换到不可播歌曲（isRetry: true 走最终失败路径）
      await controller.playSong(song2, isRetry: true);
      await tester.pump();

      // 验证旧音频被暂停、状态重置
      expect(handler.pauseCallCount, greaterThanOrEqualTo(1));
      expect(controller.isPlaying, isFalse);
      expect(controller.position, Duration.zero);
      expect(controller.duration, song2.duration);
      expect(controller.errorMessage, contains('网络异常无法获取音源'));
      expect(find.text('《${song2.title}》暂无可播放音源'), findsOneWidget);

      controller.dispose();
      fakeAudioPlayer.disposeStreams();
      await cleanUpToastAndSettle(tester);
    });

    testWidgets('地址解析返回空 URL 时重置进度、停止播放、显示 Toast.error', (tester) async {
      await pumpToastHost(tester);

      final song = _song(1, duration: const Duration(seconds: 190));
      controller.queue = [song];

      // 模拟处于播放状态且进度非零
      await controller.playSong(song);
      await tester.pump();
      controller.position = const Duration(seconds: 30);
      expect(controller.isPlaying, isTrue);

      handler.pauseCallCount = 0;
      api.returnEmptyUrl = true;

      await controller.playSong(song, isRetry: true);
      await tester.pump();

      expect(handler.pauseCallCount, greaterThanOrEqualTo(1));
      expect(controller.isPlaying, isFalse);
      expect(controller.position, Duration.zero);
      expect(controller.duration, song.duration);
      expect(controller.errorMessage, isNotNull);
      expect(find.text('《${song.title}》暂无可播放音源'), findsOneWidget);

      controller.dispose();
      fakeAudioPlayer.disposeStreams();
      await cleanUpToastAndSettle(tester);
    });

    testWidgets('音频引擎加载失败 (loadSong 异常) 时重置进度、停止播放、显示 Toast.error', (tester) async {
      await pumpToastHost(tester);

      final song = _song(1, duration: const Duration(seconds: 210));
      controller.queue = [song];

      await controller.playSong(song);
      await tester.pump();
      controller.position = const Duration(seconds: 60);
      expect(controller.isPlaying, isTrue);

      handler.pauseCallCount = 0;
      handler.loadError = Exception('Bad audio codec');

      await controller.playSong(song, isRetry: true);
      await tester.pump();

      expect(handler.pauseCallCount, greaterThanOrEqualTo(1));
      expect(controller.isPlaying, isFalse);
      expect(controller.position, Duration.zero);
      expect(controller.duration, song.duration);
      expect(controller.errorMessage, contains('Bad audio codec'));
      expect(find.text('《${song.title}》暂无可播放音源'), findsOneWidget);

      controller.dispose();
      fakeAudioPlayer.disposeStreams();
      await cleanUpToastAndSettle(tester);
    });

    testWidgets('单曲队列播放失败时显示暂无可播放音源 Toast.error', (tester) async {
      await pumpToastHost(tester);

      final song = _song(1);
      controller.queue = [song];
      handler.loadError = Exception('Single song failed');

      // 失败 3 次达到阈值
      await controller.playSong(song, isRetry: true);
      await tester.pump();
      await controller.playSong(song, isRetry: true);
      await tester.pump();
      await controller.playSong(song, isRetry: true);
      await tester.pump();

      expect(find.text('《${song.title}》暂无可播放音源'), findsOneWidget);

      controller.dispose();
      fakeAudioPlayer.disposeStreams();
      await cleanUpToastAndSettle(tester);
    });

    testWidgets('连续多次失败达上限后显示停止播放 Toast.error', (tester) async {
      await pumpToastHost(tester);

      // 2 首队列，上限 min(2, 5) = 2
      final songs = [_song(1), _song(2)];
      controller.queue = songs;
      handler.loadError = Exception('Source failure');

      // 触发第 1 首失败 3 次达到跳歌阈值
      await controller.playSong(songs[0], isRetry: true);
      await tester.pump();
      await controller.playSong(songs[0], isRetry: true);
      await tester.pump();
      await controller.playSong(songs[0], isRetry: true);
      await tester.pump();

      // 跑完级联自动跳过
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 验证提示连续多首播放失败已停止播放
      expect(find.text('连续多首歌曲播放失败，已停止播放'), findsOneWidget);

      controller.dispose();
      fakeAudioPlayer.disposeStreams();
      await cleanUpToastAndSettle(tester);
    });
  });
}
