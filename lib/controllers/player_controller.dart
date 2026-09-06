import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';
import '../services/audio_effects_service.dart';
import '../services/cache_service.dart';
import '../services/bluetooth_lyrics_service.dart';
import '../services/desktop_lyrics_service.dart';
import '../services/loudness_service.dart';
import '../services/music_api.dart';
import '../services/music_audio_handler.dart';
import '../services/network_monitor.dart';
import '../services/playback_history_service.dart';
import '../services/playback_stats_service.dart';
import '../services/super_lyric_service.dart';
import '../services/vip_background_task.dart';
import '../ui/form_factor.dart';
import 'download_controller.dart';
import 'local_music_controller.dart';
import 'player_logic.dart';
import 'shuffle_queue.dart';

part 'player_controller.playback.dart';
part 'player_controller.queue.dart';
part 'player_controller.lyrics.dart';
part 'player_controller.effects.dart';
part 'player_controller.desktop.dart';
part 'player_controller.settings.dart';

enum PlaybackMode { playlistLoop, shuffle, singleLoop }

class AudioEffectPreset {
  const AudioEffectPreset({required this.name, required this.levels});

  final String name;
  final List<int> levels;
}

// PlayerController 的私有设置键/常量（原类内 static const，拆分后提升为库级常量，
// 仅同库可见，引用方式不变）。
const _listenTimeSettingKey = 'settings.add_listening_time_enabled';
const _audioQualitySettingKey = 'settings.audio_quality';
const _equalizerEnabledSettingKey = 'settings.equalizer_enabled';
const _equalizerLevelsSettingKey = 'settings.equalizer_levels';
const _equalizerPresetSettingKey = 'settings.equalizer_preset';
const _bassBoostEnabledSettingKey = 'settings.bass_boost_enabled';
const _bassBoostStrengthSettingKey = 'settings.bass_boost_strength';
const _audioInterruptionEnabledSettingKey =
    'settings.audio_interruption_enabled';
const _autoResumeAfterInterruptionSettingKey =
    'settings.auto_resume_after_interruption';
const _playbackSpeedSettingKey = 'settings.playback_speed';
const _desktopLyricsEnabledSettingKey = 'settings.desktop_lyrics_enabled';
const _desktopLyricsSettingsKey = 'settings.desktop_lyrics_settings';
// 桌面歌词设置版本号：v2 起默认透明悬浮（opacity 0.0/字号 24）。
// 老版本持久化的是旧默认值（0.8/16），不做迁移会盖掉代码新默认，
// 表现为“样式改了但重启无效”。版本对不上时丢弃旧值，用代码默认。
const _desktopLyricsSettingsVersionKey =
    'settings.desktop_lyrics_settings_version';
const _desktopLyricsSettingsVersion = 2;
const _smartQualitySettingKey = 'settings.smart_quality_enabled';
const _allowCellularPrecacheSettingKey = 'settings.allow_cellular_precache';
const _autoPlayOnStartupSettingKey = 'settings.auto_play_on_startup';
const _autoPlayOnDeviceConnectedSettingKey =
    'settings.auto_play_on_device_connected';
const _bluetoothLyricsEnabledSettingKey = 'settings.bluetooth_lyrics_enabled';
const _playbackStateKey = 'playback_state';
const _playbackStateMaxQueueSize = 200;
const _listenTimeReportInterval = Duration(minutes: 30);
const _listenTimeCheckInterval = Duration(minutes: 1);
const _defaultEqualizerLevels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

/// 播放器控制器：状态拆分见 [_PlayerControllerBase]，职责分片见各 part 文件。
class PlayerController extends _PlayerControllerBase
    with
        _PlayerPlayback,
        _PlayerQueue,
        _PlayerLyrics,
        _PlayerEffects,
        _PlayerDesktop,
        _PlayerSettings {
  static const equalizerPresets = [
    AudioEffectPreset(name: '平直', levels: _defaultEqualizerLevels),
    AudioEffectPreset(
      name: '流行',
      levels: [0, 250, 450, 350, 100, -100, 50, 300, 450, 500],
    ),
    AudioEffectPreset(
      name: '摇滚',
      levels: [500, 350, 150, -100, -250, -150, 150, 350, 550, 650],
    ),
    AudioEffectPreset(
      name: '人声',
      levels: [-250, -150, 0, 250, 500, 550, 350, 100, -100, -200],
    ),
    AudioEffectPreset(
      name: '低音',
      levels: [750, 650, 500, 250, 0, -100, -150, -200, -250, -300],
    ),
    AudioEffectPreset(
      name: '古典',
      levels: [350, 250, 100, 0, 150, 250, 300, 350, 250, 100],
    ),
    AudioEffectPreset(
      name: '电子',
      levels: [650, 450, 120, -120, -180, 100, 350, 550, 650, 700],
    ),
  ];

  PlayerController(super.api, super.audioHandler) {
    unawaited(_restoreSettings());
    unawaited(_restorePlaybackState());
    // 车机切网（WiFi ↔ 蜂窝 ↔ 离线）后恢复网络时，若上一首因断网停在
    // 错误态，自动重播一次；isRetry 防止失败后再次触发形成循环。
    _networkRestoredSub = NetworkMonitor.instance.onConnectivityRestored.listen(
      (_) {
        if (isPreparing || errorMessage == null) return;
        final song = currentSong;
        if (song == null) return;
        debugPrint('[时音][player] 网络已恢复，自动重播: ${song.title}');
        unawaited(playSong(song, isRetry: true));
      },
    );
    _audioHandler.attachTransportControls(onNext: next, onPrevious: previous);
    _desktopLyrics.setVisibilityChangedHandler(_handleDesktopLyricsVisibility);
    _desktopLyrics.setPlaybackActionHandler(_handleDesktopLyricsPlaybackAction);
    _desktopLyrics.setLockChangedHandler(_handleDesktopLyricsLockChanged);
    _positionSub = audioPlayer.positionStream.listen((value) {
      if (_pendingInitialPosition != null) {
        // 音频正在加载且指定了起播偏移量，忽略底层引擎加载音频源时的初始 0 秒回调，
        // 防止进度条与歌词闪回 0 秒
        return;
      }
      if (!_isSeeking) {
        _setPositionBase(value, playing: isPlaying);
      }
      _maybeCompleteFromPosition(value);
      _maybeStopClimaxPreview(value);
      _maybePrecacheNext(value);
      _maybeSyncDesktopLyricFromPosition();
      _syncSuperLyricFromPosition();
      _syncBluetoothLyricsFromPosition();
      // 进度只通知 positionListenable，避免整页 AnimatedBuilder(player) 每 tick 重建。
      _emitPosition();
    });
    // Send timing anchors; Android animates karaoke progress at display refresh.
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      if (_shouldShowDesktopLyrics &&
          isPlaying &&
          lyrics.isNotEmpty &&
          !_isScrubbing) {
        _syncDesktopKaraokeProgress();
      }
    });
    _durationSub = audioPlayer.durationStream.listen((value) {
      // 恢复占位保护：引擎无音频源时的 null 回调不清空歌曲元数据占位时长，
      // 真实音频加载后非 null 值会正常覆盖。
      if (value == null) return;
      duration = value;
      _emitPosition();
      notifyListeners();
    });
    _stateSub = audioPlayer.playerStateStream.listen((value) {
      isPlaying = value.playing;
      isBuffering =
          value.processingState == ProcessingState.loading ||
          value.processingState == ProcessingState.buffering;
      // 与 positionStream 同理：指定起播偏移量的加载过程中，引擎 position 归 0，
      // 此时不能用引擎位置重建平滑基线，否则歌词与进度条先闪回开头再跳回目标。
      if (!_isSeeking && _pendingInitialPosition == null) {
        _setPositionBase(audioPlayer.position, playing: isPlaying);
      }
      _syncListeningTimeTracker();
      _syncDesktopPlayState();
      _syncSuperLyricFromPosition();
      _syncBluetoothLyricsFromPosition();
      _emitPosition();
      notifyListeners();
    });
    _processingStateSub = audioPlayer.processingStateStream.distinct().listen((
      state,
    ) {
      if (state == ProcessingState.completed) {
        if (!_isChangingSource) {
          unawaited(_handleCompleted());
        }
      }
    });
    _androidAudioSessionSub = audioPlayer.androidAudioSessionIdStream.listen((
      sessionId,
    ) {
      _androidAudioSessionId = sessionId;
      unawaited(_refreshEqualizerConfig());
      unawaited(_applyEqualizer());
      unawaited(_applyBassBoost());
      unawaited(_applyLoudnessGain());
    });
    unawaited(_setupAudioSessionListeners());
    unawaited(_loudness.init());
    unawaited(_superLyric.registerPublisher());
  }

  Duration? get climaxEndTime => _climaxEndTime;

  bool get isBluetoothLyricsSupported =>
      BluetoothLyricsService.isSupportedPlatform;

  bool get isScrubbing => _isScrubbing;

  @override
  void dispose() {
    _disposed = true;
    _pauseListeningTimeTracker();
    _networkRestoredSub?.cancel();
    _autoResumeTimer?.cancel();
    _sleepTimer?.cancel();
    _positionSub.cancel();
    _durationSub.cancel();
    _stateSub.cancel();
    _processingStateSub.cancel();
    _androidAudioSessionSub.cancel();
    _interruptionSub?.cancel();
    _becomingNoisySub?.cancel();
    _devicesSub?.cancel();
    _completionFallbackTimer?.cancel();
    _saveStateTimer?.cancel();
    _desktopLyrics.setVisibilityChangedHandler(null);
    _desktopLyrics.setPlaybackActionHandler(null);
    _desktopLyrics.setLockChangedHandler(null);
    positionListenable.dispose();
    unawaited(
      _audioEffects.configureEqualizer(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        levels: equalizerLevels,
      ),
    );
    unawaited(
      _audioEffects.configureBassBoost(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        strength: bassBoostStrength,
      ),
    );
    unawaited(_loudness.cancelAnalysis());
    unawaited(_loudness.releaseNative());
    unawaited(_superLyric.unregisterPublisher());
    _audioHandler.detachTransportControls();
    _desktopLyrics.setVisibilityChangedHandler(null);
    unawaited(_audioHandler.close());
    unawaited(_desktopLyrics.hide());
    super.dispose();
  }
}

/// PlayerController 的可变状态基座：全部字段与状态派生的基础成员集中于此，
/// 供同库 part 文件中的职责 mixin（on 本类）与 PlayerController 自身直接访问
/// （同库私有，零可见性改动）。
/// 跨分片引用的方法在此声明为抽象契约，由各职责 mixin 提供实现。
abstract class _PlayerControllerBase extends ChangeNotifier {
  _PlayerControllerBase(this._api, this._audioHandler);

  /// 下载控制器（由 main.dart 在创建后注入，供 UI 访问下载功能）。
  DownloadController? downloadController;

  /// 缓存服务（由 main.dart 在创建后注入，用于歌词等缓存）。
  CacheService? cacheService;

  /// 本地音乐控制器（由 main.dart 在创建后注入，用于读取内嵌歌词等）。
  LocalMusicController? localMusic;

  /// VIP 领取任务（由 main.dart 在创建后注入，用于播放时按需领取 VIP）。
  VipBackgroundTask? vipClaim;

  final MusicApi _api;
  final MusicAudioHandler _audioHandler;
  final AudioEffectsService _audioEffects = AudioEffectsService();
  final DesktopLyricsService _desktopLyrics = DesktopLyricsService();
  final PlaybackHistoryService _historyService = PlaybackHistoryService();
  final PlaybackStatsService _statsService = PlaybackStatsService();
  final LoudnessService _loudness = LoudnessService();
  final SuperLyricService _superLyric = SuperLyricService();
  final BluetoothLyricsService _bluetoothLyrics = BluetoothLyricsService();
  double? _pendingGainDb; // 当前歌曲分析得到的待应用增益(dB)
  // 切歌竞态守卫:每次发起分析递增,回调比对序号,不一致则丢弃旧结果。
  int _loudnessSerial = 0;
  // 当前歌曲实际播放 URL,供"开关开启时分析当前歌曲"复用,避免重新解析。
  String? _currentLoudnessUrl;
  // 渡口效应缓解:分析开始后前 3s(墙钟时间)的中途增益做 EMA 低通滤波。
  // 问题:渡口等歌前奏安静,初步 LUFS 偏低 → 增益被推到 +6dB 极限,
  // 随分析推进 LUFS 回升 → 增益砸回 +1.69dB,用户听到大幅跳变。
  // 方案:墙钟时间 3s 内的中途增益做 EMA(α=0.3),平滑掉前奏导致的剧烈跳变。
  // 用墙钟而非音频时长:解码 27x 快,3s 音频 ~110ms 就解码完,按音频时长滤波
  // 窗口在用户听到第一个进度时就已关闭。按墙钟则覆盖用户实际听到的前 3 秒。
  // 最终值(isFinal)不滤波,保证精度。
  // _emaGainDb 为 null 表示尚未初始化(首次中途值直接采用,不滤波)。
  double? _emaGainDb;
  // 分析开始的墙钟时间戳,用于判断是否在 EMA 滤波窗口内。
  DateTime? _emaStartWallTime;

  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration?> _durationSub;
  late final StreamSubscription<PlayerState> _stateSub;
  late final StreamSubscription<ProcessingState> _processingStateSub;
  late final StreamSubscription<int?> _androidAudioSessionSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  StreamSubscription<void>? _networkRestoredSub;
  StreamSubscription<Set<AudioDevice>>? _devicesSub;
  Set<AudioDevice>? _previousDevices;
  final Stopwatch _positionClock = Stopwatch();
  // 平滑位置的上一次取值：用于过滤位置流的小幅倒退（音频缓冲/时钟抖动），
  // 避免歌词高亮和卡拉OK进度出现回跳。seek/换歌的大跨度回退会重建基线。
  Duration _lastSmoothPosition = Duration.zero;
  final _shuffleQueue = ShuffleQueue();

  /// 高潮试听结束时间（播放到该时间自动暂停）。
  Duration? _climaxEndTime;

  /// 当前歌曲的高潮片段时间（用于进度条标记），可能为 null。
  SongClimax? climax;
  Timer? _completionFallbackTimer;
  Timer? _listenTimeTimer;
  DateTime? _listenTimeStartedAt;
  Duration _pendingListenTime = Duration.zero;
  bool _isReportingListenTime = false;
  int _seekSerial = 0;
  bool _isSeeking = false;
  bool _isScrubbing = false;
  bool _isHandlingCompletion = false;
  String? _completedSongHash;
  String? _precachedForSongHash;
  bool _isPrecaching = false;
  bool _isAppForeground = true;
  bool _desktopLyricsPreviewVisible = false;
  Duration? _pendingIdlePosition;
  Duration? _pendingInitialPosition;
  bool _disposed = false;

  Song? currentSong;
  List<Song> queue = const [];
  List<LyricLine> lyrics = const [];
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  /// 播放进度专用通知（高频）。UI 进度条应监听此对象，勿依赖 [notifyListeners]。
  final ValueNotifier<Duration> positionListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  bool isPlaying = false;
  bool isBuffering = false;
  bool isPreparing = false;

  /// 换源深度计数（并发 playSong 各自持有 +1/-1）。
  ///
  /// 曾经是共享 bool：快速连点切歌时，先启动的 playSong 在 await 中被
  /// 后启动者抢先，其 finally 会把后者仍需的"换源中"状态提前清除，
  /// completed 守卫失效。计数化后状态只在最后一个在途加载结束时归零。
  int _changingSourceDepth = 0;
  bool addListeningTimeEnabled = true;
  AudioQuality audioQuality = AudioQuality.standard;

  /// 是否开启音质智能切换（播放失败时自动降级重试）。
  bool smartQualityEnabled = false;

  /// 移动数据下是否允许后台缓存（下一首预缓存 + 播后缓存）。
  ///
  /// 默认 false = 仅 WiFi/有线/未知网络预缓存，蜂窝网络只预取歌词
  /// （歌词几 KB 不计），不下载音频（几十 MB），避免移动流量翻倍。
  bool allowCellularPrecache = false;

  /// 当前网络是否允许后台下载音频（预缓存 + 播后缓存）。
  ///
  /// 默认仅 WiFi/有线/未知网络允许；蜂窝网络需用户显式放行
  /// （[allowCellularPrecache]）。未知网络（单测/桌面无 NM 环境）
  /// 按放行处理，避免误杀。
  bool get isAudioPrecacheAllowed =>
      allowCellularPrecache || !NetworkMonitor.instance.isCellular;
  bool autoPlayOnStartupEnabled = false;
  bool hasRestoredPlaybackState = false;
  double playbackSpeed = 1.0;
  bool equalizerEnabled = false;
  List<int> equalizerLevels = List<int>.of(_defaultEqualizerLevels);
  String equalizerPresetName = '平直';
  EqualizerConfig equalizerConfig = EqualizerConfig.fallback(
    _defaultEqualizerLevels,
  );
  bool bassBoostEnabled = false;
  double bassBoostStrength = 0.45;
  bool audioInterruptionEnabled = true;
  bool autoResumeAfterInterruption = false;
  bool autoPlayOnDeviceConnected = false;
  bool bluetoothLyricsEnabled = false;
  bool desktopLyricsEnabled = false;
  DesktopLyricsSettings desktopLyricsSettings = const DesktopLyricsSettings();

  // SuperLyric/蓝牙歌词同步状态
  int _lastSuperLyricIndex = -1;
  bool _lastSuperLyricPlaying = false;
  int _lastBluetoothLyricIndex = -1;
  bool _lastBluetoothPlaying = false;
  int _lastDesktopLyricIndex = -1;

  Timer? _autoResumeTimer;
  Duration? sleepTimerRemaining;
  Timer? _sleepTimer;
  Timer? _saveStateTimer;
  DateTime? _sleepTimerEnd;
  bool _sleepFinishCurrentSong = false;
  bool _sleepFinishCurrentSongOption = false;
  String? errorMessage;
  int? _androidAudioSessionId;

  bool get _isChangingSource => _changingSourceDepth > 0;

  AudioPlayer get audioPlayer => _audioHandler.audioPlayer;

  MusicApi get api => _api;

  int get currentIndex {
    final song = currentSong;
    if (song == null) {
      return -1;
    }
    return queue.indexWhere((item) => item.hash == song.hash);
  }

  int get activeLyricIndex =>
      PlayerLyricLogic.activeIndex(lyrics, smoothPosition);

  Duration? _estimatedLineDuration(int index) =>
      PlayerLyricLogic.estimatedLineDuration(lyrics, duration, index);

  Duration get smoothPosition {
    final raw = _isScrubbing
        ? position
        : (!isPlaying ? position : position + _positionClock.elapsed);
    var value = raw;
    if (value < Duration.zero) {
      value = Duration.zero;
    } else if (duration > Duration.zero && value > duration) {
      value = duration;
    }
    if (_isScrubbing) {
      // 拖动进度条时位置必须严格跟随手指。
      _lastSmoothPosition = value;
      return value;
    }
    if (value < _lastSmoothPosition) {
      if (_lastSmoothPosition - value > const Duration(milliseconds: 250)) {
        // 明显回退：视为 seek 或切歌，直接重建基线。
        _lastSmoothPosition = value;
      }
    } else {
      _lastSmoothPosition = value;
    }
    return _lastSmoothPosition;
  }

  void _setPositionBase(Duration value, {required bool playing}) {
    position = _clampPosition(value);
    _positionClock
      ..stop()
      ..reset();
    if (playing) {
      _positionClock.start();
    }
  }

  void _emitPosition() {
    final next = smoothPosition;
    if (positionListenable.value != next) {
      positionListenable.value = next;
    }
  }

  Duration _clampPosition(Duration value) =>
      PlayerPositionLogic.clamp(value, duration);

  // ---- 跨职责分片的成员契约（由各 part 文件的职责 mixin 实现）----

  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
  });

  Future<void> togglePlay();

  Future<void> seek(Duration position);

  Future<void> next();

  Future<void> previous();

  Song? _nextSong({bool peek = false}) {
    if (queue.isEmpty) {
      return currentSong;
    }

    final index = currentIndex;
    if (playbackMode == PlaybackMode.shuffle) {
      if (queue.length == 1) return queue.first;
      final nextIndex = peek
          ? _shuffleQueue.peekNext(queue.length)
          : _shuffleQueue.next(queue.length);
      if (nextIndex >= 0 && nextIndex < queue.length) {
        return queue[nextIndex];
      }
      return queue.first;
    }

    if (index >= 0 && index < queue.length - 1) {
      return queue[index + 1];
    }

    return queue.first;
  }

  Future<void> loadLyrics(Song song);

  void _syncDesktopLyrics();

  Future<void> _syncDesktopLyricsVisibility();

  void _scheduleSavePlaybackState();

  Future<PlayUrl> _resolvePlayUrl(Song song);

  Future<void> _loadClimax(Song song);

  /// VIP 过期领取后重试（playback 分片实现，settings 的切音质路径复用）。
  Future<bool> _tryClaimVipAndRetry(
    Song song, {
    List<Song>? queue,
    Duration? initialPosition,
    bool preserveClimax,
  });

  Future<void> _refreshEqualizerConfig();

  Future<void> _applyEqualizer();

  Future<void> _applyBassBoost();

  Future<void> _analyzeAndApplyLoudness({
    required Song song,
    required String url,
  });

  Future<void> _applyLoudnessGain({bool instant = false});
}
