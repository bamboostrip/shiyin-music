// player_controller.carmc.dart —— PlayerController 的职责分片：Flyme Auto（ECARX）
// 媒体中心接入（issue #15 方向盘切歌）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

/// 车机媒体中心接入分片。
///
/// 职责：
/// 1. 挂接 [CarMediaCenterService]：方向盘/扶手箱按键（EAS Binder 回调）
///    → 去重闸门 → 播控动作（与通知栏/前台媒体键兜底同一套语义）；
/// 2. 订阅 mediaItem / playbackState / position 流，把曲目、播放态、进度、
///    整篇 LRC 持续上行给媒体中心（HUD 卡片与歌词的数据源）；
/// 3. 播放态翻转：false→true 时通知原生 requestPlay 抢媒体焦点（方控按键
///    归属权），true→false 时通知原生补焦（暂停后车机会停止派键）；
/// 4. 原生关键日志经 [AppLogService] 落盘——车机 adb 被封堵的用户只能靠
///    应用内导出日志排障。
///
/// 非 Android / 非 ECARX 车机上：服务内部 no-op，原生层 bindService 失败
/// 即休眠，本分片的所有调用静默失败，不产生可感知开销。
mixin _PlayerCarMediaCenter on _PlayerControllerBase {
  /// 媒体中心服务实例（与 MediaKeyService 同构：仅 Android 生效）。
  final CarMediaCenterService _carMediaCenter = CarMediaCenterService();

  /// 外部播控指令去重闸门：EAS 回调与 MediaSession 路径对同一次按键双
  /// 触发时折叠为一次（窗口 300ms，见 [CarMediaControlGate]）。
  ///
  /// 三个外部输入源共用：attachTransportControls / MediaKeyService /
  /// CarMediaCenterService（接线在 PlayerController 构造器）。
  final CarMediaControlGate carControlGate = CarMediaControlGate();

  StreamSubscription<MediaItem?>? _carMcMediaItemSub;
  StreamSubscription<PlaybackState>? _carMcPlaybackStateSub;
  StreamSubscription<Duration>? _carMcPositionSub;

  /// 上一次播放态（翻转检测）。
  bool _carMcLastPlaying = false;

  /// 上一次进度心跳上行时刻：进度流 tick 很密，1s 一次足够（原生 ticker
  /// 按锚点自行外推，这里只是纠偏）。
  DateTime _carMcLastHeartbeatAt =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// 是否已挂接（防重复）。
  bool _carMcAttached = false;

  /// 去重包装：经 [carControlGate] 放行后才执行外部注入的播控动作。
  ///
  /// 参数取 [FutureOr]：播控方法（next/previous/togglePlay）部分返回
  /// void、部分返回 Future，统一在此归一。
  Future<void> carGated(
    String action,
    FutureOr<void> Function() action2,
  ) async {
    if (!carControlGate.shouldRun(action)) {
      return;
    }
    await action2();
  }

  /// 挂接媒体中心：控制回调 + 状态上行订阅。回调由构造器注入（sibling
  /// mixin 之间不可互调，播控方法都在 PlayerController 上可见）。
  void attachCarMediaCenter({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
  }) {
    if (!_carMediaCenter.isSupported) {
      return;
    }
    _carMediaCenter.attach(
      onNext: () => carGated('next', onNext),
      onPrevious: () => carGated('previous', onPrevious),
      onPlay: () => carGated('play', onPlay),
      onPause: () => carGated('pause', onPause),
      onLog: (line) => AppLogService.instance.log('[CarMC] $line'),
    );

    if (_carMcAttached) {
      return;
    }
    _carMcAttached = true;

    // 曲目变化：上行完整状态（含整篇 LRC，HUD 歌词数据源）。
    _carMcMediaItemSub = _audioHandler.mediaItem.listen((item) {
      _carMcLastItem = item;
      if (item == null) {
        return;
      }
      _carMcPushState(includeLyric: true);
    });

    // 播放态翻转：开播抢焦点 / 暂停补焦，并上行状态。
    _carMcPlaybackStateSub = _audioHandler.playbackState.listen((state) {
      final playing = state.playing;
      if (playing == _carMcLastPlaying) {
        return;
      }
      _carMcLastPlaying = playing;
      if (playing) {
        unawaited(_carMediaCenter.notifyPlayStarted());
      } else {
        unawaited(_carMediaCenter.notifyPaused());
      }
      _carMcPushState(includeLyric: false);
    });

    // 进度心跳（1s 节流）：原生按锚点外推进度，这里周期性纠偏锚点。
    _carMcPositionSub = _audioHandler.audioPlayer.positionStream.listen((_) {
      final now = DateTime.now();
      if (now.difference(_carMcLastHeartbeatAt) < const Duration(seconds: 1)) {
        return;
      }
      _carMcLastHeartbeatAt = now;
      _carMcPushState(includeLyric: false);
    });
  }

  /// 摘除订阅与服务（dispose 时调用；可安全重复调用）。
  void disposeCarMediaCenter() {
    _carMcAttached = false;
    unawaited(_carMcPositionSub?.cancel());
    unawaited(_carMcPlaybackStateSub?.cancel());
    unawaited(_carMcMediaItemSub?.cancel());
    _carMcPositionSub = null;
    _carMcPlaybackStateSub = null;
    _carMcMediaItemSub = null;
    _carMediaCenter.detach();
  }

  /// 组一次完整状态并上行。
  ///
  /// [includeLyric] 为 true 时附带整篇 LRC（曲目/歌词变化时；[lyrics]
  /// 为空则带上空串清掉 HUD 上的旧歌词），进度心跳只纠偏锚点不带歌词，
  /// 避免每秒重组 2~4KB 文本。
  void _carMcPushState({required bool includeLyric}) {
    final song = currentSong;
    unawaited(
      _carMediaCenter.pushState(
        title: song?.title ?? '',
        artist: song?.artist ?? '',
        album: song?.albumName ?? '',
        artwork: _carMcArtwork(),
        durationMs: (song?.duration ?? duration).inMilliseconds,
        positionMs: position.inMilliseconds,
        playing: isPlaying,
        speed: _audioHandler.audioPlayer.speed,
        lyric: includeLyric ? (LrcFormatter.buildFullLrc(lyrics) ?? '') : null,
        lyricLine: _carMcCurrentLyricLine(),
      ),
    );
  }

  /// 最近一次 mediaItem（封面/时长直接取它，audio_service 已发布的口径）。
  MediaItem? _carMcLastItem;

  /// 当前曲目封面：优先 mediaItem 的 artUri（audio_service 已发布的口径），
  /// 避免再查一遍封面缓存。
  String? _carMcArtwork() {
    return _carMcLastItem?.artUri?.toString();
  }

  /// HUD 单行歌词：按当前位置在 [lyrics] 里找当前行（找不到返回 null，
  /// 原生保留上次值；媒体中心也会经 getter 主动 pull）。
  String? _carMcCurrentLyricLine() {
    if (lyrics.isEmpty) {
      return null;
    }
    final pos = position;
    String? current;
    for (final line in lyrics) {
      if (line.time > pos) {
        continue;
      }
      current = line.text;
    }
    return current;
  }
}
