import 'dart:async';

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

  void setPlaying(bool playing) {
    _playing = playing;
    _playerStateController.add(
      PlayerState(playing, _processingState),
    );
  }

  void disposeStreams() {
    _positionController.close();
    _durationController.close();
    _playerStateController.close();
    _processingStateController.close();
    _androidAudioSessionIdController.close();
  }
}

class _RecordingAudioHandler extends Fake implements MusicAudioHandler {
  _RecordingAudioHandler(this._audioPlayer);

  final AudioPlayer _audioPlayer;
  final List<String> callLogs = [];
  final List<Duration> seekPositions = [];
  Future<void> Function()? onLoadSong;
  bool throwOnSeek = false;

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
    seekPositions.add(position);
    if (throwOnSeek) throw Exception('engine seek failed');
  }

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    callLogs.add('loadSong');
    if (onLoadSong != null) {
      await onLoadSong!();
    }
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
  final Map<String, SongClimax?> climaxMap = {};

  @override
  Future<SongClimax?> songClimax(String hash) async {
    return climaxMap[hash];
  }

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async {
    return const [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerController 试听高潮冷启动 (idle) 状态测试', () {
    late _FakeAudioPlayer fakeAudioPlayer;
    late _RecordingAudioHandler recordingAudioHandler;
    late _MockMusicApi mockApi;
    late PlayerController controller;

    const testSong = Song(
      id: 'test_song_1',
      title: '测试歌曲',
      artist: '测试歌手',
      hash: 'test_hash_123',
    );

    const testClimax = SongClimax(
      startTime: Duration(seconds: 45),
      endTime: Duration(seconds: 75),
      hash: 'test_hash_123',
    );

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      fakeAudioPlayer = _FakeAudioPlayer();
      recordingAudioHandler = _RecordingAudioHandler(fakeAudioPlayer);
      mockApi = _MockMusicApi();
      mockApi.climaxMap[testSong.hash] = testClimax;

      controller = PlayerController(mockApi, recordingAudioHandler);
      // 模拟冷启动或未播放状态：已恢复 currentSong 与 queue，但底层 audioPlayer 处于 idle 状态
      controller.currentSong = testSong;
      controller.queue = [testSong];
    });

    tearDown(() {
      controller.dispose();
      fakeAudioPlayer.disposeStreams();
    });

    test(
      '当 currentSong != null 且 audioPlayer.processingState == idle 时调用 playClimaxPreview'
      '应直接从 climax.startTime 开始加载起播，保留 _climaxEndTime，且位置不弹回 0 秒',
      () async {
        expect(fakeAudioPlayer.processingState, ProcessingState.idle);

        final success = await controller.playClimaxPreview();

        expect(success, isTrue);

        // 1. 保留 _climaxEndTime 等于 climax.endTime
        expect(controller.climaxEndTime, equals(const Duration(seconds: 75)));
        expect(controller.climax, equals(testClimax));

        // 2. 播放器位置设置为 climax.startTime，而不是 0
        expect(controller.position, equals(const Duration(seconds: 45)));

        // 3. 底层音频引擎起播序列：必须在 loadSong 之后、play 之前 seek 到 climax.startTime
        final loadIndex = recordingAudioHandler.callLogs.indexOf('loadSong');
        final seekIndex = recordingAudioHandler.callLogs.lastIndexOf('seek:45');
        final playIndex = recordingAudioHandler.callLogs.indexOf('play');

        expect(loadIndex, isNot(-1), reason: '应当调用 loadSong 加载歌曲');
        expect(seekIndex, isNot(-1), reason: '应当 seek 到 climax.startTime');
        expect(playIndex, isNot(-1), reason: '应当调用 play 开始播放');
        expect(
          seekIndex > loadIndex && seekIndex < playIndex,
          isTrue,
          reason: '应当在 loadSong 之后、play 之前 seek 到高潮起始点',
        );
      },
    );

    test(
      '当 audioPlayer 处于 ready 状态且未播放时调用 playClimaxPreview'
      '应当 seek 到高潮点并调用 togglePlay 恢复播放',
      () async {
        fakeAudioPlayer.setProcessingState(ProcessingState.ready);
        fakeAudioPlayer.setPlaying(false);

        final success = await controller.playClimaxPreview();

        expect(success, isTrue);
        expect(controller.climaxEndTime, equals(const Duration(seconds: 75)));
        expect(controller.climax, equals(testClimax));
        expect(recordingAudioHandler.callLogs, contains('seek:45'));
        expect(recordingAudioHandler.callLogs, contains('play'));
      },
    );

    test('当未设置 preserveClimax 调用 playSong 时，重置 climax 与 _climaxEndTime 为 null', () async {
      // 先武装高潮
      await controller.playClimaxPreview();
      expect(controller.climaxEndTime, isNotNull);
      expect(controller.climax, isNotNull);

      // 普通切歌/播放
      const nextSong = Song(
        id: 'next_song',
        title: '下一首',
        artist: '测试歌手',
        hash: 'next_hash',
      );
      await controller.playSong(nextSong);

      expect(controller.climaxEndTime, isNull);
      expect(controller.climax, isNull);
    });

    test('当接口未返回高潮信息 (null) 时，playClimaxPreview 返回 false 且不改变播放位置', () async {
      mockApi.climaxMap.clear();

      final success = await controller.playClimaxPreview();

      expect(success, isFalse);
      expect(controller.climaxEndTime, isNull);
      expect(recordingAudioHandler.callLogs, isEmpty);
    });

    test(
      '当底层处于 idle 状态时调用 seekToAndPlay(target) 直接从 target 起播，不跳回 0 秒',
      () async {
        expect(fakeAudioPlayer.processingState, ProcessingState.idle);

        const targetPos = Duration(seconds: 83);
        await controller.seekToAndPlay(targetPos);

        expect(controller.position, equals(targetPos));
        final loadIndex = recordingAudioHandler.callLogs.indexOf('loadSong');
        final seekIndex = recordingAudioHandler.callLogs.lastIndexOf('seek:83');
        final playIndex = recordingAudioHandler.callLogs.indexOf('play');

        expect(loadIndex, isNot(-1));
        expect(seekIndex, isNot(-1));
        expect(playIndex, isNot(-1));
        expect(seekIndex > loadIndex && seekIndex < playIndex, isTrue);
      },
    );

    test(
      '当底层处于 idle 状态时调用 seekToAndPlay(target)，在音频加载期间底层 positionStream 发出 0 秒事件时，position 与 positionListenable 不会闪退回 0 秒',
      () async {
        expect(fakeAudioPlayer.processingState, ProcessingState.idle);

        const targetPos = Duration(seconds: 83);
        final recordedPositions = <Duration>[];
        controller.positionListenable.addListener(() {
          recordedPositions.add(controller.positionListenable.value);
        });

        // 启动 seekToAndPlay，并在加载中途模拟底层 audioPlayer 发射 0 秒位置
        final playFuture = controller.seekToAndPlay(targetPos);
        fakeAudioPlayer.setPosition(Duration.zero);
        await playFuture;

        expect(controller.position, equals(targetPos));
        expect(
          recordedPositions.contains(Duration.zero),
          isFalse,
          reason: 'positionListenable 不应在加载过程中回弹为 0 秒导致界面闪烁',
        );
      },
    );

    test(
      'seekToAndPlay 加载期间底层 playerStateStream 发射加载态（引擎 position 归 0）时，position 与 positionListenable 不闪回 0 秒',
      () async {
        expect(fakeAudioPlayer.processingState, ProcessingState.idle);

        const targetPos = Duration(seconds: 83);
        final recordedPositions = <Duration>[];
        controller.positionListenable.addListener(() {
          recordedPositions.add(controller.positionListenable.value);
        });

        // 模拟真实 just_audio 行为：loadSong 加载新音频源时引擎 position 归 0，
        // 且 playerStateStream 发射 (playing=false, 加载中) 状态事件
        recordingAudioHandler.onLoadSong = () async {
          fakeAudioPlayer.setPosition(Duration.zero);
          fakeAudioPlayer.setPlaying(false);
        };

        await controller.seekToAndPlay(targetPos);

        expect(controller.position, equals(targetPos));
        expect(
          recordedPositions.contains(Duration.zero),
          isFalse,
          reason: 'playerStateStream 在加载期间用引擎 0 秒位置重建平滑基线，'
              '会让歌词列表与进度条先闪回开头、加载完成后再跳回目标位置',
        );
      },
    );

    test(
      '当底层处于 idle 状态时先调用 seek(target) 后调用 togglePlay()，应保留目标位置并在起播时 seek 到 target',
      () async {
        expect(fakeAudioPlayer.processingState, ProcessingState.idle);

        const targetPos = Duration(seconds: 131);
        await controller.seek(targetPos);
        expect(controller.position, equals(targetPos));

        // 点击播放
        await controller.togglePlay();

        expect(controller.position, equals(targetPos));
        final loadIndex = recordingAudioHandler.callLogs.indexOf('loadSong');
        final seekIndex = recordingAudioHandler.callLogs.lastIndexOf('seek:131');
        final playIndex = recordingAudioHandler.callLogs.indexOf('play');

        expect(loadIndex, isNot(-1));
        expect(seekIndex, isNot(-1));
        expect(playIndex, isNot(-1));
        expect(seekIndex > loadIndex && seekIndex < playIndex, isTrue);
      },
    );
  });

  group('seek 非 idle 错误语义（回归：调用方不接错即未处理异常）', () {
    late _FakeAudioPlayer fakeAudioPlayer;
    late _RecordingAudioHandler recordingAudioHandler;
    late _MockMusicApi mockApi;
    late PlayerController controller;

    const testSong = Song(
      id: 'test_song_1',
      title: '测试歌曲',
      artist: '测试歌手',
      hash: 'test_hash_123',
    );

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      fakeAudioPlayer = _FakeAudioPlayer();
      recordingAudioHandler = _RecordingAudioHandler(fakeAudioPlayer);
      mockApi = _MockMusicApi();
      controller = PlayerController(mockApi, recordingAudioHandler);
      controller.currentSong = testSong;
      controller.queue = [testSong];
    });

    tearDown(() {
      controller.dispose();
      fakeAudioPlayer.disposeStreams();
    });

    test('非 idle 下引擎 seek 失败必须上抛（调用方才能提示而非声画脱节）', () async {
      fakeAudioPlayer.setProcessingState(ProcessingState.ready);
      recordingAudioHandler.throwOnSeek = true;

      await expectLater(
        controller.seek(const Duration(seconds: 10)),
        throwsA(isA<Exception>()),
      );
    });

    test('空队列 previous 边界回零失败不抛错，落错误态提示', () async {
      fakeAudioPlayer.setProcessingState(ProcessingState.ready);
      recordingAudioHandler.throwOnSeek = true;
      controller.queue = const [];

      await controller.previous();

      expect(controller.errorMessage, isNotNull);
    });
  });
}

