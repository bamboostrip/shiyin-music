// 私人 FM（酷狗官方「猜你喜欢」）会话逻辑：
// - 首页预览批次直接开播；无预览时现拉首批；
// - 会话内"下一首"：队列中段线性前进不请求；队列末尾续拉下一批且保持会话；
// - 在其它入口点歌（队列被替换）退出会话，同一队列内点歌保持会话；
// - 会话内"上一首"仍可线性回退，首曲回零不退出；
// - 会话播放地址走 hashOnly（FM 歌曲没有可靠专辑/音频 id）。
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
  final _errorController = StreamController<PlayerException>.broadcast();
  final _androidAudioSessionIdController = StreamController<int?>.broadcast();

  Duration lastSeek = Duration.zero;

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

  @override
  Future<void> seek(final Duration? position, {int? index}) async {
    lastSeek = position ?? Duration.zero;
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

  final AudioPlayer _audioPlayer;

  final List<String> loadedHashes = [];

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
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    loadedHashes.add(song.hash);
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

/// 播放反馈记录：每次 personalFm 调用的参数。
class _PersonalFmCall {
  _PersonalFmCall({
    this.hash,
    this.songId,
    this.playtime,
    this.isOverplay = false,
  });

  final String? hash;
  final String? songId;
  final int? playtime;
  final bool isOverplay;
}

class _FakeMusicApi extends Fake implements MusicApi {
  /// 无论是否带反馈，都依次从这里取批次返回（模拟服务端下一批推荐）。
  final List<List<Song>> batches = [];

  final List<_PersonalFmCall> fmCalls = [];
  final List<bool> songUrlHashOnly = [];

  int _batchIndex = 0;

  @override
  Future<List<Song>> personalFm({
    String? hash,
    String? songId,
    int? playtime,
    bool isOverplay = false,
  }) async {
    fmCalls.add(
      _PersonalFmCall(
        hash: hash,
        songId: songId,
        playtime: playtime,
        isOverplay: isOverplay,
      ),
    );
    if (batches.isEmpty) return const [];
    final batch = batches[_batchIndex.clamp(0, batches.length - 1)];
    if (_batchIndex < batches.length - 1) {
      _batchIndex++;
    }
    return batch;
  }

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async {
    songUrlHashOnly.add(hashOnly);
    return PlayUrl(
      url: 'https://example.com/${song.hash}.mp3',
      hash: song.hash,
    );
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

Song _song(int index) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手',
  hash: 'hash_$index',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAudioPlayer fakeAudioPlayer;
  late _RecordingAudioHandler handler;
  late _FakeMusicApi api;
  late PlayerController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeAudioPlayer = _FakeAudioPlayer();
    handler = _RecordingAudioHandler(fakeAudioPlayer);
    api = _FakeMusicApi();
    controller = PlayerController(api, handler);
  });

  tearDown(() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    controller.dispose();
    fakeAudioPlayer.disposeStreams();
  });

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('启动私人 FM', () {
    test('有预览批次时直接开播，不再请求接口', () async {
      final preview = [_song(1), _song(2)];

      final ok = await controller.startPersonalFm(initialSongs: preview);
      await settle();

      expect(ok, isTrue);
      expect(controller.isPersonalFmActive, isTrue);
      expect(controller.currentSong?.hash, 'hash_1');
      expect(controller.queue.map((song) => song.hash), ['hash_1', 'hash_2']);
      expect(api.fmCalls, isEmpty);
      // FM 会话内解析播放地址必须用 hashOnly。
      expect(api.songUrlHashOnly, isNotEmpty);
      expect(api.songUrlHashOnly.every((hashOnly) => hashOnly), isTrue);
    });

    test('无预览批次时现拉首批并开播', () async {
      api.batches.add([_song(10), _song(11)]);

      final ok = await controller.startPersonalFm();
      await settle();

      expect(ok, isTrue);
      expect(controller.isPersonalFmActive, isTrue);
      expect(controller.currentSong?.hash, 'hash_10');
      expect(api.fmCalls.length, 1);
      expect(api.fmCalls.single.hash, isNull);
    });

    test('接口返回空时进入错误态且不激活会话', () async {
      final ok = await controller.startPersonalFm();
      await settle();

      expect(ok, isFalse);
      expect(controller.isPersonalFmActive, isFalse);
      expect(controller.errorMessage, '暂时没有新的私人 FM 推荐');
    });
  });

  group('会话内的切歌导航', () {
    test('队列末尾"下一首"续拉下一批并保持会话', () async {
      api.batches
        ..add([_song(1)])
        ..add([_song(2), _song(3)]);
      await controller.startPersonalFm();
      await settle();
      expect(controller.currentSong?.hash, 'hash_1');

      await controller.next();
      await settle();

      // 第二批请求带上了当前歌曲的播放反馈（isOverplay=false）。
      expect(api.fmCalls.length, 2);
      final feedback = api.fmCalls.last;
      expect(feedback.hash, 'hash_1');
      expect(feedback.songId, 'song_1');
      expect(feedback.isOverplay, isFalse);
      expect(controller.currentSong?.hash, 'hash_2');
      expect(controller.queue.map((song) => song.hash), [
        'hash_1',
        'hash_2',
        'hash_3',
      ]);
      expect(controller.isPersonalFmActive, isTrue);
    });

    test('队列中段"下一首"线性前进且不请求续批', () async {
      api.batches.add([_song(1), _song(2), _song(3)]);
      await controller.startPersonalFm();
      await settle();
      expect(api.fmCalls.length, 1);

      await controller.next();
      await settle();

      expect(controller.currentSong?.hash, 'hash_2');
      expect(api.fmCalls.length, 1, reason: '队列中段不应请求下一批');
      expect(controller.isPersonalFmActive, isTrue);
    });

    test('"上一首"在会话内线性回退且保持会话', () async {
      api.batches.add([_song(1), _song(2)]);
      await controller.startPersonalFm();
      await settle();
      await controller.next();
      await settle();
      expect(controller.currentSong?.hash, 'hash_2');

      await controller.previous();
      await settle();

      expect(controller.currentSong?.hash, 'hash_1');
      expect(controller.isPersonalFmActive, isTrue);
    });

    test('首曲"上一首"回零不退出会话', () async {
      api.batches.add([_song(1), _song(2)]);
      await controller.startPersonalFm();
      await settle();
      expect(controller.currentSong?.hash, 'hash_1');

      await controller.previous();
      await settle();

      expect(controller.currentSong?.hash, 'hash_1');
      expect(controller.isPersonalFmActive, isTrue);
    });
  });

  group('会话的进入与退出', () {
    test('在其它列表点歌（替换队列）退出会话', () async {
      api.batches.add([_song(1), _song(2)]);
      await controller.startPersonalFm();
      await settle();
      expect(controller.isPersonalFmActive, isTrue);

      await controller.playSong(_song(99), queue: [_song(99)]);
      await settle();

      expect(controller.isPersonalFmActive, isFalse);
    });

    test('在同一队列内点歌保持会话', () async {
      api.batches.add([_song(1), _song(2)]);
      await controller.startPersonalFm();
      await settle();
      expect(controller.isPersonalFmActive, isTrue);

      await controller.playSong(_song(2), queue: controller.queue);
      await settle();

      expect(controller.currentSong?.hash, 'hash_2');
      expect(controller.isPersonalFmActive, isTrue);
    });

    test('续批为空时保留会话并进入错误态', () async {
      api.batches.add([_song(1)]);
      await controller.startPersonalFm();
      await settle();

      await controller.next();
      await settle();

      expect(controller.currentSong?.hash, 'hash_1');
      expect(controller.errorMessage, '私人 FM 暂时没有新的推荐歌曲');
      expect(controller.isPersonalFmActive, isTrue);
    });
  });
}
