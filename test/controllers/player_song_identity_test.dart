// 歌曲身份回归（P1-4.4：无 hash 歌曲 currentIndex 身份兜底）。
//
// 背景：云盘/边缘接口会产出 `hash == ''` 的歌。旧实现只按 hash 定位：
// - `currentIndex` 恒命中队列第一首空 hash 歌（或 -1）→ 播放页队列高亮
//   丢失、单曲循环/随机的「上一首/下一首」退化、shuffle 起点错位；
// - `playSong` 的 `isSameSong = currentSong?.hash == song.hash` 会让两首
//   不同的空 hash 歌恒等（切歌时不清歌词/不重载）；
// - `playSongKeepingQueue` 的 `keyOf = hash ?? id` 把 hash 与 id 混进同一
//   命名空间（空 hash 歌的 id 可与其他歌的 hash 相撞）→ 不同歌互相误判。
//
// 修复后身份优先级：identical → 歌曲身份（非空 hash > 专辑音频 id > 歌曲
// id）→ hash → id；正常歌曲（非空 hash）行为与旧实现等价。
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
  ProcessingState get processingState => ProcessingState.ready;

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

  /// 每次真正进入引擎加载的歌曲 hash（是否重新加载的观测点）。
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
  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {}

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
  List<Song> personalFmBatch = const [];

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async {
    return PlayUrl(
      url: 'https://example.com/${song.hash}.mp3',
      hash: song.hash,
    );
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];

  @override
  Future<List<Song>> personalFm({
    String? hash,
    String? songId,
    int? playtime,
    bool isOverplay = false,
  }) async {
    return personalFmBatch;
  }
}

Song _song(int index) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手',
  hash: 'hash_$index',
);

/// 云盘/边缘接口风格的无 hash 歌（hash 为空，靠 id 识别）。
Song _cloudSong(String id, {String? albumAudioId}) => Song(
  id: id,
  title: '云盘$id',
  artist: '歌手',
  hash: '',
  albumAudioId: albumAudioId,
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
    // 播放态落盘/历史记录等都是一跳微任务，dispose 前先放行，避免
    // 延迟回调通知已销毁对象。
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    controller.dispose();
    fakeAudioPlayer.disposeStreams();
  });

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('currentIndex 四段身份兜底', () {
    test('空 hash 云盘歌按歌曲 id 定位队列位置（队列高亮不再丢）', () {
      controller.queue = [
        _song(1),
        _cloudSong('cloud_1'),
        _cloudSong('cloud_2'),
      ];
      // 换一个实例：identical 段不命中，走身份段的 id 兜底。
      controller.currentSong = _cloudSong('cloud_1');

      expect(controller.currentIndex, 1);
    });

    test('空 hash 且无 id：按专辑音频 id 定位（身份段第二优先级）', () {
      controller.queue = [
        _song(1),
        _cloudSong('', albumAudioId: 'audio_a'),
        _cloudSong('', albumAudioId: 'audio_b'),
      ];
      controller.currentSong = _cloudSong('', albumAudioId: 'audio_a');

      expect(controller.currentIndex, 1);
    });

    test('identical 优先：同 hash 多实例时返回队列中的实际对象位置', () {
      final sharedHashA = Song(
        id: 'dup_a',
        title: 'A',
        artist: '歌手',
        hash: 'h1',
      );
      final sharedHashB = Song(
        id: 'dup_b',
        title: 'B',
        artist: '歌手',
        hash: 'h1',
      );
      controller.queue = [sharedHashA, sharedHashB];
      controller.currentSong = sharedHashB;

      // 旧实现 indexWhere(hash ==) 会返回 0；新实现 identical 优先返回 1。
      expect(controller.currentIndex, 1);
    });

    test('重复空 hash 歌：定位到身份匹配的那一首，而非队列第一首', () {
      controller.queue = [
        _cloudSong('cloud_1'),
        _song(1),
        _cloudSong('cloud_2'),
      ];
      controller.currentSong = _cloudSong('cloud_2');

      // 旧实现会命中第一首空 hash 歌（index 0）。
      expect(controller.currentIndex, 2);
    });

    test('正常歌曲（非空 hash）行为不变：仍按 hash 定位', () {
      controller.queue = [_song(1), _song(2), _song(3)];
      controller.currentSong = _song(2);

      expect(controller.currentIndex, 1);
    });

    test('不在队列：返回 -1', () {
      controller.queue = [_song(1), _song(2)];
      controller.currentSong = Song(
        id: 'not_in_queue',
        title: '不在队列',
        artist: '歌手',
        hash: 'hash_404',
      );

      expect(controller.currentIndex, -1);
    });

    test('无匹配且 hash/id 都为空：返回 -1（不误命中队列首曲）', () {
      controller.queue = [_song(1), _song(2)];
      controller.currentSong = const Song(
        id: '',
        title: '无身份',
        artist: '歌手',
        hash: '',
      );

      expect(controller.currentIndex, -1);
    });
  });

  group('切歌导航走身份兜底', () {
    test('空 hash 歌在队列末尾时「下一首」回绕到队首，而不是重播自己', () async {
      final cloud1 = _cloudSong('cloud_1');
      final cloud2 = _cloudSong('cloud_2');
      await controller.playSong(cloud1, queue: [_song(1), cloud2, cloud1]);
      await settle();
      expect(controller.currentIndex, 2);
      handler.loadedHashes.clear();

      await controller.next();
      await settle();

      // 旧实现 currentIndex 命中 index 1（第一首空 hash 歌 cloud2），
      // 「下一首」拿到自己（index 2）→ 重播当前歌。
      expect(controller.currentSong?.hash, 'hash_1');
      expect(controller.currentIndex, 0);
      expect(handler.loadedHashes, ['hash_1']);
    });
  });

  group('playSong 同一首歌判定', () {
    test('两首不同的空 hash 歌：视为切歌（重载时长/清歌词），不再恒等', () async {
      final cloudA = const Song(
        id: 'cloud_a',
        title: 'A',
        artist: '歌手',
        hash: '',
        duration: Duration(seconds: 100),
      );
      final cloudB = const Song(
        id: 'cloud_b',
        title: 'B',
        artist: '歌手',
        hash: '',
        duration: Duration(seconds: 200),
      );

      await controller.playSong(cloudA, queue: [cloudA, cloudB]);
      await settle();
      expect(controller.duration, const Duration(seconds: 100));

      await controller.playSong(cloudB, queue: [cloudA, cloudB]);
      await settle();

      // 旧实现 isSameSong 为 true（'' == ''）→ duration 保持 A 的 100s。
      expect(controller.duration, const Duration(seconds: 200));
      expect(controller.currentIndex, 1);
    });

    test('非空 hash 相同的另一实例：仍视为同一首歌重播（不清歌词/时长）', () async {
      final first = const Song(
        id: 'same_id',
        title: '同一首',
        artist: '歌手',
        hash: 'same_hash',
        duration: Duration(seconds: 100),
      );
      // 不同实例、同 hash（历史/持久化恢复会产生这种对象）。
      final replay = const Song(
        id: 'same_id',
        title: '同一首',
        artist: '歌手',
        hash: 'same_hash',
        duration: Duration(seconds: 200),
      );

      await controller.playSong(first, queue: [first]);
      await settle();
      expect(controller.duration, const Duration(seconds: 100));

      await controller.playSong(replay);
      await settle();

      expect(controller.duration, const Duration(seconds: 100));
    });
  });

  group('playSongKeepingQueue 身份复用', () {
    test('空 hash 歌的 id 与其他歌的 hash 相撞：不再互相误判（keyOf 命名空间冲突）', () async {
      final cloudSong = const Song(
        id: 'shared_key',
        title: '云盘歌',
        artist: '歌手',
        hash: '',
      );
      final otherSong = const Song(
        id: 'other_id',
        title: '另一首',
        artist: '歌手',
        hash: 'shared_key',
      );

      await controller.playSong(cloudSong, queue: [cloudSong]);
      await settle();
      handler.loadedHashes.clear();

      // 旧 keyOf：cloudSong → 'shared_key'（id），otherSong → 'shared_key'
      // （hash）→ 误判为「点的就是当前歌」：不重载、currentSong 不变。
      await controller.playSongKeepingQueue(otherSong);
      await settle();

      expect(controller.currentSong?.hash, 'shared_key');
      expect(controller.currentSong?.id, 'other_id');
      expect(handler.loadedHashes, ['shared_key']);
    });

    test('空 hash 不同 id：不是当前歌，插入队列并起播', () async {
      final cloudA = _cloudSong('cloud_a');
      await controller.playSong(cloudA, queue: [cloudA]);
      await settle();
      handler.loadedHashes.clear();

      await controller.playSongKeepingQueue(_cloudSong('cloud_b'));
      await settle();

      expect(controller.queue, hasLength(2));
      expect(controller.currentSong?.id, 'cloud_b');
      expect(controller.currentIndex, 1);
      expect(handler.loadedHashes, hasLength(1));
    });

    test('空 hash 同 id 不同专辑音频 id：按身份区分并插入队列', () async {
      await controller.playSong(
        const Song(id: 'same_id', title: 'A', artist: '歌手', hash: ''),
        queue: [const Song(id: 'same_id', title: 'A', artist: '歌手', hash: '')],
      );
      await settle();
      handler.loadedHashes.clear();

      // 同 id 但专辑音频 id 不同：是另一首歌，应插入并起播。
      await controller.playSongKeepingQueue(
        const Song(
          id: 'same_id',
          title: 'B',
          artist: '歌手',
          hash: '',
          albumAudioId: 'audio_b',
        ),
      );
      await settle();

      expect(controller.queue, hasLength(2));
      expect(controller.currentSong?.albumAudioId, 'audio_b');
      expect(controller.currentIndex, 1);
    });
  });

  group('_isSameQueue 身份比较（私人 FM 会话保持）', () {
    test('空 hash 队列按歌曲 id 逐项比较：同身份队列保持会话', () async {
      final fmSongs = [_cloudSong('fm_1'), _cloudSong('fm_2')];
      api.personalFmBatch = fmSongs;
      await controller.startPersonalFm();
      await settle();
      expect(controller.isPersonalFmActive, isTrue);

      // 同内容、不同 Song 实例的队列：应识别为同一队列，保持 FM 会话。
      await controller.playSong(
        _cloudSong('fm_2'),
        queue: [_cloudSong('fm_1'), _cloudSong('fm_2')],
      );
      await settle();

      expect(controller.currentSong?.id, 'fm_2');
      expect(controller.isPersonalFmActive, isTrue);
    });

    test('空 hash 队列身份不同：判定为替换队列并退出会话', () async {
      final fmSongs = [_cloudSong('fm_1'), _cloudSong('fm_2')];
      api.personalFmBatch = fmSongs;
      await controller.startPersonalFm();
      await settle();
      expect(controller.isPersonalFmActive, isTrue);

      await controller.playSong(
        _cloudSong('other_1'),
        queue: [_cloudSong('other_1'), _cloudSong('other_2')],
      );
      await settle();

      expect(controller.isPersonalFmActive, isFalse);
    });
  });
}
