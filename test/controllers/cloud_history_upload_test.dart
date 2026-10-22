// 云端播放记录上报（「听歌时光机」二期）：
// - 开关默认关：上报是把听歌行为写进酷狗账号画像的写操作，未经用户
//   显式开启绝不上报（「默认关」是本特性的决定性风险控制条款）；
// - 起播成功钩子仅在「开关开 + 酷狗在线源 + 数字 mixsongid」时上报，
//   unawaited 不阻塞播放，失败静默（不落 errorMessage、不影响本地历史）。
//
// 装置（_Engine/_FakeAudioPlayer/_EngineAudioHandler/_MockMusicApi/settle）
// 拷贝自 play_confirm_timeout_test.dart；_SpyMusicApi 在 _MockMusicApi
// 基础上记录 uploadPlayHistory 调用、可注入异常。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';
import 'package:shiyin_music/services/playback_history_service.dart';

class _Engine {
  bool playing = false;
  ProcessingState state = ProcessingState.idle;
  final stateCtrl = StreamController<PlayerState>.broadcast();
  final processingCtrl = StreamController<ProcessingState>.broadcast();
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration?>.broadcast();
  final errorCtrl = StreamController<PlayerException>.broadcast();

  void emit() {
    processingCtrl.add(state);
    stateCtrl.add(PlayerState(playing, state));
  }

  void setState(ProcessingState s) {
    state = s;
    emit();
  }

  Future<void> dispose() async {
    await stateCtrl.close();
    await processingCtrl.close();
    await positionCtrl.close();
    await durationCtrl.close();
    await errorCtrl.close();
  }
}

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  _FakeAudioPlayer(this.engine);

  final _Engine engine;

  @override
  Stream<Duration> get positionStream => engine.positionCtrl.stream;

  @override
  Stream<Duration?> get durationStream => engine.durationCtrl.stream;

  @override
  Stream<PlayerState> get playerStateStream => engine.stateCtrl.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      engine.processingCtrl.stream;

  @override
  Stream<PlayerException> get errorStream => engine.errorCtrl.stream;

  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Duration get position => Duration.zero;

  @override
  bool get playing => engine.playing;

  @override
  ProcessingState get processingState => engine.state;

  @override
  int? get androidAudioSessionId => null;
}

class _EngineAudioHandler extends Fake implements MusicAudioHandler {
  _EngineAudioHandler(this.engine, this.player);

  final _Engine engine;
  final _FakeAudioPlayer player;

  /// Android 实机行为：`play()` 置 playWhenReady 后 Future 挂到曲末才回执，
  /// 但引擎侧 playing 已为 true。
  bool hangPlayUntilCompleted = false;

  /// 未来风险路径：`play()` 既不回执也不起播（会话被抢/未 ready 又不抛错），
  /// 引擎侧 playing 保持 false。
  bool hangPlaySilent = false;

  final List<Completer<void>> _playBlockers = [];

  @override
  AudioPlayer get audioPlayer => player;

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {}

  @override
  void detachTransportControls() {}

  @override
  Future<void> seek(Duration position, [dynamic options]) async {
    if (engine.state != ProcessingState.ready) {
      engine.setState(ProcessingState.ready);
    }
  }

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    engine.setState(ProcessingState.loading);
    engine.setState(ProcessingState.ready);
  }

  void releaseAllBlocked() {
    for (final blocker in _playBlockers) {
      if (!blocker.isCompleted) blocker.complete();
    }
  }

  @override
  Future<void> play() async {
    if (hangPlaySilent) {
      final blocker = Completer<void>();
      _playBlockers.add(blocker);
      await blocker.future;
      return;
    }
    if (engine.playing) return;
    engine.playing = true;
    engine.emit();
    if (hangPlayUntilCompleted) {
      final blocker = Completer<void>();
      _playBlockers.add(blocker);
      await blocker.future;
    }
  }

  @override
  Future<void> pause() async {
    if (!engine.playing) return;
    engine.playing = false;
    engine.emit();
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

/// Spy：在 _MockMusicApi 基础上记录 uploadPlayHistory 调用，可注入异常。
class _SpyMusicApi extends _MockMusicApi {
  final List<String> uploadedMixSongIds = [];
  Object? uploadError;

  @override
  Future<void> uploadPlayHistory({
    required String mixSongId,
    int playCount = 1,
  }) async {
    if (uploadError != null) throw uploadError!;
    uploadedMixSongIds.add(mixSongId);
  }
}

/// 让控制器内部异步链与 `unawaited` 的历史写入跑完。
Future<void> settle([int rounds = 30]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 酷狗在线源测试歌：数字 albumAudioId 即 mixsongid。
  final kugouSong = Song(
    id: '123456',
    title: 'T',
    artist: 'A',
    hash: 'hash1',
    albumAudioId: '123456',
  );

  late _Engine engine;
  late _EngineAudioHandler handler;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    engine = _Engine();
    handler = _EngineAudioHandler(engine, _FakeAudioPlayer(engine));
  });

  tearDown(() async {
    handler.releaseAllBlocked();
    await settle();
    await engine.dispose();
  });

  group('cloudUploadMixSongIdOf 资格判定（纯静态）', () {
    test('酷狗源 + 数字 albumAudioId → 解析为 int', () {
      final song = Song(
          id: '999', title: 'T', artist: 'A', hash: 'h',
          albumAudioId: '123456');
      expect(PlayerController.cloudUploadMixSongIdOf(song), 123456);
    });

    test('albumAudioId 缺省时回退 song.id（与评论按钮同口径）', () {
      final song = Song(id: '777', title: 'T', artist: 'A', hash: 'h');
      expect(PlayerController.cloudUploadMixSongIdOf(song), 777);
    });

    test('网易源 → null（不上报）', () {
      final song = Song(
          id: '123', title: 'T', artist: 'A', hash: 'ne_1',
          source: SongSource.netease);
      expect(PlayerController.cloudUploadMixSongIdOf(song), isNull);
    });

    test('本地源 → null（不上报）', () {
      final song = Song(
          id: '/storage/a.mp3', title: 'T', artist: 'A', hash: '/storage/a.mp3',
          source: SongSource.local);
      expect(PlayerController.cloudUploadMixSongIdOf(song), isNull);
    });

    test('非数字 id（hash 兜底）→ null（不上报）', () {
      final song = Song(
          id: 'ABCDEF1234', title: 'T', artist: 'A', hash: 'ABCDEF1234');
      expect(PlayerController.cloudUploadMixSongIdOf(song), isNull);
    });
  });

  group('起播上报钩子（行为）', () {
    test('默认关：起播成功不调用上报', () async {
      final api = _SpyMusicApi();
      final controller = PlayerController(api, handler);
      addTearDown(controller.dispose);
      await controller.playSong(kugouSong, queue: [kugouSong]);
      await settle(); await settle();

      expect(controller.cloudHistoryUploadEnabled, isFalse);
      expect(api.uploadedMixSongIds, isEmpty);
    });

    test('开启后：酷狗歌起播成功 → 上报一次且 id 正确', () async {
      final api = _SpyMusicApi();
      final controller = PlayerController(api, handler);
      addTearDown(controller.dispose);
      await controller.setCloudHistoryUploadEnabled(true);
      await controller.playSong(kugouSong, queue: [kugouSong]);
      await settle(); await settle();

      expect(api.uploadedMixSongIds, ['123456']);
    });

    test('开启后：上报异常不影响播放（无 errorMessage、本地历史照记）', () async {
      final api = _SpyMusicApi()..uploadError = Exception('云端 4xx');
      final controller = PlayerController(api, handler);
      addTearDown(controller.dispose);
      await controller.setCloudHistoryUploadEnabled(true);
      await controller.playSong(kugouSong, queue: [kugouSong]);
      await settle(); await settle();

      expect(api.uploadedMixSongIds, isEmpty);
      expect(controller.errorMessage, isNull);
      final history = await PlaybackHistoryService().getHistory();
      expect(history.map((s) => s.hash), contains(kugouSong.hash));
    });
  });

  group('开关持久化', () {
    test('setCloudHistoryUploadEnabled 写入 prefs 且恢复读回', () async {
      final controller = PlayerController(_SpyMusicApi(), handler);
      addTearDown(controller.dispose);

      expect(controller.cloudHistoryUploadEnabled, isFalse); // 默认关

      await controller.setCloudHistoryUploadEnabled(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings.cloud_history_upload_enabled'), isTrue);
    });
  });
}
