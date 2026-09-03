import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
import 'download_controller.dart';
import 'local_music_controller.dart';
import 'shuffle_queue.dart';

enum PlaybackMode { playlistLoop, shuffle, singleLoop }

class AudioEffectPreset {
  const AudioEffectPreset({required this.name, required this.levels});

  final String name;
  final List<int> levels;
}

class PlayerController extends ChangeNotifier {
  static const _listenTimeSettingKey = 'settings.add_listening_time_enabled';
  static const _audioQualitySettingKey = 'settings.audio_quality';
  static const _equalizerEnabledSettingKey = 'settings.equalizer_enabled';
  static const _equalizerLevelsSettingKey = 'settings.equalizer_levels';
  static const _equalizerPresetSettingKey = 'settings.equalizer_preset';
  static const _bassBoostEnabledSettingKey = 'settings.bass_boost_enabled';
  static const _bassBoostStrengthSettingKey = 'settings.bass_boost_strength';
  static const _audioInterruptionEnabledSettingKey =
      'settings.audio_interruption_enabled';
  static const _autoResumeAfterInterruptionSettingKey =
      'settings.auto_resume_after_interruption';
  static const _playbackSpeedSettingKey = 'settings.playback_speed';
  static const _desktopLyricsEnabledSettingKey =
      'settings.desktop_lyrics_enabled';
  static const _desktopLyricsSettingsKey = 'settings.desktop_lyrics_settings';
  static const _smartQualitySettingKey = 'settings.smart_quality_enabled';
  static const _autoPlayOnStartupSettingKey = 'settings.auto_play_on_startup';
  static const _autoPlayOnDeviceConnectedSettingKey =
      'settings.auto_play_on_device_connected';
  static const _bluetoothLyricsEnabledSettingKey =
      'settings.bluetooth_lyrics_enabled';
  static const _playbackStateKey = 'playback_state';
  static const _playbackStateMaxQueueSize = 200;
  static const _listenTimeReportInterval = Duration(minutes: 30);
  static const _listenTimeCheckInterval = Duration(minutes: 1);
  static const _defaultEqualizerLevels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
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

  /// 下载控制器（由 main.dart 在创建后注入，供 UI 访问下载功能）。
  DownloadController? downloadController;

  /// 缓存服务（由 main.dart 在创建后注入，用于歌词等缓存）。
  CacheService? cacheService;

  /// 本地音乐控制器（由 main.dart 在创建后注入，用于读取内嵌歌词等）。
  LocalMusicController? localMusic;

  /// VIP 领取任务（由 main.dart 在创建后注入，用于播放时按需领取 VIP）。
  VipBackgroundTask? vipClaim;

  PlayerController(this._api, this._audioHandler) {
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
    _positionSub = audioPlayer.positionStream.listen((value) {
      if (!_isSeeking) {
        _setPositionBase(value, playing: isPlaying);
      }
      _maybeCompleteFromPosition(value);
      _maybeStopClimaxPreview(value);
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
      duration = value ?? Duration.zero;
      _emitPosition();
      notifyListeners();
    });
    _stateSub = audioPlayer.playerStateStream.listen((value) {
      isPlaying = value.playing;
      isBuffering =
          value.processingState == ProcessingState.loading ||
          value.processingState == ProcessingState.buffering;
      if (!_isSeeking) {
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

  AudioPlayer get audioPlayer => _audioHandler.audioPlayer;

  MusicApi get api => _api;

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
  bool _isAppForeground = true;
  bool _desktopLyricsPreviewVisible = false;

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
  bool _isChangingSource = false;
  bool addListeningTimeEnabled = true;
  AudioQuality audioQuality = AudioQuality.standard;

  /// 是否开启音质智能切换（播放失败时自动降级重试）。
  bool smartQualityEnabled = false;
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
  bool get isBluetoothLyricsSupported =>
      BluetoothLyricsService.isSupportedPlatform;

  // SuperLyric/蓝牙歌词同步状态
  int _lastSuperLyricIndex = -1;
  bool _lastSuperLyricPlaying = false;
  int _lastBluetoothLyricIndex = -1;
  bool _lastBluetoothPlaying = false;
  Timer? _autoResumeTimer;
  Duration? sleepTimerRemaining;
  Timer? _sleepTimer;
  Timer? _saveStateTimer;
  DateTime? _sleepTimerEnd;
  bool _sleepFinishCurrentSong = false;
  bool _sleepFinishCurrentSongOption = false;
  String? errorMessage;
  int seekRevision = 0;
  int? _androidAudioSessionId;
  bool get isScrubbing => _isScrubbing;

  /// 当前音量（0.0–1.0）。桌面播放栏音量滑杆使用。
  double get volume => _audioHandler.audioPlayer.volume;

  /// 设置音量（0.0–1.0），越界值自动夹取。
  Future<void> setVolume(double value) =>
      _audioHandler.audioPlayer.setVolume(value.clamp(0.0, 1.0));

  bool get isAudioEffectsSupported => _audioEffects.isAudioEffectsSupported;
  bool get isBassBoostSupported => _audioEffects.isBassBoostSupported;
  bool get loudnessEnabled => _loudness.isEnabled;
  bool get isLoudnessAnalysisSupported => _loudness.isAnalysisSupported;
  String get audioEffectsLabel {
    if (!isAudioEffectsSupported) {
      return '当前平台暂不支持';
    }
    if (equalizerEnabled) {
      return '均衡器：$equalizerPresetName';
    }
    if (bassBoostEnabled) {
      return 'Bass ${(bassBoostStrength * 100).round()}%';
    }
    return '关闭';
  }

  String get playbackSpeedLabel {
    if (playbackSpeed == playbackSpeed.roundToDouble()) {
      return '${playbackSpeed.round()}x';
    }
    return '${playbackSpeed}x';
  }

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

  int get currentIndex {
    final song = currentSong;
    if (song == null) {
      return -1;
    }
    return queue.indexWhere((item) => item.hash == song.hash);
  }

  int get activeLyricIndex {
    if (lyrics.isEmpty) {
      return -1;
    }
    var index = 0;
    for (var i = 0; i < lyrics.length; i++) {
      if (smoothPosition >= lyrics[i].time) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  String get playbackModeLabel {
    return switch (playbackMode) {
      PlaybackMode.playlistLoop => '歌单循环',
      PlaybackMode.shuffle => '随机播放',
      PlaybackMode.singleLoop => '单曲循环',
    };
  }

  PlaybackMode cyclePlaybackMode() {
    playbackMode = switch (playbackMode) {
      PlaybackMode.playlistLoop => PlaybackMode.shuffle,
      PlaybackMode.shuffle => PlaybackMode.singleLoop,
      PlaybackMode.singleLoop => PlaybackMode.playlistLoop,
    };
    if (playbackMode == PlaybackMode.shuffle) {
      _shuffleQueue.reset(queue.length, currentIndex: currentIndex);
    }
    _scheduleSavePlaybackState();
    notifyListeners();
    return playbackMode;
  }

  Future<void> setAddListeningTimeEnabled(bool enabled) async {
    if (addListeningTimeEnabled == enabled) {
      return;
    }
    addListeningTimeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_listenTimeSettingKey, enabled);
    if (!enabled) {
      _resetListeningTimeTracker();
    } else {
      _syncListeningTimeTracker();
    }
    notifyListeners();
  }

  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
  }) async {
    _climaxEndTime = null;
    climax = null;
    _completionFallbackTimer?.cancel();
    _completedSongHash = null;
    _lastSmoothPosition = Duration.zero;
    isPreparing = true;
    _isChangingSource = true;
    errorMessage = null;
    currentSong = song;
    final queueChanged = queue != null && !listEquals(this.queue, queue);
    if (queue != null && queue.isNotEmpty) {
      this.queue = queue;
    } else if (this.queue.isEmpty) {
      this.queue = [song];
    }
    if (playbackMode == PlaybackMode.shuffle) {
      final songIndex = this.queue.indexWhere((item) => item.hash == song.hash);
      if (queueChanged || _shuffleQueue.length != this.queue.length) {
        _shuffleQueue.reset(
          this.queue.length,
          currentIndex: songIndex >= 0 ? songIndex : 0,
        );
      } else if (songIndex >= 0) {
        _shuffleQueue.syncCurrentIndex(this.queue.length, songIndex);
      }
    }
    lyrics = const [];
    _lastDesktopLyricIndex = -1;
    notifyListeners();
    // 预缓存封面图，避免打开播放页时出现纯色背景闪烁
    _precacheCover(song);
    unawaited(_syncDesktopLyricsVisibility());
    // 切歌:取消上一首可能在途的响度分析,避免旧分析空跑占 CPU。
    // 序号守卫也会丢弃旧结果,但取消能立即停掉原生解码线程。
    unawaited(_loudness.cancelAnalysis());
    // 异步预取高潮片段时间，用于进度条标记（失败静默）。
    unawaited(_loadClimax(song));

    try {
      String url;
      String? networkUrl;
      final local = downloadController?.localPathFor(song, audioQuality);
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final playUrl = await _resolvePlayUrl(song);
        if (playUrl.url.isEmpty) {
          throw Exception(
            song.isCloudDrive
                ? '云盘歌曲暂时没有可播放地址'
                : song.source == SongSource.netease
                ? '网易云歌曲暂时没有可播放地址'
                : '这首歌暂时没有可播放地址',
          );
        }
        url = playUrl.url;
        networkUrl = playUrl.url;
      }
      // 响度均衡:先查缓存,命中则首播前即应用正确增益(instant,无跳变);
      // 未命中则播放中分析,完成后渐变(ramp)应用。
      _currentLoudnessUrl = url;
      final pre = _loudness.gainFromCache(song.hash);
      if (pre.fromCache) {
        _pendingGainDb = pre.gainDb;
        unawaited(_applyLoudnessGain(instant: true));
      }
      unawaited(_analyzeAndApplyLoudness(song: song, url: url));
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: this.queue,
        queueIndex: currentIndex,
      );
      isPreparing = false;
      notifyListeners();
      unawaited(loadLyrics(song));
      await _audioHandler.play();
      // 记录播放历史与本地播放统计（后台执行，不阻塞播放）
      unawaited(_historyService.record(song));
      unawaited(_statsService.recordPlay(song));
      // 首播后后台缓存（仅当本次用的是网络 URL）
      if (networkUrl != null) {
        unawaited(
          downloadController?.cacheForPlayback(song, audioQuality, networkUrl),
        );
      }
    } catch (error) {
      // VIP 过期：自动领取后重试一次
      if (error is VipRequiredException && vipClaim != null) {
        final claimed = await _tryClaimVipAndRetry(song);
        if (claimed) return;
      }
      // 网络类失败（非 VIP、非首次重试）：短暂等待后自动重试一次。
      // 车机弱网/网络切换瞬间首次请求常失败，重试后即可恢复；
      // 确定性错误（如"没有可播放地址"）重试成本低，统一兜底一次。
      if (!isRetry && error is! VipRequiredException) {
        errorMessage = '播放失败，正在重试...';
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 2));
        debugPrint('[时音][player] 播放失败，自动重试: ${song.title} ($error)');
        await playSong(song, queue: queue, isRetry: true);
        return;
      }
      errorMessage = error.toString();
      isPreparing = false;
      notifyListeners();
    } finally {
      _isChangingSource = false;
      if (isPreparing) {
        isPreparing = false;
        notifyListeners();
      }
      _scheduleSavePlaybackState();
    }
  }

  /// 预缓存歌曲封面到 Flutter ImageCache，打开播放页时可立即显示。
  void _precacheCover(Song song) {
    final coverUrl = song.coverUrl;
    if (coverUrl == null || coverUrl.isEmpty) return;
    if (coverUrl.startsWith('content://')) return;
    final provider = ResizeImage(
      NetworkImage(coverUrl),
      width: 150,
      height: 150,
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    stream.addListener(ImageStreamListener((_, _) {}, onError: (_, _) {}));
  }

  /// 解析播放地址。
  ///
  /// - 云盘歌曲走 [MusicApi.cloudSongUrl]
  /// - 网易云歌曲使用外链地址
  /// - 其它歌曲走 [MusicApi.songUrl]，开启智能音质时在网络请求失败
  ///   或返回空地址时自动降级重试（lossless -> high -> standard）。
  Future<PlayUrl> _resolvePlayUrl(Song song) async {
    if (song.source == SongSource.local) {
      return PlayUrl(url: song.id, hash: song.hash);
    }
    if (song.isCloudDrive) {
      return _api.cloudSongUrl(song);
    }
    if (song.source == SongSource.netease) {
      // 网易云歌曲使用外链播放地址
      return PlayUrl(
        url: 'https://music.163.com/song/media/outer/url?id=${song.id}.mp3',
        hash: song.hash,
      );
    }

    try {
      final playUrl = await _api.songUrl(song, quality: audioQuality);
      if (playUrl.url.isNotEmpty || !smartQualityEnabled) {
        return playUrl;
      }
      // 返回空地址：按智能音质策略降级重试
      final fallback = _nextLowerQuality(audioQuality);
      if (fallback == null) return playUrl;
      return _api.songUrl(song, quality: fallback);
    } catch (error) {
      if (!smartQualityEnabled) rethrow;
      // 网络请求失败：尝试降级重试
      final fallback = _nextLowerQuality(audioQuality);
      if (fallback == null) rethrow;
      try {
        final retryUrl = await _api.songUrl(song, quality: fallback);
        if (retryUrl.url.isNotEmpty) {
          debugPrint(
            '[时音][smart-quality] ${audioQuality.badge} 失败，'
            '已降级为 ${fallback.badge}',
          );
          return retryUrl;
        }
      } catch (_) {
        // 降级也失败，抛出原始错误
      }
      rethrow;
    }
  }

  /// VIP 过期时自动领取并重试播放，成功返回 true。
  Future<bool> _tryClaimVipAndRetry(Song song) async {
    try {
      final result = await vipClaim!.claimNow(null);
      if (result.status == VipClaimStatus.success ||
          result.status == VipClaimStatus.alreadyClaimed) {
        debugPrint('[时音][player] VIP 已领取，重试播放: ${song.title}');
        final playUrl = await _api.songUrl(song, quality: audioQuality);
        if (playUrl.url.isNotEmpty) {
          errorMessage = null;
          // 重新走完整播放流程
          unawaited(playSong(song));
          return true;
        }
      }
    } catch (e) {
      debugPrint('[时音][player] VIP 领取/重试失败: $e');
    }
    return false;
  }

  /// 返回更低一档的音质；已是最低档时返回 null。
  AudioQuality? _nextLowerQuality(AudioQuality quality) {
    switch (quality) {
      case AudioQuality.lossless:
        return AudioQuality.high;
      case AudioQuality.high:
        return AudioQuality.standard;
      case AudioQuality.standard:
        return null;
    }
  }

  Future<bool> addToQueue(Song song) async {
    final added = await addSongsToQueue([song]);
    return added > 0;
  }

  /// 批量插入到「下一首」位置，只更新一次队列与系统媒体会话。
  /// 用新列表替换播放队列（不切歌），用于歌单分页后台补全。
  Future<void> replaceQueue(List<Song> songs) async {
    if (songs.isEmpty) return;
    queue = List<Song>.of(songs);
    if (playbackMode == PlaybackMode.shuffle) {
      _shuffleQueue.reset(queue.length, currentIndex: currentIndex);
    }
    await _audioHandler.setSongQueue(
      queueSongs: queue,
      queueIndex: currentIndex,
      currentSong: currentSong,
    );
    _scheduleSavePlaybackState();
    notifyListeners();
  }

  Future<int> addSongsToQueue(List<Song> songs) async {
    if (songs.isEmpty) return 0;

    final currentSongKey = currentSong == null
        ? ''
        : (currentSong!.hash.isNotEmpty ? currentSong!.hash : currentSong!.id);
    final nextQueue = List<Song>.of(queue);
    final seen = <String>{};
    final toInsert = <Song>[];

    for (final song in songs) {
      final songKey = song.hash.isNotEmpty ? song.hash : song.id;
      if (songKey.isEmpty || songKey == currentSongKey) continue;
      if (!seen.add(songKey)) continue;

      final existingIndex = nextQueue.indexWhere((item) {
        final itemKey = item.hash.isNotEmpty ? item.hash : item.id;
        return itemKey.isNotEmpty && itemKey == songKey;
      });
      if (existingIndex >= 0) {
        nextQueue.removeAt(existingIndex);
      }
      toInsert.add(song);
    }

    if (toInsert.isEmpty) return 0;

    if (nextQueue.isEmpty) {
      nextQueue.addAll(toInsert);
    } else {
      final index = currentIndex;
      final insertIndex = index < 0
          ? 0
          : (index + 1).clamp(0, nextQueue.length);
      nextQueue.insertAll(insertIndex, toInsert);
    }

    queue = nextQueue;
    if (playbackMode == PlaybackMode.shuffle) {
      _shuffleQueue.reset(queue.length, currentIndex: currentIndex);
    }
    await _audioHandler.setSongQueue(
      queueSongs: queue,
      queueIndex: currentIndex,
      currentSong: currentSong,
    );
    _scheduleSavePlaybackState();
    notifyListeners();
    return toInsert.length;
  }

  Future<void> setAudioQuality(
    AudioQuality quality, {
    bool reloadCurrent = false,
  }) async {
    final sameQuality = audioQuality == quality;
    if (sameQuality && !reloadCurrent) {
      return;
    }

    audioQuality = quality;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_audioQualitySettingKey, quality.apiValue);
    notifyListeners();

    if (reloadCurrent && currentSong != null && !sameQuality) {
      await _reloadCurrentSongForQuality();
    }
  }

  /// 开关音质智能切换（播放失败时自动降级重试）。
  Future<void> setSmartQualityEnabled(bool enabled) async {
    if (smartQualityEnabled == enabled) return;
    smartQualityEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_smartQualitySettingKey, enabled);
    notifyListeners();
  }

  /// 开关开机自启播放歌曲功能。
  Future<void> setAutoPlayOnStartupEnabled(bool enabled) async {
    if (autoPlayOnStartupEnabled == enabled) return;
    autoPlayOnStartupEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayOnStartupSettingKey, enabled);
    notifyListeners();
  }

  /// 开关连接新音频设备自动播放功能。
  Future<void> setAutoPlayOnDeviceConnected(bool enabled) async {
    if (autoPlayOnDeviceConnected == enabled) return;
    autoPlayOnDeviceConnected = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayOnDeviceConnectedSettingKey, enabled);
    notifyListeners();
  }

  /// 开关车载蓝牙歌词广播（默认关闭，避免无车机时多余广播）。
  Future<void> setBluetoothLyricsEnabled(bool enabled) async {
    if (bluetoothLyricsEnabled == enabled) return;
    bluetoothLyricsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bluetoothLyricsEnabledSettingKey, enabled);
    if (!enabled && currentSong != null) {
      unawaited(
        _bluetoothLyrics.broadcastMetaChanged(
          title: currentSong!.title,
          artist: currentSong!.artist,
          album: currentSong!.albumName,
          lyric: '',
          position: position,
          duration: currentSong!.duration ?? Duration.zero,
          playing: isPlaying,
          trackIndex: currentIndex,
          listSize: queue.length,
        ),
      );
    } else if (enabled) {
      _pushBluetoothLyricForCurrentLine(force: true);
    }
    notifyListeners();
  }

  /// 读取本地播放统计。
  Future<PlaybackStats> getPlaybackStats() => _statsService.getStats();

  /// 清空本地播放统计。
  Future<void> clearPlaybackStats() => _statsService.clear();

  /// 读取播放历史。
  Future<List<Song>> getPlaybackHistory({int limit = 100}) =>
      _historyService.getHistory(limit: limit);

  /// 读取播放历史总数（轻量计数，不反序列化 Song 对象）。
  Future<int> getPlaybackHistoryCount() => _historyService.count();

  /// 清空播放历史。
  Future<void> clearPlaybackHistory() => _historyService.clear();

  Future<void> setPlaybackSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 3.0);
    if ((playbackSpeed - clamped).abs() < 0.001) {
      return;
    }
    playbackSpeed = clamped;
    await audioPlayer.setSpeed(clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_playbackSpeedSettingKey, clamped);
    notifyListeners();
  }

  Future<void> setBassBoostEnabled(bool enabled) async {
    if (bassBoostEnabled == enabled) {
      return;
    }
    bassBoostEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bassBoostEnabledSettingKey, enabled);
    await _applyBassBoost();
    notifyListeners();
  }

  Future<void> setBassBoostStrength(
    double strength, {
    bool persist = true,
  }) async {
    final nextStrength = strength.clamp(0.0, 1.0);
    if ((bassBoostStrength - nextStrength).abs() < 0.001) {
      return;
    }
    bassBoostStrength = nextStrength;
    if (bassBoostEnabled) {
      unawaited(_applyBassBoost());
    }
    notifyListeners();

    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_bassBoostStrengthSettingKey, nextStrength);
    }
  }

  Future<void> setEqualizerEnabled(bool enabled) async {
    if (equalizerEnabled == enabled) {
      return;
    }
    equalizerEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, enabled);
    await _applyEqualizer();
    notifyListeners();
  }

  Future<void> setEqualizerBandLevel(
    int index,
    int levelMillibels, {
    bool persist = true,
  }) async {
    if (index < 0 || index >= equalizerLevels.length) {
      return;
    }
    final clamped = levelMillibels.clamp(
      equalizerConfig.minMillibels,
      equalizerConfig.maxMillibels,
    );
    if (equalizerLevels[index] == clamped) {
      return;
    }
    equalizerLevels = List<int>.of(equalizerLevels)..[index] = clamped;
    equalizerPresetName = '自定义';
    if (equalizerEnabled) {
      unawaited(_applyEqualizer());
    }
    notifyListeners();

    if (persist) {
      await _persistEqualizer();
    }
  }

  Future<void> applyEqualizerPreset(AudioEffectPreset preset) async {
    equalizerPresetName = preset.name;
    equalizerLevels = _levelsForBandCount(
      preset.levels,
      equalizerLevels.length,
    );
    await _persistEqualizer();
    if (equalizerEnabled) {
      await _applyEqualizer();
    }
    notifyListeners();
  }

  Future<void> resetEqualizer() async {
    await applyEqualizerPreset(equalizerPresets.first);
  }

  Future<void> loadLyrics(Song song) async {
    final cache = cacheService;
    final cacheKey = 'cache_lyric_${song.hash}';

    if (song.source == SongSource.local) {
      // 1. 优先尝试同名 .lrc 文件
      try {
        final songFile = File(song.id);
        final dotIndex = songFile.path.lastIndexOf('.');
        final lrcPath =
            '${dotIndex != -1 ? songFile.path.substring(0, dotIndex) : songFile.path}.lrc';
        final file = File(lrcPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          String content;
          try {
            content = utf8.decode(bytes);
          } catch (_) {
            content = utf8.decode(bytes, allowMalformed: true);
          }
          final lines = parseLyrics(content);
          if (currentSong?.hash == song.hash) {
            lyrics = lines;
            notifyListeners();
            _syncDesktopLyrics();
          }
          return;
        }
      } catch (e) {
        debugPrint('Failed to load local .lrc lyrics: $e');
      }

      // 2. 尝试从音频文件内嵌元数据读取歌词
      try {
        final embedded = await localMusic?.getEmbeddedLyrics(song.id);
        if (embedded != null && embedded.isNotEmpty) {
          final lines = parseLyrics(embedded);
          if (currentSong?.hash == song.hash) {
            lyrics = lines;
            notifyListeners();
            _syncDesktopLyrics();
          }
          return;
        }
      } catch (e) {
        debugPrint('Failed to load embedded lyrics: $e');
      }

      if (currentSong?.hash == song.hash) {
        lyrics = const [];
        notifyListeners();
        _syncDesktopLyrics();
      }
      return;
    }

    // 1. 先读缓存，命中则立即显示（无感）
    if (cache != null) {
      try {
        final cached = await cache.read<List<LyricLine>>(
          cacheKey,
          decode: (json) => (json['lines'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(LyricLine.fromCache)
              .toList(),
          ttl: const Duration(days: 30),
        );
        if (cached != null &&
            !listEquals(lyrics, cached.data) &&
            currentSong?.hash == song.hash) {
          lyrics = cached.data;
          notifyListeners();
          _syncDesktopLyrics();
        }
      } catch (_) {}
    }

    // 2. 后台静默刷新
    try {
      final fresh = await _api.lyrics(song);
      if (currentSong?.hash != song.hash) return; // 已切歌，丢弃
      if (!listEquals(lyrics, fresh)) {
        lyrics = fresh;
        notifyListeners();
      }
      // 写缓存（空歌词也缓存，避免重复请求）
      if (cache != null) {
        unawaited(
          cache.write(cacheKey, {
            'lines': fresh.map((l) => l.toCache()).toList(),
          }),
        );
      }
    } catch (_) {
      if (currentSong?.hash == song.hash && lyrics.isEmpty) {
        lyrics = const [];
        notifyListeners();
      }
    }
    if (currentSong?.hash == song.hash) {
      _syncDesktopLyrics();
    }
  }

  Future<void> togglePlay() async {
    if (audioPlayer.playing) {
      await _audioHandler.pause();
    } else {
      // 冷启动恢复播放状态后，音频引擎只恢复了队列/当前歌曲状态，
      // 尚未加载任何音频源（idle）。此时直接 play() 只是空转
      // （UI 显示播放中但不出声），必须走完整播放流程加载当前歌曲。
      if (audioPlayer.processingState == ProcessingState.idle) {
        final song = currentSong;
        if (song != null) {
          await playSong(song, queue: queue);
          return;
        }
      }
      if (audioPlayer.processingState == ProcessingState.completed) {
        await _audioHandler.seek(Duration.zero);
      }
      await _audioHandler.play();
    }
  }

  void previewSeek(Duration position) {
    _isScrubbing = true;
    _isSeeking = true;
    _setPositionBase(position, playing: false);
    _emitPosition();
  }

  Future<void> seek(Duration position) async {
    final serial = ++_seekSerial;
    final target = _clampPosition(position);
    _lastSmoothPosition = Duration.zero;
    // 用户手动 seek 后取消高潮武装，避免拖动进度条到高潮结束点后意外自动暂停。
    _climaxEndTime = null;
    seekRevision++;
    _isScrubbing = false;
    _isSeeking = true;
    _setPositionBase(target, playing: isPlaying);
    _emitPosition();

    try {
      await _audioHandler.seek(target);
      if (serial != _seekSerial) {
        return;
      }
      _setPositionBase(target, playing: isPlaying);
      _emitPosition();
    } finally {
      if (serial == _seekSerial) {
        _isSeeking = false;
        _isScrubbing = false;
      }
    }
  }

  Future<void> next() async {
    final nextSong = _nextSong();
    if (nextSong == null) return;
    await playSong(nextSong, queue: queue);
  }

  Future<void> previous() async {
    if (queue.isEmpty) {
      await seek(Duration.zero);
      return;
    }

    if (playbackMode == PlaybackMode.shuffle) {
      if (queue.length == 1) {
        await seek(Duration.zero);
        return;
      }
      final prevIndex = _shuffleQueue.previous(queue.length);
      if (prevIndex >= 0 && prevIndex < queue.length) {
        await playSong(queue[prevIndex], queue: queue);
        return;
      }
    }

    final index = currentIndex;
    if (index > 0) {
      await playSong(queue[index - 1], queue: queue);
    } else {
      await seek(Duration.zero);
    }
  }

  Future<void> _handleCompleted() async {
    if (_isHandlingCompletion || currentSong == null) return;
    if (_completedSongHash == currentSong!.hash) return;
    _isHandlingCompletion = true;
    _completionFallbackTimer?.cancel();
    _completedSongHash = currentSong!.hash;

    try {
      if (_sleepFinishCurrentSong) {
        _sleepFinishCurrentSong = false;
        _sleepFinishCurrentSongOption = false;
        sleepTimerRemaining = null;
        notifyListeners();
        unawaited(_audioHandler.pause());
        return;
      }

      // Windows 上 just_audio_windows 的 WinRT MediaPlayer 在触发 completed
      // 事件时，native 回调仍在后台线程执行。若立即调用 setUrl() 加载新音源，
      // 会与 COM 平台线程产生竞态，导致 "Lost connection to device" 进程崩溃。
      // 延迟 100ms 让 native 层完成 completed 状态的清理，再切换到下一首。
      if (Platform.isWindows) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // 延迟后重新检查状态，避免在延迟期间用户手动切歌
        if (_completedSongHash != currentSong?.hash) return;
      }

      if (playbackMode == PlaybackMode.singleLoop) {
        _completedSongHash = null;
        await _audioHandler.seek(Duration.zero);
        await _audioHandler.play();
        return;
      }

      final nextSong = _nextSong();
      if (nextSong == null) {
        await _audioHandler.seek(Duration.zero);
        return;
      }
      await playSong(nextSong, queue: queue);
    } finally {
      _isHandlingCompletion = false;
    }
  }

  void _maybeCompleteFromPosition(Duration value) {
    if (_isSeeking || _isScrubbing || !isPlaying || duration <= Duration.zero) {
      return;
    }
    if (audioPlayer.processingState == ProcessingState.completed) {
      return;
    }

    final remaining = duration - value;
    if (remaining.inMilliseconds <= 750 &&
        (_completionFallbackTimer?.isActive != true)) {
      final delay =
          (remaining > Duration.zero ? remaining : Duration.zero) +
          const Duration(milliseconds: 180);
      _completionFallbackTimer = Timer(delay, () {
        if (!isPlaying || _isSeeking || _isScrubbing) return;
        final currentPosition = audioPlayer.position;
        if (duration > Duration.zero &&
            duration - currentPosition <= const Duration(milliseconds: 220)) {
          unawaited(_handleCompleted());
        }
      });
    }
  }

  /// 试听当前歌曲的高潮片段：定位到高潮开始并播放，到高潮结束自动暂停。
  /// 返回是否成功（无高潮片段或失败时返回 false）。
  Future<bool> playClimaxPreview() async {
    final song = currentSong;
    if (song == null) return false;
    try {
      final climax = await _api.songClimax(song.hash);
      if (climax == null) return false;
      // 等待网络期间可能已切歌，避免把旧歌的高潮定位到新歌上。
      if (currentSong?.hash != song.hash) return false;
      this.climax = climax;
      await seek(climax.startTime);
      if (currentSong?.hash != song.hash) return false;
      // seek 完成后再设置结束时间，避免 seek 期间旧位置触发提前暂停。
      _climaxEndTime = climax.endTime;
      if (!audioPlayer.playing) {
        await togglePlay();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 高潮试听播放到结束时间时自动暂停。
  void _maybeStopClimaxPreview(Duration value) {
    final end = _climaxEndTime;
    if (end == null || value < end) return;
    _climaxEndTime = null;
    if (audioPlayer.playing) {
      unawaited(togglePlay());
    }
  }

  /// 异步获取当前歌曲高潮时间，用于进度条标记（失败静默）。
  Future<void> _loadClimax(Song song) async {
    try {
      final result = await _api.songClimax(song.hash);
      if (currentSong?.hash != song.hash) return;
      climax = result;
      notifyListeners();
    } catch (_) {
      if (currentSong?.hash == song.hash) {
        climax = null;
      }
    }
  }

  Future<void> _reloadCurrentSongForQuality() async {
    final song = currentSong;
    if (song == null) {
      return;
    }

    final resumePlayback = isPlaying;
    final targetPosition = smoothPosition;
    isPreparing = true;
    errorMessage = null;
    notifyListeners();

    try {
      String url;
      String? networkUrl;
      final local = downloadController?.localPathFor(song, audioQuality);
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final PlayUrl playUrl;
        if (song.isCloudDrive) {
          playUrl = await _api.cloudSongUrl(song);
        } else if (song.source == SongSource.netease) {
          playUrl = PlayUrl(
            url: 'https://music.163.com/song/media/outer/url?id=${song.id}.mp3',
            hash: song.hash,
          );
        } else {
          playUrl = await _api.songUrl(song, quality: audioQuality);
        }
        if (playUrl.url.isEmpty) {
          throw Exception('当前音质暂时没有可播放地址');
        }
        url = playUrl.url;
        networkUrl = playUrl.url;
      }
      // 响度均衡:切换音质/重载后 URL 可能变化。先查缓存命中即 instant 应用,
      // 未命中则播放中分析后渐变(序号守卫会丢弃旧结果)。
      _currentLoudnessUrl = url;
      final pre = _loudness.gainFromCache(song.hash);
      if (pre.fromCache) {
        _pendingGainDb = pre.gainDb;
        unawaited(_applyLoudnessGain(instant: true));
      }
      unawaited(_analyzeAndApplyLoudness(song: song, url: url));
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: queue,
        queueIndex: currentIndex,
      );
      if (targetPosition > Duration.zero) {
        await _audioHandler.seek(_clampPosition(targetPosition));
      }
      if (resumePlayback) {
        await _audioHandler.play();
      }
      // 切音质后后台缓存
      if (networkUrl != null) {
        unawaited(
          downloadController?.cacheForPlayback(song, audioQuality, networkUrl),
        );
      }
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isPreparing = false;
      notifyListeners();
    }
  }

  Future<void> _setupAudioSessionListeners() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          // 打断开始：系统可能已自动暂停播放器。
          // 若开启了"阻止打断"，立即恢复播放以对抗暂停。
          if (!audioInterruptionEnabled && isPlaying && currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 300), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_audioHandler.play());
              }
            });
          }
        } else {
          // 打断结束：若开启了"自动恢复"或"阻止打断"，恢复播放。
          if ((autoResumeAfterInterruption || (!audioInterruptionEnabled)) &&
              currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_audioHandler.play());
              }
            });
          }
        }
      });
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        if (!audioInterruptionEnabled) {
          // 阻止打断模式下忽略耳机拔出
          return;
        }
        if (autoResumeAfterInterruption && currentSong != null) {
          _autoResumeTimer?.cancel();
          _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
            if (!isPlaying && currentSong != null) {
              unawaited(_audioHandler.play());
            }
          });
        }
      });
      _previousDevices = await session.getDevices();
      _devicesSub = session.devicesStream.listen((devices) {
        if (_previousDevices != null) {
          final addedDevices = devices.difference(_previousDevices!);
          if (addedDevices.isNotEmpty) {
            // ignore: experimental_member_use
            final hasNewAudioDevice = addedDevices.any(
              (d) =>
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.bluetoothA2dp ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.bluetoothLe ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.bluetoothSco ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.wiredHeadset ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.wiredHeadphones ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.carAudio,
            );

            if (hasNewAudioDevice &&
                autoPlayOnDeviceConnected &&
                currentSong != null &&
                !isPlaying) {
              _autoResumeTimer?.cancel();
              _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
                if (!isPlaying && currentSong != null) {
                  unawaited(_audioHandler.play());
                }
              });
            }
          }
        }
        _previousDevices = devices;
      });
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  /// 根据打断设置生成 AudioSessionConfiguration。
  ///
  /// 阻止打断时使用 [AndroidAudioFocusGainType.gain] 并禁用 androidWillPauseWhenDucked，
  /// 向系统声明不希望被其他 App 打断。同时配合 interruptionEventStream 中的
  /// 主动恢复播放作为双保险。
  AudioSessionConfiguration get _audioSessionConfiguration {
    if (audioInterruptionEnabled) {
      return const AudioSessionConfiguration.music();
    }
    // 阻止打断模式：声明需要独占音频焦点，不因降音暂停
    return const AudioSessionConfiguration(
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      // 不因其他 App 降音而暂停
      androidWillPauseWhenDucked: false,
    );
  }

  Future<void> setAudioInterruptionEnabled(bool enabled) async {
    if (audioInterruptionEnabled == enabled) return;
    audioInterruptionEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_audioInterruptionEnabledSettingKey, enabled);
    // 设置变更后立即重新配置 AudioSession，使新策略生效
    unawaited(_reconfigureAudioSession());
    notifyListeners();
  }

  /// 重新配置 AudioSession 以应用最新的打断策略。
  Future<void> _reconfigureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  Future<void> setAutoResumeAfterInterruption(bool enabled) async {
    if (autoResumeAfterInterruption == enabled) return;
    autoResumeAfterInterruption = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoResumeAfterInterruptionSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setDesktopLyricsEnabled(bool enabled) async {
    if (desktopLyricsEnabled == enabled) return;
    desktopLyricsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, enabled);
    notifyListeners();

    if (enabled) {
      final hasPermission = await _desktopLyrics.checkPermission();
      if (!hasPermission) {
        desktopLyricsEnabled = false;
        await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
        notifyListeners();
        await _desktopLyrics.requestPermission();
        return;
      }
      final song = currentSong;
      if (song != null) {
        await _syncDesktopLyricsVisibility();
      }
    } else {
      await _desktopLyrics.hide();
    }
  }

  bool get _shouldShowDesktopLyrics {
    return desktopLyricsEnabled &&
        currentSong != null &&
        (!_isAppForeground || _desktopLyricsPreviewVisible);
  }

  Future<void> _syncDesktopLyricsVisibility() async {
    if (!_shouldShowDesktopLyrics) {
      await _desktopLyrics.hide();
      return;
    }

    final song = currentSong;
    if (song == null) return;
    final shown = await _desktopLyrics.show(
      title: song.title,
      artist: song.artist,
    );
    if (shown) {
      _syncDesktopLyrics();
      _syncDesktopPlayState();
      _syncDesktopKaraokeProgress();
    }
  }

  void _syncDesktopLyrics() {
    if (!_shouldShowDesktopLyrics) return;
    final index = activeLyricIndex;
    if (lyrics.isEmpty) {
      _desktopLyrics.updateLyrics(current: '', next: '');
      return;
    }
    final current = lyrics[index.clamp(0, lyrics.length - 1)].text;
    final nextIndex = index + 1;
    final next = nextIndex < lyrics.length ? lyrics[nextIndex].text : '';
    _desktopLyrics.updateLyrics(current: current, next: next);
  }

  void _syncDesktopPlayState() {
    if (!_shouldShowDesktopLyrics) return;
    _desktopLyrics.updatePlayState(isPlaying: isPlaying);
  }

  int _lastDesktopLyricIndex = -1;

  void _maybeSyncDesktopLyricFromPosition() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    if (index != _lastDesktopLyricIndex) {
      _lastDesktopLyricIndex = index;
      _syncDesktopLyrics();
    }
    // Karaoke progress for current line
    _syncDesktopKaraokeProgress();
  }

  void _syncSuperLyricFromPosition() {
    if (currentSong == null) return;
    if (lyrics.isEmpty) {
      if (!isPlaying && _lastSuperLyricPlaying) {
        _lastSuperLyricPlaying = false;
        _lastSuperLyricIndex = -1;
        unawaited(_superLyric.sendStop());
      } else if (isPlaying && !_lastSuperLyricPlaying) {
        _lastSuperLyricPlaying = true;
      }
      return;
    }
    final index = activeLyricIndex;
    final lineChanged = isPlaying && (index != _lastSuperLyricIndex);
    final resumed = isPlaying && !_lastSuperLyricPlaying;
    if (lineChanged || resumed) {
      _lastSuperLyricIndex = index;
      _lastSuperLyricPlaying = true;
      final clampedIndex = index.clamp(0, lyrics.length - 1);
      final line = lyrics[clampedIndex];
      final lineEndTime = line.time +
          (line.duration ?? _estimatedLineDuration(clampedIndex) ?? Duration.zero);
      unawaited(
        _superLyric.sendLyric(
          song: currentSong!,
          line: line,
          lineEndTime: lineEndTime,
        ),
      );
    } else if (!isPlaying && _lastSuperLyricPlaying) {
      _lastSuperLyricPlaying = false;
      unawaited(_superLyric.sendStop());
    }
  }

  void _syncBluetoothLyricsFromPosition() {
    if (!bluetoothLyricsEnabled) return;
    if (currentSong == null) return;
    final index = lyrics.isEmpty ? -1 : activeLyricIndex;
    final lineChanged = index != _lastBluetoothLyricIndex;
    final playingChanged = isPlaying != _lastBluetoothPlaying;
    if (lineChanged || playingChanged) {
      _pushBluetoothLyricForCurrentLine(
        index: index,
        forcePlayState: playingChanged,
      );
    }
  }

  void _pushBluetoothLyricForCurrentLine({
    bool force = false,
    int? index,
    bool forcePlayState = false,
  }) {
    if (!bluetoothLyricsEnabled || currentSong == null) return;
    final song = currentSong!;
    final resolvedIndex = index ?? (lyrics.isEmpty ? -1 : activeLyricIndex);
    final prevIndex = _lastBluetoothLyricIndex;

    final String lyricText;
    if (lyrics.isEmpty || resolvedIndex < 0) {
      lyricText = '';
      _lastBluetoothLyricIndex = -1;
    } else {
      final clampedIndex = resolvedIndex.clamp(0, lyrics.length - 1);
      lyricText = lyrics[clampedIndex].text;
      _lastBluetoothLyricIndex = clampedIndex;
    }

    _lastBluetoothPlaying = isPlaying;

    final lineChanged = force || prevIndex != _lastBluetoothLyricIndex;
    if (lineChanged) {
      unawaited(
        _bluetoothLyrics.broadcastMetaChanged(
          title: song.title,
          artist: song.artist,
          album: song.albumName,
          lyric: lyricText,
          position: position,
          duration: song.duration ?? Duration.zero,
          playing: isPlaying,
          trackIndex: currentIndex,
          listSize: queue.length,
        ),
      );
    }
    if (forcePlayState) {
      unawaited(
        _bluetoothLyrics.broadcastPlayStateChanged(
          title: song.title,
          artist: song.artist,
          album: song.albumName,
          position: position,
          duration: song.duration ?? Duration.zero,
          playing: isPlaying,
        ),
      );
    }
  }

  void _syncDesktopKaraokeProgress() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    final line = lyrics[index.clamp(0, lyrics.length - 1)];
    final position = smoothPosition;
    final lineDuration = line.duration ?? _estimatedLineDuration(index);

    if (line.words.isEmpty) {
      // No word-level data: estimate progress from line duration
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      } else {
        _desktopLyrics.updateKaraokeProgress(
          progress: 1.0,
          lineDuration: null,
          isPlaying: isPlaying,
        );
      }
    } else {
      // Word-level: find active word and compute progress
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      }
    }
  }

  Duration? _estimatedLineDuration(int index) {
    if (index < 0 || index >= lyrics.length) {
      return null;
    }
    final explicit = lyrics[index].duration;
    if (explicit != null && explicit > Duration.zero) {
      return explicit;
    }
    if (index + 1 < lyrics.length) {
      final nextDuration = lyrics[index + 1].time - lyrics[index].time;
      if (nextDuration > Duration.zero) {
        return nextDuration;
      }
    }
    if (duration > lyrics[index].time) {
      final tailDuration = duration - lyrics[index].time;
      if (tailDuration > Duration.zero) {
        return tailDuration;
      }
    }
    return null;
  }

  Future<void> updateDesktopLyricsSettings(
    DesktopLyricsSettings settings,
  ) async {
    desktopLyricsSettings = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _desktopLyricsSettingsKey,
      jsonEncode(settings.toMap()),
    );
    notifyListeners();
    await _desktopLyrics.updateSettings(settings);
  }

  bool get isDesktopLyricsSupported => DesktopLyricsService.isSupportedPlatform;

  void setAppForeground(bool isForeground) {
    if (_isAppForeground == isForeground) return;
    _isAppForeground = isForeground;
    if (desktopLyricsEnabled) {
      _desktopLyrics.setAppForeground(isForeground: isForeground);
      unawaited(_syncDesktopLyricsVisibility());
    }
  }

  Future<void> setDesktopLyricsPreviewVisible(bool visible) async {
    if (_desktopLyricsPreviewVisible == visible) return;
    _desktopLyricsPreviewVisible = visible;
    await _syncDesktopLyricsVisibility();
  }

  Future<void> _handleDesktopLyricsVisibility({
    required bool visible,
    required bool userClosed,
  }) async {
    if (!userClosed || !desktopLyricsEnabled) {
      return;
    }
    desktopLyricsEnabled = false;
    _desktopLyricsPreviewVisible = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
    notifyListeners();
  }

  Future<bool> checkDesktopLyricsPermission() =>
      _desktopLyrics.checkPermission();

  Future<void> requestDesktopLyricsPermission() =>
      _desktopLyrics.requestPermission();

  bool get isSleepTimerActive =>
      sleepTimerRemaining != null && sleepTimerRemaining! > Duration.zero;

  bool get isSleepFinishCurrentSong => _sleepFinishCurrentSong;
  bool get sleepFinishCurrentSongOption => _sleepFinishCurrentSongOption;

  /// Set a sleep timer that pauses playback immediately or after current song finishes when it expires.
  void setSleepTimer(Duration duration, {bool finishCurrentSong = false}) {
    _sleepFinishCurrentSongOption = finishCurrentSong;
    _sleepFinishCurrentSong = false;
    _sleepTimer?.cancel();
    _sleepTimerEnd = DateTime.now().add(duration);
    sleepTimerRemaining = duration;
    notifyListeners();

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final end = _sleepTimerEnd;
      if (end == null) return;
      final remaining = end.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        if (_sleepFinishCurrentSongOption) {
          _sleepTimer?.cancel();
          _sleepTimer = null;
          _sleepTimerEnd = null;
          _sleepFinishCurrentSong = true;
          notifyListeners();
        } else {
          _executeSleepTimer();
        }
      } else {
        sleepTimerRemaining = remaining;
        notifyListeners();
      }
    });
  }

  /// Set a sleep timer that finishes the current song, then stops.
  void setSleepTimerFinishSong(Duration duration) {
    setSleepTimer(duration, finishCurrentSong: true);
  }

  /// Update the sleep timer finish song option dynamically.
  void updateSleepTimerOption(bool finishCurrentSong) {
    if (_sleepTimer != null || _sleepFinishCurrentSong) {
      _sleepFinishCurrentSongOption = finishCurrentSong;
      // If the timer has already expired and is waiting for song to finish,
      // and they turn it OFF, we should stop immediately.
      if (!finishCurrentSong && _sleepFinishCurrentSong) {
        _executeSleepTimer();
      } else {
        notifyListeners();
      }
    }
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepFinishCurrentSong = false;
    _sleepFinishCurrentSongOption = false;
    sleepTimerRemaining = null;
    notifyListeners();
  }

  void _executeSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepFinishCurrentSong = false;
    _sleepFinishCurrentSongOption = false;
    sleepTimerRemaining = null;
    notifyListeners();
    unawaited(_audioHandler.pause());
  }

  void _scheduleSavePlaybackState() {
    _saveStateTimer?.cancel();
    _saveStateTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_savePlaybackState());
    });
  }

  Future<void> _savePlaybackState() async {
    final prefs = await SharedPreferences.getInstance();
    final state = {
      'queue': queue
          .take(_playbackStateMaxQueueSize)
          .map((s) => s.toCache())
          .toList(),
      'currentIndex': currentIndex,
      'playbackMode': playbackMode.name,
    };
    await prefs.setString(_playbackStateKey, jsonEncode(state));
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    addListeningTimeEnabled =
        prefs.getBool(_listenTimeSettingKey) ?? addListeningTimeEnabled;
    audioQuality = AudioQuality.fromApiValue(
      prefs.getString(_audioQualitySettingKey),
    );
    smartQualityEnabled =
        prefs.getBool(_smartQualitySettingKey) ?? smartQualityEnabled;
    autoPlayOnStartupEnabled =
        prefs.getBool(_autoPlayOnStartupSettingKey) ?? autoPlayOnStartupEnabled;
    equalizerEnabled =
        prefs.getBool(_equalizerEnabledSettingKey) ?? equalizerEnabled;
    equalizerPresetName =
        prefs.getString(_equalizerPresetSettingKey) ?? equalizerPresetName;
    equalizerLevels = _restoreEqualizerLevels(
      prefs.getString(_equalizerLevelsSettingKey),
    );
    equalizerConfig = EqualizerConfig.fallback(equalizerLevels);
    bassBoostEnabled =
        prefs.getBool(_bassBoostEnabledSettingKey) ?? bassBoostEnabled;
    bassBoostStrength =
        prefs.getDouble(_bassBoostStrengthSettingKey) ?? bassBoostStrength;
    audioInterruptionEnabled =
        prefs.getBool(_audioInterruptionEnabledSettingKey) ??
        audioInterruptionEnabled;
    autoResumeAfterInterruption =
        prefs.getBool(_autoResumeAfterInterruptionSettingKey) ??
        autoResumeAfterInterruption;
    autoPlayOnDeviceConnected =
        prefs.getBool(_autoPlayOnDeviceConnectedSettingKey) ??
        autoPlayOnDeviceConnected;
    bluetoothLyricsEnabled =
        prefs.getBool(_bluetoothLyricsEnabledSettingKey) ??
        bluetoothLyricsEnabled;
    playbackSpeed = prefs.getDouble(_playbackSpeedSettingKey) ?? playbackSpeed;
    desktopLyricsEnabled =
        prefs.getBool(_desktopLyricsEnabledSettingKey) ?? desktopLyricsEnabled;
    final dlSettingsRaw = prefs.getString(_desktopLyricsSettingsKey);
    if (dlSettingsRaw != null && dlSettingsRaw.isNotEmpty) {
      try {
        final map = jsonDecode(dlSettingsRaw);
        if (map is Map<String, dynamic>) {
          desktopLyricsSettings = DesktopLyricsSettings.fromMap(map);
        }
      } catch (_) {}
    }
    unawaited(audioPlayer.setSpeed(playbackSpeed));
    if (desktopLyricsEnabled) {
      unawaited(_desktopLyrics.updateSettings(desktopLyricsSettings));
    }
    _syncListeningTimeTracker();
    unawaited(_refreshEqualizerConfig());
    unawaited(_applyEqualizer());
    unawaited(_applyBassBoost());
    notifyListeners();
  }

  Future<void> _restorePlaybackState() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playbackStateKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final state = jsonDecode(raw) as Map<String, dynamic>;
      final queueList = (state['queue'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromCache)
          .toList();
      if (queueList.isEmpty) return;

      queue = queueList;
      final index = (state['currentIndex'] as int? ?? 0).clamp(
        0,
        queueList.length - 1,
      );
      currentSong = queueList[index];

      final modeName = state['playbackMode'] as String?;
      if (modeName != null) {
        playbackMode = PlaybackMode.values.firstWhere(
          (m) => m.name == modeName,
          orElse: () => PlaybackMode.playlistLoop,
        );
      }

      if (playbackMode == PlaybackMode.shuffle) {
        _shuffleQueue.reset(queue.length, currentIndex: index);
      }

      hasRestoredPlaybackState = true;
      notifyListeners();
    } catch (_) {}
  }

  /// 尝试播放已恢复的当前歌曲。
  ///
  /// 播放失败时按播放模式处理：
  /// - [PlaybackMode.singleLoop]：不切歌，保留错误信息
  /// - [PlaybackMode.playlistLoop] / [PlaybackMode.shuffle]：自动切下一首重试
  ///
  /// 返回 true 表示成功开始播放。
  Future<bool> resumePlayback() async {
    if (currentSong == null || queue.isEmpty) return false;

    final maxAttempts = queue.length;
    var songToPlay = currentSong!;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      errorMessage = null;
      await playSong(songToPlay, queue: queue);
      if (errorMessage == null) return true;

      if (playbackMode == PlaybackMode.singleLoop) {
        return false;
      }

      final nextSong = _nextSong();
      if (nextSong == null) return false;
      songToPlay = nextSong;
    }

    return false;
  }

  List<int> _restoreEqualizerLevels(String? raw) {
    if (raw == null || raw.isEmpty) {
      return List<int>.of(_defaultEqualizerLevels);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final levels = decoded
            .whereType<num>()
            .map((value) => value.round())
            .toList();
        if (levels.isNotEmpty) {
          return _levelsForBandCount(levels, _defaultEqualizerLevels.length);
        }
      }
    } catch (_) {}
    return List<int>.of(_defaultEqualizerLevels);
  }

  Future<void> _persistEqualizer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, equalizerEnabled);
    await prefs.setString(_equalizerPresetSettingKey, equalizerPresetName);
    await prefs.setString(
      _equalizerLevelsSettingKey,
      jsonEncode(equalizerLevels),
    );
  }

  Future<void> _refreshEqualizerConfig() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    final config = await _audioEffects.equalizerConfig(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
    );
    if (config == null || config.bands.isEmpty) {
      return;
    }
    equalizerConfig = config;
    if (equalizerLevels.length != config.bands.length) {
      equalizerLevels = _levelsForBandCount(
        equalizerLevels,
        config.bands.length,
      );
      unawaited(_persistEqualizer());
    }
    notifyListeners();
  }

  Future<void> _applyEqualizer() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    await _audioEffects.configureEqualizer(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: equalizerEnabled,
      levels: equalizerLevels,
    );
  }

  Future<void> _applyBassBoost() async {
    if (!isBassBoostSupported) {
      return;
    }

    await _audioEffects.configureBassBoost(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: bassBoostEnabled,
      strength: bassBoostStrength,
    );
  }

  /// 切歌时并行分析响度,完成后应用增益(不阻塞 loadSong/播放)。
  /// 渐进式:原生解码过程中每 500ms 推一次中途 LUFS,这里收到后立即算增益
  /// 并渐变应用,用户 0.5s 即可听到大致均衡。全曲分析完成后用精确值做最后
  /// 一次微调并写缓存。
  ///
  /// 用 [_loudnessSerial] 守护:若分析期间又切了歌,本次结果(包括中途进度)
  /// 会被丢弃。切歌时 [playSong] 会调 [LoudnessService.cancelAnalysis] 取消
  /// 旧分析,避免空跑占 CPU。
  ///
  /// 仅在缓存未命中(需原生解码分析)时触发渐变应用;缓存命中已由
  /// 调用方(loadSong 前)instant 应用,这里 [analyzeAndComputeGain] 会
  /// 再次命中并返回相同值,gain 与 [_pendingGainDb] 一致则跳过重复应用。
  Future<void> _analyzeAndApplyLoudness({
    required Song song,
    required String url,
  }) async {
    final serial = ++_loudnessSerial;
    // 重置 EMA 滤波状态:每首新歌从零开始滤波,记录墙钟起点。
    _emaGainDb = null;
    _emaStartWallTime = DateTime.now();
    LoudnessService.log(
      'controller analyze 开始 serial=$serial hash=${song.hash.length > 8 ? song.hash.substring(0, 8) : song.hash}',
    );
    final gain = await _loudness.analyzeAndComputeGain(
      songHash: song.hash,
      url: url,
      onProgress: (gainDb, lufs, analyzedMs, isFinal) {
        // 切歌守卫:序号不匹配说明期间已切到其它歌曲,丢弃本次中途进度。
        if (serial != _loudnessSerial) {
          LoudnessService.log(
            'controller PROGRESS 丢弃 serial=$serial≠$_loudnessSerial (已切歌)',
          );
          return;
        }
        // 渡口效应缓解:分析开始后前 3s(墙钟时间)的中途增益做 EMA 低通滤波。
        // 用墙钟而非音频时长:解码 27x 快,3s 音频 ~110ms 就解码完,按音频时长
        // 滤波窗口在用户听到第一个进度时就已关闭。按墙钟则覆盖用户实际听到的
        // 前 3 秒播放。最终值(isFinal)不滤波,保证精度。
        var appliedGain = gainDb;
        final wallElapsedMs = _emaStartWallTime == null
            ? LoudnessService.earlyProgressWallMs + 1
            : DateTime.now().difference(_emaStartWallTime!).inMilliseconds;
        if (!isFinal && wallElapsedMs < LoudnessService.earlyProgressWallMs) {
          final prev = _emaGainDb;
          if (prev == null) {
            // 首次中途值直接采用(无历史可平均),初始化 EMA 状态。
            _emaGainDb = gainDb;
          } else {
            // EMA: α=0.3 → 新值权重 30%,历史 70%。对 +6→+1.69 跳变
            // 平滑到 +3.90(首次)→ +3.0(二次),用户可感但不再突兀。
            _emaGainDb =
                LoudnessService.emaAlpha * gainDb +
                (1 - LoudnessService.emaAlpha) * prev;
            appliedGain = _emaGainDb!;
            LoudnessService.log(
              'controller PROGRESS(mid,EMA) raw=${gainDb.toStringAsFixed(2)}dB smoothed=${appliedGain.toStringAsFixed(2)}dB wall=${wallElapsedMs}ms<${LoudnessService.earlyProgressWallMs}ms',
            );
          }
        }
        // 中途进度(isFinal=false):若新增益与当前应用增益差异超过阈值,
        // 渐变应用(用户无感)。差异太小(<0.3dB)则跳过,避免频繁 ramp。
        // 最终值(isFinal=true):总是应用(可能差异小但需定稿)。
        final currentGain = _pendingGainDb;
        final diff = currentGain == null
            ? double.infinity
            : (appliedGain - currentGain).abs();
        if (isFinal) {
          LoudnessService.log(
            'controller PROGRESS(final) gain=${appliedGain.toStringAsFixed(2)}dB diff=${diff == double.infinity ? "∞" : diff.toStringAsFixed(2)}dB → 应用(ramp)',
          );
        } else if (diff >= LoudnessService.progressGainThreshold) {
          LoudnessService.log(
            'controller PROGRESS(mid) gain=${appliedGain.toStringAsFixed(2)}dB diff=${diff.toStringAsFixed(2)}dB≥${LoudnessService.progressGainThreshold} → 应用(ramp)',
          );
        } else {
          LoudnessService.log(
            'controller PROGRESS(mid) gain=${appliedGain.toStringAsFixed(2)}dB diff=${diff.toStringAsFixed(2)}dB<${LoudnessService.progressGainThreshold} → 跳过(差异太小)',
          );
          return;
        }
        _pendingGainDb = appliedGain;
        // 中途值用渐变(ramp),最终值也用渐变(平滑收敛)。
        // 缓存命中的 instant 应用已在 playSong 里处理,不走到这里。
        unawaited(_applyLoudnessGain(instant: false));
        notifyListeners();
      },
    );
    // 切歌守卫:序号不匹配说明期间已切到其它歌曲,丢弃本次最终结果
    if (serial != _loudnessSerial) {
      LoudnessService.log(
        'controller analyze 最终结果丢弃 serial=$serial≠$_loudnessSerial (已切歌)',
      );
      return;
    }
    // 最终值已在 onProgress(isFinal=true) 里应用过,这里只处理:
    // - gain 为 null(分析失败/未启用/被取消)→ reset
    // - 缓存命中(gain 与 _pendingGainDb 一致)→ 跳过
    if (gain == null) {
      LoudnessService.log('controller analyze 返回 null (失败/取消/未启用)');
      if (_pendingGainDb != null) {
        _pendingGainDb = null;
        await _applyLoudnessGain(instant: false);
        notifyListeners();
      }
      return;
    }
    // 缓存命中场景:onProgress 不会被调用(查缓存直接返回),
    // _pendingGainDb 可能仍为 null(首次)或旧值。这里补一次 instant 应用。
    if (gain != _pendingGainDb) {
      LoudnessService.log(
        'controller analyze 缓存命中补应用 gain=${gain.toStringAsFixed(2)}dB (instant)',
      );
      _pendingGainDb = gain;
      await _applyLoudnessGain(instant: true);
      notifyListeners();
    } else {
      LoudnessService.log(
        'controller analyze 完成 gain=${gain.toStringAsFixed(2)}dB 已应用,无需补应用',
      );
    }
  }

  /// 应用当前歌曲的响度增益(sessionId 变化或分析完成时调用)。
  /// [instant]=true 直接设置(缓存命中首播);false 走渐变(播放中分析完成)。
  Future<void> _applyLoudnessGain({bool instant = false}) async {
    await _loudness.applyGain(
      audioPlayer: audioPlayer,
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      gainDb: _pendingGainDb,
      instant: instant,
    );
  }

  /// 开关响度均衡。
  Future<void> setLoudnessEnabled(bool enabled) async {
    await _loudness.setEnabled(
      enabled: enabled,
      audioPlayer: audioPlayer,
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
    );
    if (enabled) {
      // 开启后,对当前歌曲立即分析并应用(用已解析的真实 URL,避免重新请求)
      final song = currentSong;
      final url = _currentLoudnessUrl;
      if (song != null && url != null && url.isNotEmpty) {
        unawaited(_analyzeAndApplyLoudness(song: song, url: url));
      }
    } else {
      _pendingGainDb = null;
      _loudnessSerial++; // 使任何在途分析结果失效
      unawaited(_loudness.cancelAnalysis()); // 停掉原生解码线程
    }
    notifyListeners();
  }

  /// 响度分析缓存条目数(供设置页展示)。
  int get loudnessCacheCount => _loudness.cacheCount;

  /// 清空响度分析缓存(设置页"缓存管理"调用)。
  /// 清完后若响度开启,重置当前歌曲增益回原始音量,下次切歌重新分析。
  Future<void> clearLoudnessCache() async {
    _loudnessSerial++; // 使任何在途分析结果失效
    unawaited(_loudness.cancelAnalysis()); // 停掉原生解码线程
    _pendingGainDb = null;
    await _loudness.clearCache();
    if (_loudness.isEnabled) {
      await _loudness.resetGain(
        audioPlayer: audioPlayer,
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      );
    }
    notifyListeners();
  }

  void _syncListeningTimeTracker() {
    final shouldTrack =
        addListeningTimeEnabled && isPlaying && currentSong != null;
    if (shouldTrack) {
      _listenTimeStartedAt ??= DateTime.now();
      _listenTimeTimer ??= Timer.periodic(
        _listenTimeCheckInterval,
        (_) => unawaited(_maybeReportListeningTime()),
      );
      return;
    }

    _pauseListeningTimeTracker();
  }

  void _pauseListeningTimeTracker() {
    final startedAt = _listenTimeStartedAt;
    if (startedAt != null) {
      _pendingListenTime += DateTime.now().difference(startedAt);
      _listenTimeStartedAt = null;
    }
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
  }

  void _resetListeningTimeTracker() {
    _listenTimeStartedAt = null;
    _pendingListenTime = Duration.zero;
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
  }

  Duration _trackedListeningTime() {
    final startedAt = _listenTimeStartedAt;
    if (startedAt == null) {
      return _pendingListenTime;
    }
    return _pendingListenTime + DateTime.now().difference(startedAt);
  }

  Future<void> _maybeReportListeningTime() async {
    if (_isReportingListenTime || !addListeningTimeEnabled) {
      return;
    }
    if (_trackedListeningTime() < _listenTimeReportInterval) {
      return;
    }

    _isReportingListenTime = true;
    try {
      await _api.addListeningTime();
      // 上报成功，同步记录本地统计的听歌时长
      unawaited(_statsService.addListenTime(_listenTimeReportInterval));
      final stillPlaying = isPlaying && currentSong != null;
      final remainder = _trackedListeningTime() - _listenTimeReportInterval;
      _pendingListenTime = remainder > Duration.zero
          ? remainder
          : Duration.zero;
      _listenTimeStartedAt = stillPlaying ? DateTime.now() : null;
      if (!stillPlaying) {
        _listenTimeTimer?.cancel();
        _listenTimeTimer = null;
      }
    } catch (error) {
      debugPrint('[时音][listen-time] report failed: $error');
    } finally {
      _isReportingListenTime = false;
    }
  }

  Song? _nextSong() {
    if (queue.isEmpty) {
      return currentSong;
    }

    final index = currentIndex;
    if (playbackMode == PlaybackMode.shuffle) {
      if (queue.length == 1) return queue.first;
      final nextIndex = _shuffleQueue.next(queue.length);
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

  @override
  void dispose() {
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

  Duration _clampPosition(Duration value) {
    if (value < Duration.zero) {
      return Duration.zero;
    }
    if (duration > Duration.zero && value > duration) {
      return duration;
    }
    return value;
  }

  List<int> _levelsForBandCount(List<int> source, int count) {
    if (count <= 0) {
      return const [];
    }
    if (source.length == count) {
      return List<int>.of(source);
    }
    if (source.length == 1) {
      return List<int>.filled(count, source.first);
    }

    return [
      for (var index = 0; index < count; index++)
        source[((index / math.max(1, count - 1)) * (source.length - 1))
            .round()],
    ];
  }
}
