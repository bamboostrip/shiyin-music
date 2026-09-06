// player_controller.settings.dart —— PlayerController 的职责分片：设置/持久化/计时器（音质与开关设置/播放状态恢复/睡眠定时器/听歌时长统计）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerSettings on _PlayerControllerBase {
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

  /// 开关移动数据下后台缓存。
  ///
  /// 关闭（默认）时蜂窝网络只预取歌词，不下载音频；
  /// 打开后蜂窝网络也允许下一首预缓存 + 播后缓存。
  Future<void> setAllowCellularPrecache(bool enabled) async {
    if (allowCellularPrecache == enabled) return;
    allowCellularPrecache = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowCellularPrecacheSettingKey, enabled);
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

  /// 切音质后重载当前歌曲（不断队列、不断歌词，尽量原位继续）。
  ///
  /// 与 playSong 共用同一套守卫：换源深度计数（防 completed 插队）、
  /// 解析/加载期 hash 校验（旧音质不抢新歌引擎）、智能音质降级与
  /// VIP 领取重试（经 [_resolvePlayUrl]），定位走公开 [seek]。
  Future<void> _reloadCurrentSongForQuality() async {
    final song = currentSong;
    if (song == null) {
      return;
    }

    final resumePlayback = isPlaying;
    final targetPosition = smoothPosition;
    isPreparing = true;
    errorMessage = null;
    _changingSourceDepth++;
    // 切旧分析，避免旧歌 LUFS 回调算进新音质增益
    unawaited(_loudness.cancelAnalysis());
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
        // 复用主路径解析：云盘/网易/智能降级语义与 playSong 一致
        final playUrl = await _resolvePlayUrl(song);
        // 解析耗时数秒，期间用户可能已切歌：旧音质不得抢引擎
        if (currentSong?.hash != song.hash) {
          debugPrint('[时音][player] 切音质解析期间已切歌，丢弃旧结果');
          return;
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
      // 加载期间同样可能被切歌抢先：旧音质的 seek/play 全部作废
      if (currentSong?.hash != song.hash) {
        debugPrint('[时音][player] 切音质加载期间已切歌，中止旧后续动作');
        return;
      }
      if (targetPosition > Duration.zero) {
        // 走公开 seek：serial/clamp/notify 语义与手势一致
        await seek(targetPosition);
      }
      if (currentSong?.hash != song.hash) return;
      if (resumePlayback) {
        await _audioHandler.play();
      }
      // 切音质后后台缓存（同样受蜂窝门控约束）
      if (networkUrl != null && isAudioPrecacheAllowed) {
        unawaited(
          downloadController?.cacheForPlayback(song, audioQuality, networkUrl),
        );
      }
    } catch (error) {
      if (_disposed) return;
      // VIP 过期：领取后走完整播放流程重试（保留定位）
      if (error is VipRequiredException && vipClaim != null) {
        final claimed = await _tryClaimVipAndRetry(
          song,
          queue: queue,
          initialPosition: targetPosition > Duration.zero
              ? targetPosition
              : null,
          preserveClimax: true,
        );
        if (claimed) return;
      }
      if (currentSong?.hash != song.hash) {
        debugPrint('[时音][player] 切音质失败时歌曲已切换，跳过错误态');
        return;
      }
      errorMessage = error.toString();
    } finally {
      if (!_disposed) {
        if (_changingSourceDepth > 0) _changingSourceDepth--;
        isPreparing = false;
        notifyListeners();
      }
    }
  }

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

  @override
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
    allowCellularPrecache =
        prefs.getBool(_allowCellularPrecacheSettingKey) ??
        allowCellularPrecache;
    autoPlayOnStartupEnabled =
        prefs.getBool(_autoPlayOnStartupSettingKey) ?? autoPlayOnStartupEnabled;
    equalizerEnabled =
        prefs.getBool(_equalizerEnabledSettingKey) ?? equalizerEnabled;
    equalizerPresetName =
        prefs.getString(_equalizerPresetSettingKey) ?? equalizerPresetName;
    equalizerLevels = PlayerEqualizerLogic.restoreLevels(
      prefs.getString(_equalizerLevelsSettingKey),
      _defaultEqualizerLevels,
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
    userVolume =
        (prefs.getDouble(_userVolumeSettingKey) ?? userVolume).clamp(0.0, 1.0);
    desktopLyricsEnabled =
        prefs.getBool(_desktopLyricsEnabledSettingKey) ?? desktopLyricsEnabled;
    final dlVersion = prefs.getInt(_desktopLyricsSettingsVersionKey) ?? 0;
    if (dlVersion >= _desktopLyricsSettingsVersion) {
      final dlSettingsRaw = prefs.getString(_desktopLyricsSettingsKey);
      if (dlSettingsRaw != null && dlSettingsRaw.isNotEmpty) {
        try {
          final map = jsonDecode(dlSettingsRaw);
          if (map is Map<String, dynamic>) {
            desktopLyricsSettings = DesktopLyricsSettings.fromMap(map);
          }
        } catch (_) {}
      }
    } else {
      // 旧版本残留直接丢弃，并把版本号写到最新，避免每次启动重复判断。
      await prefs.setInt(
        _desktopLyricsSettingsVersionKey,
        _desktopLyricsSettingsVersion,
      );
    }
    unawaited(audioPlayer.setSpeed(playbackSpeed));
    // 恢复用户音量到引擎（响度关闭时即最终值；开启后首播的 instant
    // 应用会再按系数合成一次，此处只保证恢复后、首播前的一致性）
    unawaited(audioPlayer.setVolume(userVolume));
    // 无论当前是否开启都同步设置到桥接：桥接的 settings 缓存是创建
    // 悬浮窗时随 createWindow 参数下发的内容源，若仅在已开启时同步，
    // 「上次锁定 → 本次启动后才开启」会以默认设置（未锁定）建窗，
    // 丢失用户的锁定/字号偏好。
    unawaited(_desktopLyrics.updateSettings(desktopLyricsSettings));
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

      // 恢复元数据占位 + 补拉：此前只还原了队列/当前歌曲，引擎时长、
      // 歌词、高潮全是空的——未开启自动播放时进播放页就是 00:00 +
      // 暂无歌词 + 无高潮标记。时长先用歌曲元数据占位（引擎加载后覆盖），
      // 歌词走缓存优先（30 天）+ 静默刷新，高潮走网络补拉。
      duration = currentSong?.duration ?? Duration.zero;

      hasRestoredPlaybackState = true;
      notifyListeners();
      final restored = currentSong;
      if (restored != null) {
        unawaited(loadLyrics(restored));
        unawaited(_loadClimax(restored));
      }
    } catch (_) {}
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
}
