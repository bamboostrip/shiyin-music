// 歌词进度偏移（「调整歌词进度」功能的核心状态）：
//   1. 语义：正 = 歌词提前 —— 偏移 +0.5s 让真实进度 10.0s 处显示 10.5s 那一句；
//   2. 夹取：±20 秒，且 lyricPosition 不越出 [0, duration]；
//   3. 持久化：按歌曲 hash 落盘、切歌互不串味、重启后自动带上；
//   4. 同步：偏移变更后桌面歌词（悬浮窗）当前句与逐字进度立刻重推，
//      而不是等下一句才更新。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/player_logic.dart';
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
  }) async {
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
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

/// 三行歌词：0s / 5s / 10s（曲长 30s）。
const _lyrics = [
  LyricLine(time: Duration.zero, text: '第一句'),
  LyricLine(time: Duration(seconds: 5), text: '第二句'),
  LyricLine(time: Duration(seconds: 10), text: '第三句'),
];

const _offsetPrefsKey = 'settings.lyric_offset_per_song';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerLyricOffsetLogic', () {
    test('夹取到 ±limit', () {
      const limit = Duration(seconds: 20);
      expect(
        PlayerLyricOffsetLogic.clamp(const Duration(seconds: 30), limit),
        limit,
      );
      expect(
        PlayerLyricOffsetLogic.clamp(const Duration(seconds: -30), limit),
        -limit,
      );
      expect(
        PlayerLyricOffsetLogic.clamp(
          const Duration(milliseconds: 500),
          limit,
        ).inMilliseconds,
        500,
      );
    });

    test('文案：无偏移 / 歌词提前 / 歌词延后，整数不带小数', () {
      expect(PlayerLyricOffsetLogic.describe(Duration.zero), '无偏移');
      expect(
        PlayerLyricOffsetLogic.describe(const Duration(milliseconds: 500)),
        '歌词提前 0.5 秒',
      );
      expect(
        PlayerLyricOffsetLogic.describe(const Duration(milliseconds: -1500)),
        '歌词延后 1.5 秒',
      );
      expect(
        PlayerLyricOffsetLogic.describe(const Duration(seconds: 2)),
        '歌词提前 2 秒',
      );
    });
  });

  group('PlayerController 歌词进度偏移', () {
    const channel = MethodChannel('shiyin_music/desktop_lyrics');

    late _FakeAudioPlayer fakeAudioPlayer;
    late _FakeAudioHandler handler;
    late PlayerController controller;
    late List<MethodCall> calls;

    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// 推进播放进度（位置流回调 → position/smoothPosition 落定）。
    Future<void> setPosition(Duration value) async {
      fakeAudioPlayer.emitPosition(value);
      await settle();
    }

    MethodCall lastCall(String method) {
      final matches = calls.where((c) => c.method == method).toList();
      expect(
        matches,
        isNotEmpty,
        reason: '未下发 $method 调用，实际=${calls.map((c) => c.method).toList()}',
      );
      return matches.last;
    }

    PlayerController buildController() => PlayerController(_MockMusicApi(), handler);

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // 移动端形态 + Android：桌面歌词走 MethodChannel 分支，便于断言推送。
      debugDesktopFormFactorOverride = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return null;
          });

      fakeAudioPlayer = _FakeAudioPlayer();
      handler = _FakeAudioHandler(fakeAudioPlayer);
      controller = buildController();
      controller.currentSong = _song(1);
      controller.lyrics = _lyrics;
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

    test('偏移为正 = 歌词提前：同一真实进度高亮行提前一行', () async {
      await setPosition(const Duration(milliseconds: 4900));
      expect(controller.activeLyricIndex, 0, reason: '4.9s 还没唱到 5s 的第二句');

      await controller.setLyricOffset(kLyricOffsetStep);

      expect(controller.lyricOffset, kLyricOffsetStep);
      expect(controller.hasLyricOffset, isTrue);
      expect(controller.lyricOffsetLabel, '歌词提前 0.5 秒');
      expect(controller.lyricPosition, const Duration(milliseconds: 5400));
      expect(
        controller.activeLyricIndex,
        1,
        reason: '偏移 +0.5s 后按 5.4s 定位：第二句提前 0.5 秒上屏',
      );
    });

    test('偏移为负 = 歌词延后：同一真实进度高亮行落后一行', () async {
      await setPosition(const Duration(milliseconds: 5200));
      expect(controller.activeLyricIndex, 1);

      await controller.setLyricOffset(-kLyricOffsetStep);

      expect(controller.hasLyricOffset, isTrue);
      expect(controller.lyricOffsetLabel, '歌词延后 0.5 秒');
      expect(controller.activeLyricIndex, 0, reason: '按 4.7s 定位仍停在第一句');

      await controller.resetLyricOffset();
      expect(controller.lyricOffset, Duration.zero);
      expect(controller.hasLyricOffset, isFalse);
      expect(controller.activeLyricIndex, 1);
    });

    test('偏移夹取到 ±20 秒，lyricPosition 不越出 [0, duration]', () async {
      await controller.setLyricOffset(const Duration(seconds: 30));
      expect(controller.lyricOffset, kLyricOffsetLimit);
      await controller.setLyricOffset(const Duration(seconds: -30));
      expect(controller.lyricOffset, -kLyricOffsetLimit);

      // 位置 0 + 负偏移：不能算出负数（否则开头几句永远点不亮）。
      await setPosition(Duration.zero);
      expect(controller.lyricPosition, Duration.zero);

      // 曲长 30s + 正偏移：不能算出曲尾之后（否则高亮会落到不存在的行）。
      await controller.setLyricOffset(kLyricOffsetLimit);
      await setPosition(const Duration(seconds: 25));
      expect(controller.lyricPosition, const Duration(seconds: 30));
    });

    test('按歌曲落盘：切歌互不影响、切回自动还原', () async {
      final song1 = _song(1);
      final song2 = _song(2);
      controller.queue = [song1, song2];

      await controller.playSong(song1, queue: [song1, song2]);
      await settle();
      await controller.setLyricOffset(const Duration(milliseconds: 750));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_offsetPrefsKey), '{"hash_1":750}');

      // 切到没调过的歌：偏移必须归零（否则会拿上一首的修正值错位）。
      await controller.playSong(song2, queue: [song1, song2]);
      await settle();
      expect(controller.lyricOffset, Duration.zero);
      expect(controller.hasLyricOffset, isFalse);

      // 切回：自动带上这首歌自己的偏移。
      await controller.playSong(song1, queue: [song1, song2]);
      await settle();
      expect(controller.lyricOffset, const Duration(milliseconds: 750));
    });

    test('重启后恢复：新控制器播放同一首歌仍带偏移', () async {
      // 故意在构造函数恢复设置还没跑完时就调整：这是真实竞态
      //（用户启动后立刻进详情调进度），恢复流程不得把它抹回 0。
      await controller.setLyricOffset(const Duration(milliseconds: -1000));
      await settle();

      final restored = buildController();
      await settle();
      await restored.playSong(_song(1));
      await settle();

      expect(restored.lyricOffset, const Duration(milliseconds: -1000));
      restored.dispose();
    });

    test('重置即删除记录：新控制器不再带上偏移', () async {
      await controller.setLyricOffset(kLyricOffsetStep);
      await controller.resetLyricOffset();
      await settle();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(_offsetPrefsKey),
        isNull,
        reason: '全部归零应删键，不留空 JSON',
      );

      final restored = buildController();
      await settle();
      await restored.playSong(_song(1));
      await settle();
      expect(restored.lyricOffset, Duration.zero);
      restored.dispose();
    });

    test('偏移变更立即把当前句与逐字进度重推给桌面歌词', () async {
      controller.desktopLyricsEnabled = true;
      controller.setAppForeground(false);
      await settle();
      expect(lastCall('show').arguments['current'], '第一句');

      await setPosition(const Duration(milliseconds: 4900));
      calls.clear();

      await controller.setLyricOffset(kLyricOffsetStep);
      await settle();

      // 换句文本：当前句换成第二句（不能等下一次位置回调）。
      expect(lastCall('updateLyrics').arguments['current'], '第二句');
      expect(lastCall('updateLyrics').arguments['next'], '第三句');
      // 逐字进度也按新的行重推（progress 属于新句的起点附近）。
      expect(
        calls.map((c) => c.method),
        contains('updateKaraokeProgress'),
        reason: '偏移变更后卡拉OK进度必须跟着换行重推',
      );
    });

    test('桌面歌词悬浮窗的进度指令落到同一份偏移状态', () async {
      // 悬浮窗快捷菜单的「歌词进度」三键走既有 controlPlayback 动作通道
      //（参数是动作名字符串），主窗据此调整同一份 lyricOffset。
      const codec = StandardMethodCodec();
      Future<void> sendAction(String action) async {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              codec.encodeMethodCall(MethodCall('controlPlayback', action)),
              (ByteData? data) {},
            );
        await settle();
      }

      await sendAction('lyricOffsetEarlier');
      expect(controller.lyricOffset, kLyricOffsetStep);

      await sendAction('lyricOffsetLater');
      expect(controller.lyricOffset, Duration.zero);

      await sendAction('lyricOffsetEarlier');
      await sendAction('lyricOffsetReset');
      expect(controller.lyricOffset, Duration.zero);
      expect(controller.hasLyricOffset, isFalse);
    });
  });
}
