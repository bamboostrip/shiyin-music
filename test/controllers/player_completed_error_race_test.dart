// PC media_kit 在曲目 EOF 后可能先吐错误日志再/同时进入 completed。
// 若把这些迟到错误当成「播放中出错」，Toast 会挂在已播完的歌上，
// 并打断自动下一首。覆盖：completed 后 isPlaying 收敛、迟到错误不弹
// 没有音源、自动下一首仍能推进。
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

  Duration _position = Duration.zero;
  bool _playing = false;
  ProcessingState _processingState = ProcessingState.idle;

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
  Duration get position => _position;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => _processingState;

  @override
  int? get androidAudioSessionId => null;

  void setProcessingState(ProcessingState state) {
    _processingState = state;
    _processingStateController.add(state);
  }

  void setPosition(Duration pos) {
    _position = pos;
    _positionController.add(pos);
  }

  /// 模拟 just_audio 行为：processingState 变更时 playerState 同步发出。
  /// 桌面 media_kit 适配层 completed 后 playing 可能仍为 true，故 playing
  /// 与 processingState 分开传入。
  void emitPlayerState({required bool playing, ProcessingState? state}) {
    if (state != null) {
      _processingState = state;
    }
    _playing = playing;
    _playerStateController.add(PlayerState(playing, _processingState));
    _processingStateController.add(_processingState);
  }

  void emitError(PlayerException error) {
    _errorController.add(error);
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
  final List<String> loadedHashes = [];
  final List<Duration> seekPositions = [];
  int playCount = 0;
  int pauseCount = 0;

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
    seekPositions.add(position);
  }

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    loadedHashes.add(song.hash);
  }

  @override
  Future<void> play() async {
    playCount++;
    _audioPlayer.emitPlayerState(playing: true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _audioPlayer.emitPlayerState(playing: false);
  }

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

Song _song(int index) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手$index',
  hash: 'hash_$index',
  duration: Duration(seconds: 180 + index),
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

  tearDown(() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    controller.dispose();
    fakeAudioPlayer.disposeStreams();
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
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('completed 后 isPlaying 收敛为 false（即使引擎 playing 仍为 true）', (
    tester,
  ) async {
    final songs = [_song(1), _song(2)];
    controller.queue = songs;
    controller.currentSong = songs[0];

    // 正常播放中
    fakeAudioPlayer.emitPlayerState(playing: true, state: ProcessingState.ready);
    await tester.pump();
    expect(controller.isPlaying, isTrue);

    // media_kit：playing 仍 true，但 processingState 已 completed
    fakeAudioPlayer.emitPlayerState(
      playing: true,
      state: ProcessingState.completed,
    );
    await tester.pump();

    expect(controller.isPlaying, isFalse);
  });

  testWidgets('completed 后的迟到引擎错误不对已播完歌曲弹「没有音源」', (tester) async {
    await pumpToastHost(tester);

    final song1 = _song(1);
    final song2 = _song(2);
    controller.queue = [song1, song2];
    controller.currentSong = song1;
    await controller.playSong(song1);
    await tester.pump();

    // 模拟曲目播完：playing 仍 true + completed（桌面适配层常见形态）
    fakeAudioPlayer.emitPlayerState(
      playing: true,
      state: ProcessingState.completed,
    );
    await tester.pump();

    // 模拟 mpv EOF 后的连接清理类 error 日志被抬成 PlayerException
    fakeAudioPlayer.emitError(
      PlayerException(1, 'ffmpeg: tcp: Connection reset by peer', 0),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('《${song1.title}》暂无可播放音源'), findsNothing);
    expect(find.text('播放中断，请稍后重试'), findsNothing);

    await cleanUpToastAndSettle(tester);
  });

  test('completed 自动下一首仍推进到下一曲，迟到错误不阻断', () async {
    final song1 = _song(1);
    final song2 = _song(2);
    controller.queue = [song1, song2];
    controller.currentSong = song1;
    handler.loadedHashes.clear();

    // completed → 自动下一首
    fakeAudioPlayer.emitPlayerState(
      playing: true,
      state: ProcessingState.completed,
    );
    // 迟到错误紧跟其后（模拟桌面端竞态）
    fakeAudioPlayer.emitError(
      PlayerException(1, 'lavf: Failed to create file cache', 0),
    );

    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(controller.currentSong?.hash, song2.hash);
    expect(handler.loadedHashes, contains(song2.hash));
    expect(controller.errorMessage, isNot('播放中断，请稍后重试'));
  });

  test('播放中途错误（非 completed）仍走失败路径', () async {
    final song = _song(1);
    controller.queue = [song];
    controller.currentSong = song;
    await controller.playSong(song);
    await Future<void>.delayed(Duration.zero);

    fakeAudioPlayer.emitPlayerState(
      playing: true,
      state: ProcessingState.ready,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.isPlaying, isTrue);

    // 进度停在歌曲前段，remaining 远大于 1.5s，属真正的中途错误
    fakeAudioPlayer.setPosition(const Duration(seconds: 10));
    controller.position = const Duration(seconds: 10);
    fakeAudioPlayer.emitError(
      PlayerException(1, 'ffmpeg: tcp: Connection timed out', 0),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.errorMessage, '播放中断，请稍后重试');
    expect(controller.isPlaying, isFalse);
    expect(controller.currentSong?.hash, song.hash);
  });

  test('曲末 FLAC 解码失败按播完处理，自动切下一首且不弹当前歌没有音源', () async {
    final song1 = _song(1);
    final song2 = _song(2);
    controller.queue = [song1, song2];
    controller.currentSong = song1;
    controller.duration = const Duration(seconds: 305);
    controller.position = const Duration(seconds: 304);
    handler.loadedHashes.clear();

    fakeAudioPlayer.setPosition(const Duration(seconds: 304));
    fakeAudioPlayer.emitPlayerState(playing: true, state: ProcessingState.ready);
    await Future<void>.delayed(Duration.zero);
    expect(controller.isPlaying, isTrue);

    // 对齐实机日志：曲末 flac invalid sync → ad: Error decoding audio.
    fakeAudioPlayer.emitError(
      PlayerException(1, 'Error decoding audio.', 0),
    );

    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(controller.currentSong?.hash, song2.hash);
    expect(handler.loadedHashes, contains(song2.hash));
    expect(controller.errorMessage, isNot('播放中断，请稍后重试'));
  });

  test('remaining 为负（引擎时长略短于元数据）也按曲末处理', () async {
    final song1 = _song(1);
    final song2 = _song(2);
    controller.queue = [song1, song2];
    controller.currentSong = song1;
    controller.duration = const Duration(seconds: 305);
    // 引擎 position 略超元数据时长
    controller.position = const Duration(milliseconds: 305100);
    handler.loadedHashes.clear();

    fakeAudioPlayer.setPosition(const Duration(milliseconds: 305100));
    fakeAudioPlayer.emitPlayerState(playing: true, state: ProcessingState.ready);
    await Future<void>.delayed(Duration.zero);

    fakeAudioPlayer.emitError(
      PlayerException(1, 'Error decoding audio.', 0),
    );

    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(controller.currentSong?.hash, song2.hash);
    expect(handler.loadedHashes, contains(song2.hash));
  });

  test('阈值上界：剩余 2s 不算曲末，走正常失败路径（锁 1.5s 阈值上界）', () async {
    final song1 = _song(1);
    final song2 = _song(2);
    controller.queue = [song1, song2];
    controller.currentSong = song1;
    controller.duration = const Duration(seconds: 300);
    controller.position = const Duration(seconds: 298);
    handler.loadedHashes.clear();

    fakeAudioPlayer.setPosition(const Duration(seconds: 298));
    fakeAudioPlayer.emitPlayerState(playing: true, state: ProcessingState.ready);
    await Future<void>.delayed(Duration.zero);
    expect(controller.isPlaying, isTrue);

    fakeAudioPlayer.emitError(
      PlayerException(1, 'ffmpeg: tcp: Connection timed out', 0),
    );
    await Future<void>.delayed(Duration.zero);

    // remaining=2s > 1.5s：不得按播完自动切歌，必须走正常失败路径。
    expect(controller.errorMessage, '播放中断，请稍后重试');
    expect(controller.isPlaying, isFalse);
    expect(controller.currentSong?.hash, song1.hash);
    expect(handler.loadedHashes, isNot(contains(song2.hash)));
  });

  test('completed 后点播放应 pause→seek→play，而不是只 play 空转', () async {
    final song = _song(1);
    controller.queue = [song];
    controller.currentSong = song;
    controller.duration = const Duration(seconds: 200);

    // 引擎 completed，但 just_audio.playing 仍可能为 true（适配层不回写）
    fakeAudioPlayer.emitPlayerState(
      playing: true,
      state: ProcessingState.completed,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.isPlaying, isFalse);

    handler.playCount = 0;
    handler.pauseCount = 0;
    handler.seekPositions.clear();
    await controller.togglePlay();

    // just_audio.play() 在 playing==true 时短路，必须先 pause 归零
    expect(handler.pauseCount, 1, reason: 'completed 后必须先 pause 再 play');
    expect(handler.playCount, 1);
    expect(handler.seekPositions, contains(Duration.zero));
  });

  test('曲末点歌词行跳转：先收敛陈旧的 playing 标志再起播，且不冲掉目标位置', () async {
    final song = _song(1);
    controller.queue = [song];
    controller.currentSong = song;
    controller.duration = const Duration(seconds: 200);

    // 引擎 completed、isPlaying 已收敛，但 just_audio.playing 仍是陈旧的 true：
    // 此时读 audioPlayer.playing 会误判「还在播」而跳过起播。
    fakeAudioPlayer.emitPlayerState(
      playing: true,
      state: ProcessingState.completed,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.isPlaying, isFalse);

    handler.playCount = 0;
    handler.pauseCount = 0;
    handler.seekPositions.clear();
    const target = Duration(seconds: 60);
    await controller.seekToAndPlay(target);

    expect(handler.seekPositions, contains(target));
    expect(
      handler.seekPositions,
      isNot(contains(Duration.zero)),
      reason: '不得 seek 回零，冲掉调用方定位的歌词/高潮位置',
    );
    expect(handler.pauseCount, 1, reason: '先 pause 归零 just_audio.playing');
    expect(handler.playCount, 1);
  });

  test('曲末 EOF 解码错误属正常播完：不扣跳过预算，超过上限仍继续切歌', () async {
    final songs = [_song(1), _song(2)];
    controller.queue = songs;

    // 实机形态（3.0.8 Windows）：libmpv 在真实 EOF 报
    // `(1) Error decoding audio.`，位置距引擎时长约 300ms。曲末跳过预算的
    // 上限 = min(队列长度 2, 5) = 2，若这条路径扣额度，第 3 次就会停住不再
    // 切歌——这正是「播到曲末不跳转」的成因（计数器只在自然 completed 归零，
    // 而本路径永远走不到那里 → 每个会话固定只能连播 5 首）。
    // 「系统性坏尾受预算限制」的防护由停滞 watchdog 承重，回归见
    // player_tail_stall_test.dart「系统性坏尾：watchdog 强制推进计入曲末跳过预算」。
    for (var attempt = 0; attempt < 4; attempt++) {
      final current = controller.currentSong ?? songs[0];
      controller.currentSong = current;
      final songDuration = current.duration!;
      controller.duration = songDuration;
      final nearEnd = songDuration - const Duration(milliseconds: 300);
      controller.position = nearEnd;
      fakeAudioPlayer.setPosition(nearEnd);
      fakeAudioPlayer.emitPlayerState(
        playing: true,
        state: ProcessingState.ready,
      );
      await Future<void>.delayed(Duration.zero);

      fakeAudioPlayer.emitError(
        PlayerException(1, 'Error decoding audio.', 0),
      );
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    expect(
      handler.loadedHashes.length,
      4,
      reason: '曲末 EOF 解码错误不计入跳过预算，4 次都应自动切歌',
    );
    expect(
      controller.errorMessage,
      isNot('连续多次在曲末播放失败，已停止自动切歌'),
      reason: '正常播完不得报「已停止自动切歌」',
    );
  });
}
