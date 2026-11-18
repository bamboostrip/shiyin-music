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
      // 关闭前把最后一段真实播放时长结进统计，否则最多丢一个节流周期。
      // 先吸收休眠空档：这条路径同样是 force 结清，隔一次休眠后再关开关
      // 会把整段休眠算进统计。
      _absorbListenTimeStall();
      _flushListenTimeToStats(force: true);
      _resetListeningTimeTracker();
    } else {
      _syncListeningTimeTracker();
    }
    notifyListeners();
  }

  Future<void> setKeepScreenOnEnabled(bool enabled) async {
    if (keepScreenOnEnabled == enabled) {
      return;
    }
    keepScreenOnEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepScreenOnSettingKey, enabled);
    notifyListeners();
  }

  /// 开关歌词页切歌键（issue #3：默认关，保持 QQ 音乐原版底栏观感）。
  Future<void> setLyricPageSkipButtonsEnabled(bool enabled) async {
    if (lyricPageSkipButtonsEnabled == enabled) return;
    lyricPageSkipButtonsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lyricPageSkipButtonsSettingKey, enabled);
    notifyListeners();
  }

  /// 开关「搜索点歌替换播放队列」（issue #6-3：默认关 = 插入当前队列）。
  Future<void> setSearchPlayReplaceQueue(bool enabled) async {
    if (searchPlayReplaceQueue == enabled) return;
    searchPlayReplaceQueue = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_searchPlayReplaceQueueSettingKey, enabled);
    notifyListeners();
  }

  /// 开关「显示已下架/无版权歌曲」。
  ///
  /// 默认 false = 歌单/专辑里隐藏这些歌（当前行为）；true = 置灰显示、
  /// 不可播放。
  Future<void> setShowUnavailableSongs(bool enabled) async {
    if (showUnavailableSongs == enabled) return;
    showUnavailableSongs = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showUnavailableSongsSettingKey, enabled);
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
    // 与 playSong 同构的企图代次：解析/加载期间用户暂停、切歌、断连都会
    // 推进 serial，加载完成后的起播必须作废。切音质本身不是「显式播放」，
    // 因此这里不调 _handleManualPlay()——断连保护仍需用户按播放键解除。
    final intentSerial = _playbackIntentSerial;
    if (resumePlayback) _pendingPlaybackIntent = intentSerial;
    isPreparing = true;
    errorMessage = null;
    _tailSkipExhausted = false;
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
      if (currentSong?.hash != song.hash ||
          (resumePlayback && intentSerial != _playbackIntentSerial)) {
        debugPrint('[时音][player] 切音质解析期间已切歌/暂停，丢弃旧结果');
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
      } else {
        // 未命中(清过缓存等罕见场景):与 playSong 同语义,先中性化旧增益,
        // 真实增益分析出来前按原始响度播放。
        _resetStaleLoudnessGain();
      }
      unawaited(_analyzeAndApplyLoudness(song: song, url: url));
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: queue,
        queueIndex: currentIndex,
      );
      // 加载期间同样可能被切歌/暂停抢先：旧音质的 seek/play 全部作废
      if (currentSong?.hash != song.hash ||
          (resumePlayback && intentSerial != _playbackIntentSerial)) {
        debugPrint('[时音][player] 切音质加载期间已切歌/暂停，中止旧后续动作');
        return;
      }
      // 音源已换成这首歌：后续进度写盘才归属它（与 playSong 同一判据）。
      _positionOwnerHash = song.hash;
      if (targetPosition > Duration.zero) {
        // 走公开 seek：serial/clamp/notify 语义与手势一致
        await seek(targetPosition);
      }
      if (currentSong?.hash != song.hash ||
          (resumePlayback && intentSerial != _playbackIntentSerial)) {
        return;
      }
      if (resumePlayback) {
        // 有界等待平台确认：Android 端无界 await 会拖到曲末，把换源深度与
        // isPreparing 钉死（详见 _kPlayConfirmTimeout）。
        final confirm = await _requestPlayback(expectedIntent: intentSerial);
        if (confirm == PlayConfirm.blocked) {
          // 同 playSong：音源已归属/已定位，落一次盘避免残留旧位置。
          unawaited(_saveCurrentPosition());
          debugPrint('[时音][player] 切音质起播被状态机拒绝: ${song.title}');
          return;
        }
      }
      // 切音质稳定播放后再后台缓存（同样受蜂窝门控约束；快速切歌会取消）
      if (networkUrl != null && isAudioPrecacheAllowed) {
        _schedulePlayCache(song, audioQuality, networkUrl);
      }
    } catch (error) {
      if (_disposed) return;
      // VIP 过期：领取后走完整播放流程重试（保留定位）
      if (error is VipRequiredException && vipClaim != null) {
        final outcome = await _tryClaimVipAndRetry(
          song,
          queue: queue,
          initialPosition: targetPosition > Duration.zero
              ? targetPosition
              : null,
          preserveClimax: true,
          // 切音质期间用户暂停/切歌同样作废这次领取重试。
          expectedIntent: intentSerial,
        );
        // 只有「已重新起播」才收手；领取失败与「领了仍无地址」都落错误态，
        // 切音质是用户主动动作，不自作主张跳歌。
        if (outcome == VipRetryOutcome.resumed) return;
      }
      if (currentSong?.hash != song.hash) {
        debugPrint('[时音][player] 切音质失败时歌曲已切换，跳过错误态');
        return;
      }
      errorMessage = error.toString();
    } finally {
      var depth = _changingSourceDepth;
      if (depth > 0) {
        depth = --_changingSourceDepth;
      }
      if (!_disposed) {
        // 与 playSong 的 finally 同一守卫归属规则：本流程被更新的切歌/切音质
        // 抢先时，不得清掉新流程的 isPreparing（加载态会提前消失）。
        if (depth == 0 && isPreparing) {
          isPreparing = false;
          notifyListeners();
        }
      }
      // 与 playSong finally 同构：只清自己登记的意图，别清掉后来流程的。
      if (_pendingPlaybackIntent == intentSerial) {
        _pendingPlaybackIntent = null;
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
          // 到期时若并未在播放，不存在"当前歌曲播完"，直接执行休眠清空状态；
          // 否则标记会残留，导致之后某个会话突然暂停。
          if (!isPlaying) {
            _executeSleepTimer();
          } else {
            _sleepFinishCurrentSong = true;
            notifyListeners();
          }
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

  /// 更新「播完当前歌曲再停止」偏好。
  ///
  /// 无定时器运行时也要记住该偏好——用户常先打开开关再选时长；
  /// 旧实现仅在定时器已激活时写入，导致菜单里点了仍显示「关」。
  void updateSleepTimerOption(bool finishCurrentSong) {
    _sleepFinishCurrentSongOption = finishCurrentSong;
    // 定时已到期且在等播完时，关掉开关应立即休眠。
    if (!finishCurrentSong && _sleepFinishCurrentSong) {
      _executeSleepTimer();
      return;
    }
    notifyListeners();
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
    unawaited(_audioHandler.pause(userInitiated: false));
  }

  @override
  void _scheduleSavePlaybackState() {
    _saveStateTimer?.cancel();
    _saveStateTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_savePlaybackStateGuarded());
    });
  }

  /// 落盘失败不得外溢：防抖是 unawaited 定时器、生命周期刷写也在 unawaited
  /// 回调里，异常会变成未处理的异步错误（prefs/平台通道故障时每次切歌刷一条），
  /// 反而掩盖真正的业务问题。返回值供 [flushPlaybackState] 决定要不要重排。
  Future<bool> _savePlaybackStateGuarded() async {
    try {
      await _savePlaybackState();
      return true;
    } catch (error) {
      debugPrint('[时音][player] 播放状态写盘失败（忽略本次）: $error');
      return false;
    }
  }

  /// 立即落盘播放状态（取消防抖）。
  ///
  /// 供桌面退出路径（DesktopWindow.quitGracefully 注册的退出前钩子）与移动端
  /// 退后台（main.dart AppLifecycleState.paused）调用：硬终止进程不做任何异步
  /// 收尾，防抖窗口内的切歌必须先刷写，否则下次启动恢复到上一首歌。
  Future<void> flushPlaybackState() async {
    // 进度单独一个键，顺手一起刷：退出/退后台是最容易「听到一半就没了」的点。
    // 必须 await：桌面 quitGracefully 在钩子返回后直接 TerminateProcess，
    // 未完成的 prefs 写会被硬杀丢掉。
    await _saveCurrentPosition();
    _saveStateTimer?.cancel();
    _saveStateTimer = null;
    // 防抖已被取消：这次写失败就等于把窗口内本该落盘的切歌一起丢了，
    // 所以失败后重排一次，交给后续切歌/下一次生命周期兜住。
    if (!await _savePlaybackStateGuarded()) _scheduleSavePlaybackState();
  }

  /// 恢复出来的位置是否值得应用。
  ///
  /// 尾 3 秒内不恢复：否则一开播就撞曲末，自动下一首，用户看到的是
  /// 「刚进来就跳歌」。用「剩余时长」判断而不是百分比，长播客/有声书不受影响。
  bool _isResumablePosition(Song song, Duration saved) {
    final total = song.duration;
    if (total == null || total <= Duration.zero) return true;
    return total - saved > const Duration(seconds: 3);
  }

  Future<void> _savePlaybackState() async {
    final prefs = await SharedPreferences.getInstance();
    final total = queue.length;
    final index = currentIndex;
    // 长队列只存前 N 首会导致「播到第 250 首、重启回到第 200 首」：改为以
    // 当前歌为中心取窗口，并额外记下基准偏移与当前歌 hash，恢复时按 hash
    // 精确找回原曲（旧数据没有这两个字段时按原语义退化）。
    const max = _playbackStateMaxQueueSize;
    final base = total <= max || index < 0
        ? 0
        : (index - max ~/ 2).clamp(0, total - max);
    final end = (base + max).clamp(0, total);
    final state = {
      'queueBaseIndex': base,
      'currentSongHash': currentSong?.hash ?? '',
      'queue': queue.sublist(base, end).map((s) => s.toCache()).toList(),
      'currentIndex': index < 0 ? -1 : index - base,
      'playbackMode': playbackMode.name,
    };
    await prefs.setString(_playbackStateKey, jsonEncode(state));
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    addListeningTimeEnabled =
        prefs.getBool(_listenTimeSettingKey) ?? addListeningTimeEnabled;
    // 听歌时长跨会话累计（上游 3.3.0 #151）：读回未满上报周期的余量，
    // 重启后接着累计，不再从 0 起算。脏数据（类型不符等）静默忽略——
    // 统计不是关键路径，不能因此中断其余设置恢复。
    try {
      final savedPendingListenTimeMs =
          prefs.getInt(_pendingListenTimeMsKey) ?? 0;
      if (savedPendingListenTimeMs > 0) {
        _pendingListenTime = Duration(milliseconds: savedPendingListenTimeMs);
      }
    } catch (_) {}
    keepScreenOnEnabled =
        prefs.getBool(_keepScreenOnSettingKey) ?? keepScreenOnEnabled;
    lyricPageSkipButtonsEnabled =
        prefs.getBool(_lyricPageSkipButtonsSettingKey) ??
        lyricPageSkipButtonsEnabled;
    searchPlayReplaceQueue =
        prefs.getBool(_searchPlayReplaceQueueSettingKey) ??
        searchPlayReplaceQueue;
    showUnavailableSongs =
        prefs.getBool(_showUnavailableSongsSettingKey) ?? showUnavailableSongs;
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
    surroundEnabled =
        prefs.getBool(_surroundEnabledSettingKey) ?? surroundEnabled;
    surroundStrength =
        prefs.getDouble(_surroundStrengthSettingKey) ?? surroundStrength;
    audioInterruptionEnabled =
        prefs.getBool(_audioInterruptionEnabledSettingKey) ??
        audioInterruptionEnabled;
    autoResumeAfterInterruption =
        prefs.getBool(_autoResumeAfterInterruptionSettingKey) ??
        autoResumeAfterInterruption;
    autoPlayOnDeviceConnected =
        prefs.getBool(_autoPlayOnDeviceConnectedSettingKey) ??
        autoPlayOnDeviceConnected;
    autoPauseOnDeviceDisconnect =
        prefs.getBool(_autoPauseOnDeviceDisconnectSettingKey) ??
        autoPauseOnDeviceDisconnect;
    bluetoothLyricsEnabled =
        prefs.getBool(_bluetoothLyricsEnabledSettingKey) ??
        bluetoothLyricsEnabled;

    // 手环/AVRCP 歌词标题同步（上游 3.3.0 #134）：恢复用户偏好，并把
    // 「车载蓝牙歌词 && 标题同步」的合成开关下发给 handler。默认关闭时
    // 保持 handler 默认值、不跨对象调用（既有 fake handler 单测零改动）。
    bluetoothLyricsTitleSyncEnabled =
        prefs.getBool(_bluetoothLyricsTitleSyncSettingKey) ??
        bluetoothLyricsTitleSyncEnabled;
    final effectiveBluetoothTitleSync =
        bluetoothLyricsEnabled && bluetoothLyricsTitleSyncEnabled;
    if (effectiveBluetoothTitleSync) {
      _bluetoothLyricsTitleSyncApplied = true;
      _audioHandler.setBluetoothLyricsTitleSync(true);
    }
    // 逐曲歌词进度偏移：先恢复整张映射，当前歌的装载放到方法末尾
    // （此刻桌面歌词等设置已就绪，补推不会拿着半成品设置）。
    _restoreLyricOffsets(prefs);
    playbackSpeed = prefs.getDouble(_playbackSpeedSettingKey) ?? playbackSpeed;
    userVolume = (prefs.getDouble(_userVolumeSettingKey) ?? userVolume).clamp(
      0.0,
      1.0,
    );
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
            // 一次性把存量 'center' 迁到新的默认 'split'（左右分离）。
            // 行为等价：单行下 split 渲染与 center 完全一致；双行历史上
            // 忽略 alignment，'center' 不可能是用户对双行的选择。
            final alignmentMigrated =
                prefs.getBool(_desktopLyricsAlignmentMigratedKey) ?? false;
            if (!alignmentMigrated) {
              if (desktopLyricsSettings.alignment ==
                  DesktopLyricsAlignment.center) {
                desktopLyricsSettings = desktopLyricsSettings.copyWith(
                  alignment: DesktopLyricsAlignment.split,
                );
                await prefs.setString(
                  _desktopLyricsSettingsKey,
                  jsonEncode(desktopLyricsSettings.toMap()),
                );
              }
              await prefs.setBool(_desktopLyricsAlignmentMigratedKey, true);
            }
          }
        } catch (_) {}
      } else {
        // v2 已是最新但尚无持久化（新安装）：按平台取默认值，
        // 桌面透明单行，移动端双行 + 50% 背景。
        desktopLyricsSettings = DesktopLyricsSettings.platformDefault(
          isDesktop: isDesktopFormFactor,
        );
      }
    } else {
      // 旧版本残留直接丢弃，并把版本号写到最新，避免每次启动重复判断。
      // 必须同时删除旧 JSON：只写版本号的话，下次启动 dlVersion 已达标，
      // 上面的读取分支会把 v1 的旧值（旧透明度/字号/锁定态）重新 parse
      // 回来——首启是新默认值、二启复活旧样式，来回翻转。
      // 新安装的默认值按平台取（桌面透明双行 / 移动半透双行），
      // 存量老用户不强制迁移（已有持久化在上个分支原样保留）。
      desktopLyricsSettings = DesktopLyricsSettings.platformDefault(
        isDesktop: isDesktopFormFactor,
      );
      await prefs.remove(_desktopLyricsSettingsKey);
      await prefs.setInt(
        _desktopLyricsSettingsVersionKey,
        _desktopLyricsSettingsVersion,
      );
    }
    // 本方法从构造函数 unawaited 发起，任何 await 之后都可能已被 dispose
    // （测试里创建后即刻销毁是常态）：继续通知/驱动引擎都会踩
    // "used after being disposed"。
    if (_disposed) return;
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
    unawaited(_applySurround());
    // 映射恢复完再对齐当前歌：构造函数里 _restorePlaybackState 也是
    // unawaited 发起，可能已经先把 currentSong 落定（那时映射还是空的）。
    // 只在映射里确有此歌时才装载：当前歌没有记录意味着原始进度，直接调用
    // 会把启动瞬间用户刚调好的偏移抹回 0（那次调整一定已经写进映射）。
    final offsetSong = currentSong;
    if (offsetSong != null && _lyricOffsets.containsKey(offsetSong.hash)) {
      _loadLyricOffsetForSong(offsetSong);
    }
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
      final savedIndex = state['currentIndex'] as int? ?? 0;
      final savedHash = state['currentSongHash'] as String? ?? '';
      // 优先按 hash 找回当前歌（窗口保存后相对下标不再等于原始下标）；
      // 旧数据没有 hash/baseIndex，退化为下标 clamp。
      var index = savedHash.isEmpty
          ? -1
          : queueList.indexWhere((song) => song.hash == savedHash);
      if (index < 0) {
        // 回退只能用**窗口内**的相对下标：queueList 是「以当前歌为中心」的
        // 窗口（长度 ≤ _playbackStateMaxQueueSize），而 currentIndex 存的就是
        // 相对下标（见 _savePlaybackState 的 index - base）。
        // 曾误写成 base + savedIndex，把原队列的绝对下标当窗口下标用——
        // base>0 且 hash 找不回（当前歌 hash 为空，如云盘来源）时会 clamp 到
        // 窗口末尾，恢复成完全另一首歌，且下次保存把错位置固化。
        // 旧快照（无 queueBaseIndex，存的是绝对下标）在本式下语义不变：
        // 越界同样 clamp 到窗口末尾。
        index = (savedIndex >= 0 ? savedIndex : 0).clamp(
          0,
          queueList.length - 1,
        );
      }
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

      // 恢复播放进度：全局单点（最后在播那首 + 位置），只在 hash 对上时采用。
      // 写进内存的 position 有两个用处：暂停态下界面直接显示「上次听到 03:12」，
      // 以及未开自动播放时用户点播放能从这里续（见 togglePlay 的 idle 分支）。
      final restoredSong = currentSong;
      final savedPosition = restoredSong == null
          ? null
          : parseSavedPosition(
              prefs.getString(_currentPositionKey),
              restoredSong.hash,
            );
      if (restoredSong != null &&
          savedPosition != null &&
          _isResumablePosition(restoredSong, savedPosition)) {
        _setPositionBase(savedPosition, playing: false);
        _lastSmoothPosition = savedPosition;
        _emitPosition();
        _resumePosition = savedPosition;
      } else {
        _resumePosition = null;
      }

      // 与 _restoreSettings 同理：构造函数 unawaited 发起，await 之后
      // 可能已 dispose，不得再通知或触发补拉。
      if (_disposed) return;
      hasRestoredPlaybackState = true;
      notifyListeners();
      final restored = currentSong;
      if (restored != null) {
        // 恢复出来的这首歌可能带过歌词进度偏移（映射此刻通常已就绪；
        // 万一晚到，_restoreSettings 末尾还会再对齐一次）。
        _loadLyricOffsetForSong(restored);
        unawaited(loadLyrics(restored));
        unawaited(_loadClimax(restored));
      }
    } catch (error) {
      // 恢复失败不阻断启动，但持久化数据半损坏（字段类型变化等）时必须
      // 留有线索，否则"重启后队列静默丢失"无从排查。
      debugPrint('[时音][player] 播放状态恢复失败（跳过）: $error');
    }
  }

  void _syncListeningTimeTracker() {
    final shouldTrack =
        addListeningTimeEnabled && isPlaying && currentSong != null;
    if (shouldTrack) {
      final startedAt = _listenTimeStartedAt ??= _listenClock();
      _statsListenAnchor ??= startedAt;
      _listenTimeHeartbeat ??= startedAt;
      _listenTimeTimer ??= Timer.periodic(
        _listenTimeCheckInterval,
        (_) => _tickListeningTime(),
      );
      return;
    }

    _pauseListeningTimeTracker();
  }

  /// 15s 心跳一次：先吸收未观测空档，再结算本地统计与服务端上报。
  void _tickListeningTime() {
    _absorbListenTimeStall();
    // 本地统计按增量累计；写盘按 _statsListenFlushInterval 节流，
    // 不依赖服务端上报是否成功。
    _flushListenTimeToStats();
    unawaited(_maybeReportListeningTime());
  }

  void _pauseListeningTimeTracker() {
    // 暂停/切歌/dispose 可能紧跟在一次休眠之后：先吸收空档，否则下面
    // 这段墙钟差会把休眠时长整段算进余量与统计。
    _absorbListenTimeStall();
    final startedAt = _listenTimeStartedAt;
    if (startedAt != null) {
      _pendingListenTime += _listenClock().difference(startedAt);
      _listenTimeStartedAt = null;
      // 暂停/切歌/dispose 都会走到这里：把本段新增时长并入余量后落盘，
      // 否则进程被杀时这段时长直接丢失（上游 3.3.0 #151）。
      unawaited(_savePendingListenTime());
    }
    // 暂停/切歌/dispose：立即结清（force），不因节流丢掉最后一段。
    _flushListenTimeToStats(force: true);
    _statsListenAnchor = null;
    _listenTimeHeartbeat = null;
    _listenTimeHeartbeatPosition = null;
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
  }

  /// 吸收「进程没被调度」造成的未观测空档。
  ///
  /// 听歌时长是「播放期间的真实耗时」，只能靠 15s 心跳采样：两次心跳之间
  /// 隔了数倍心跳周期，就说明这段时间 Dart 侧没被调度（合盖休眠、UI 线程长
  /// 卡顿、调试断点暂停）。此时墙钟已经前进，直接结算会把整段空档记成听歌
  /// 时长——本地统计一次性多出几十分钟到几小时，服务端余量也会跟着虚增。
  ///
  /// 处理方式：先看**播放位置证据**。位置也同步前进了就说明音频一直在放
  /// （移动端后台长播被系统冻结 Dart 侧、断点卡住 UI 线程时都是这种），整段
  /// 照常计入；位置基本没动（系统休眠时音频同时停住）才只结算到最后一次心跳
  /// 为止（那是最后确证「还在播放」的时刻），空档按 0 计，锚点推到 now。
  ///
  /// 时钟回拨（负间隔）不采信位置证据，一律走吸收：否则 `now - anchor` 恒为
  /// 负，`_flushListenTimeToStats` 会一直早退，统计冻结到墙钟追回旧锚点为止。
  void _absorbListenTimeStall() {
    final heartbeat = _listenTimeHeartbeat;
    // 未在跟踪时不建立心跳：心跳只由 `_syncListeningTimeTracker` 起播时
    // 初始化，避免非播放期间的一次调用把"上次心跳"挪到现在。
    if (heartbeat == null) return;
    final now = _listenClock();
    _listenTimeHeartbeat = now;
    // 每拍都刷新位置基线：空档判定要和"上一次心跳那一刻"的位置比，
    // 只在与空档时更新会把基线越放越旧，正常播放也会被误判成"位置前进"。
    final position = _readPlaybackPosition();
    final previousPosition = _listenTimeHeartbeatPosition;
    _listenTimeHeartbeatPosition = position;
    final gap = now.difference(heartbeat);
    if (gap.abs() <= _listenTimeStallThreshold) return;

    if (gap > Duration.zero &&
        _listenGapBackedByProgress(previousPosition, position, gap)) {
      // 位置证据成立：这段是真实播放（不丢数），锚点/余量都不用动，
      // 下一次 flush 会把整段正常结算。
      debugPrint(
        '[时音][listen-time] 空档有播放位置证据，照常计入 ${gap.inSeconds}s',
      );
      return;
    }

    final anchor = _statsListenAnchor;
    if (anchor != null) {
      final observed = heartbeat.difference(anchor);
      if (observed > Duration.zero) {
        unawaited(_statsService.addListenTime(observed));
      }
      _statsListenAnchor = now;
    }
    final startedAt = _listenTimeStartedAt;
    if (startedAt != null) {
      final observed = heartbeat.difference(startedAt);
      if (observed > Duration.zero) _pendingListenTime += observed;
      _listenTimeStartedAt = now;
    }
    debugPrint(
      '[时音][listen-time] 跳过未观测空档 ${gap.inSeconds}s'
      '（休眠/长卡顿/时钟跳变）',
    );
  }

  /// 读当前播放位置；引擎未就绪或平台不提供时返回 null（视为「无证据」，
  /// 退化成旧行为：按空档吸收）。位置读取绝不能影响结算本身。
  Duration? _readPlaybackPosition() {
    try {
      return audioPlayer.position;
    } catch (_) {
      return null;
    }
  }

  /// 未观测空档是否被播放位置推进坐实。
  ///
  /// 门槛取「前进 ≥ 空档一半」而不是接近 1:1：解码缓冲/暂停切换会让位置略
  /// 滞后于墙钟。这个门槛同时能排除两类必须丢弃的情况：
  /// - 系统休眠：音频同时停住，位置只剩休眠前那几十毫秒，远不到一半；
  /// - 回拨/切歌后位置归零（advanced 为负）：交给调用方按空档吸收。
  bool _listenGapBackedByProgress(
    Duration? before,
    Duration? after,
    Duration gap,
  ) {
    if (before == null || after == null) return false;
    final advanced = after - before;
    return advanced >= gap ~/ 2;
  }

  /// 把距上次锚点的听歌时长增量写入本地统计。
  ///
  /// 与服务端上报完全解耦：未登录、接口失败时统计照常增长（此前只在
  /// `addListeningTime` 成功后才按整 5 分钟累加，导致统计恒为 0）。
  ///
  /// 周期 tick 走节流（[force] = false，满 [_statsListenFlushInterval] 才写）；
  /// 暂停/切歌/关闭开关/上报结束等需要立即结清的场景传 [force] = true。
  void _flushListenTimeToStats({bool force = false}) {
    final anchor = _statsListenAnchor;
    if (anchor == null) return;
    final now = _listenClock();
    final delta = now.difference(anchor);
    if (delta <= Duration.zero) return;
    if (!force) {
      // 桌面端 prefs 是纯 Dart 实现（整文件重编码+同步写盘），频率要更保守。
      final interval = isDesktopFormFactor
          ? _statsListenFlushIntervalDesktop
          : _statsListenFlushInterval;
      if (delta < interval) return;
    }
    _statsListenAnchor = now;
    unawaited(_statsService.addListenTime(delta));
  }

  void _resetListeningTimeTracker() {
    _listenTimeStartedAt = null;
    _statsListenAnchor = null;
    _listenTimeHeartbeat = null;
    _listenTimeHeartbeatPosition = null;
    _pendingListenTime = Duration.zero;
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
    // 重置要落盘：只清内存的话，下次启动会把旧余量读回来（关闭开关后
    // 仍在上报）。这里显式写 0 而非删除 key——语义明确、也避免读到脏值。
    unawaited(_savePendingListenTime());
  }

  Duration _trackedListeningTime() {
    final startedAt = _listenTimeStartedAt;
    if (startedAt == null) {
      return _pendingListenTime;
    }
    return _pendingListenTime + _listenClock().difference(startedAt);
  }

  Future<void> _maybeReportListeningTime() async {
    if (_isReportingListenTime || !addListeningTimeEnabled) {
      return;
    }
    // 上报判定同样基于墙钟差：先吸收空档，否则休眠后第一次判定会把整段
    // 休眠顶成"已满 5 分钟"，余量虚增后还会按 15s 一次连续补报。
    _absorbListenTimeStall();
    if (_trackedListeningTime() < _listenTimeReportInterval) {
      return;
    }

    _isReportingListenTime = true;
    try {
      await _api.addListeningTime();
      // 请求在途期间可能经历休眠：结清余量前再吸收一次空档，否则休眠
      // 时长会被算进余量并触发连续补报。
      _absorbListenTimeStall();
      // 本地统计已在 15s tick / 暂停时独立累计，这里不再按整 5 分钟补记
      // （否则未登录或上报失败时统计恒为 0）。
      final stillPlaying = isPlaying && currentSong != null;
      final remainder = _trackedListeningTime() - _listenTimeReportInterval;
      _pendingListenTime = remainder > Duration.zero
          ? remainder
          : Duration.zero;
      _listenTimeStartedAt = stillPlaying ? _listenClock() : null;
      if (!stillPlaying) {
        // 上报期间刚好暂停/播完：把最后一段写进统计并结束锚点，避免下次
        // 起播时用旧锚点算出超长增量。
        _flushListenTimeToStats(force: true);
        _statsListenAnchor = null;
        _listenTimeHeartbeat = null;
        _listenTimeHeartbeatPosition = null;
        _listenTimeTimer?.cancel();
        _listenTimeTimer = null;
      }
      // 上报成功后余量（可能不足 5min）同样落盘：下次启动接着累计。
      unawaited(_savePendingListenTime());
    } catch (error) {
      debugPrint('[时音][listen-time] report failed: $error');
    } finally {
      _isReportingListenTime = false;
    }
  }

  /// 把未满上报周期的听歌时长余量写入本地（跨会话累计）。
  ///
  /// 失败静默：统计不是关键路径，写失败最多让重启后少累计一个周期，
  /// 不能因此弹错误或影响播放。
  Future<void> _savePendingListenTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _pendingListenTimeMsKey,
        _pendingListenTime.inMilliseconds,
      );
    } catch (_) {}
  }

  // ---- 仅供测试的只读/触发钩子（见 test/controllers/player_listen_time_test.dart）----
  // 听歌时长由 Timer + DateTime 驱动，5min 周期无法在单测里真实等待；
  // 暴露只读余量与单次上报触发点，使 restore/落盘/失败路径可确定性验证。

  @visibleForTesting
  Duration get pendingListenTimeForTest => _pendingListenTime;

  @visibleForTesting
  Future<void> reportListeningTimeForTest() => _maybeReportListeningTime();

  /// 单次心跳（等价于 15s 定时器触发一次），配合 [setListenClockForTest]
  /// 可用假时钟逐跳推进，确定性验证休眠/时钟跳变下的累计。
  @visibleForTesting
  void tickListeningTimeForTest() => _tickListeningTime();

  /// 注入听歌时长的时间源（默认墙钟）。测试用它模拟系统休眠/时钟回拨：
  /// 真实等待数十分钟既不现实也不该出现在单测里。
  @visibleForTesting
  void setListenClockForTest(DateTime Function() clock) {
    _listenClock = clock;
  }
}
