// player_controller.playback.dart —— PlayerController 的职责分片：播放主流程（加载/播放/seek/完成回调/高潮试听/音量与倍速）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerPlayback on _PlayerControllerBase {
  /// 当前音量（0.0–1.0）。桌面播放栏音量滑杆使用。
  double get volume => _audioHandler.audioPlayer.volume;

  /// 设置音量（0.0–1.0），越界值自动夹取。
  /// 音量会被快捷键等非 UI 入口修改，通知监听者以同步播放栏滑块。
  Future<void> setVolume(double value) async {
    await _audioHandler.audioPlayer.setVolume(value.clamp(0.0, 1.0));
    notifyListeners();
  }

  String get playbackSpeedLabel {
    if (playbackSpeed == playbackSpeed.roundToDouble()) {
      return '${playbackSpeed.round()}x';
    }
    return '${playbackSpeed}x';
  }

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
  }) async {
    final isSameSong = currentSong?.hash == song.hash;
    if (!preserveClimax) {
      _climaxEndTime = null;
      climax = null;
    }
    _completionFallbackTimer?.cancel();
    _completedSongHash = null;
    _precachedForSongHash = null;
    _pendingIdlePosition = null;

    if (initialPosition != null && initialPosition > Duration.zero) {
      _pendingInitialPosition = initialPosition;
      _setPositionBase(initialPosition, playing: false);
      _lastSmoothPosition = initialPosition;
      _emitPosition();
    } else {
      _pendingInitialPosition = null;
      _setPositionBase(Duration.zero, playing: false);
      _lastSmoothPosition = Duration.zero;
      _emitPosition();
    }

    // 检查是否有本地音频缓存（已下载/播放缓存）或本地音频文件
    var local = downloadController?.localPathFor(song, audioQuality);
    // 离线/跨音质降级检索：若当前音质无缓存，查找是否有任意可用本地音质文件
    local ??= downloadController?.localPathForAnyQuality(
      song,
      preferredQuality: audioQuality,
    );
    final hasLocalAudio = local != null || song.source == SongSource.local;

    // 切新歌必须清空歌词并重置歌词行；同一首歌重播/从冷启动恢复播放时保留已有歌词防闪烁
    if (!isSameSong) {
      lyrics = const [];
      _lastDesktopLyricIndex = -1;
    }

    // 切新歌或无本地缓存需走网络解析时标记 isPreparing；
    // 同一首歌且有本地缓存时毫秒级即播，无需展示加载态，实现无感体验。
    isPreparing = !isSameSong || !hasLocalAudio;
    _changingSourceDepth++;
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
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final playUrl = await _resolvePlayUrl(song);
        // URL 解析可挂起数秒（弱网/智能音质降级重试链），期间用户可能
        // 已切到另一首（currentSong 已被后者覆盖）：旧歌不得再把引擎与
        // mediaItem 抢回去，歌词/高潮等已有 hash 序号守卫，唯独主播放
        // 路径此前没有。
        if (currentSong?.hash != song.hash) {
          debugPrint('[时音][player] 地址解析期间已切歌，丢弃旧结果: ${song.title}');
          return;
        }
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
      // loadSong（setUrl 等待后端就绪）期间同样可能被更新的切歌抢先：
      // 旧歌的 seek/play/缓存后置动作全部作废，避免新歌被旧歌的
      // 播放指令打回。
      if (currentSong?.hash != song.hash) {
        debugPrint('[时音][player] 加载期间已切歌，中止旧歌后续动作: ${song.title}');
        return;
      }
      if (initialPosition != null && initialPosition > Duration.zero) {
        await seek(initialPosition);
      }
      _pendingInitialPosition = null;
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
      _pendingInitialPosition = null;
      // VIP 过期：自动领取后重试一次
      if (error is VipRequiredException && vipClaim != null) {
        final claimed = await _tryClaimVipAndRetry(song);
        if (claimed) return;
      }
      // 网络类失败（非 VIP、非首次重试）：短暂等待后自动重试一次。
      // 车机弱网/网络切换瞬间首次请求常失败，重试后即可恢复；
      // 确定性错误（如"没有可播放地址"）重试成本低，统一兜底一次。
      if (!isRetry && error is! VipRequiredException) {
        // 等待期间用户可能已切歌：旧歌的自动重试不得抢回播放权。
        if (currentSong?.hash != song.hash) {
          debugPrint('[时音][player] 重试前歌曲已切换，放弃重试: ${song.title}');
          return;
        }
        errorMessage = '播放失败，正在重试...';
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 2));
        if (currentSong?.hash != song.hash) {
          debugPrint('[时音][player] 重试等待期间歌曲已切换，放弃重试: ${song.title}');
          return;
        }
        debugPrint('[时音][player] 播放失败，自动重试: ${song.title} ($error)');
        await playSong(
          song,
          queue: queue,
          isRetry: true,
          initialPosition: initialPosition,
          preserveClimax: preserveClimax,
        );
        return;
      }
      // 确定性失败落错误态前同样确认仍是当前歌：切歌后的旧错误不得
      // 覆盖新歌的加载/播放状态。
      if (currentSong?.hash != song.hash) {
        debugPrint('[时音][player] 失败落错误态前歌曲已切换，跳过: ${song.title}');
        return;
      }
      errorMessage = error.toString();
      isPreparing = false;
      notifyListeners();
    } finally {
      _pendingInitialPosition = null;
      if (_changingSourceDepth > 0) {
        _changingSourceDepth--;
      }
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
  @override
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
      final fallback = PlayerQualityLogic.nextLowerQuality(audioQuality);
      if (fallback == null) return playUrl;
      return _api.songUrl(song, quality: fallback);
    } catch (error) {
      if (!smartQualityEnabled) rethrow;
      // 网络请求失败：尝试降级重试
      final fallback = PlayerQualityLogic.nextLowerQuality(audioQuality);
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

  @override
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
          final initPos =
              _pendingIdlePosition ??
              (position > Duration.zero ? position : null);
          _pendingIdlePosition = null;
          await playSong(song, queue: queue, initialPosition: initPos);
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

  @override
  Future<void> seek(Duration position) async {
    final serial = ++_seekSerial;
    final target = _clampPosition(position);
    _lastSmoothPosition = Duration.zero;
    // 用户手动 seek 后取消高潮武装，避免拖动进度条到高潮结束点后意外自动暂停。
    _climaxEndTime = null;
    _isScrubbing = false;
    _isSeeking = true;
    _setPositionBase(target, playing: isPlaying);
    _emitPosition();

    // 当底层音频引擎处于 idle 状态（如冷启动恢复歌曲但尚未起播）时，
    // 底层尚未加载音频源。此时暂存目标位置，等后续起播时作为 initialPosition 传入，杜绝弹回 0 秒。
    if (audioPlayer.processingState == ProcessingState.idle) {
      _pendingIdlePosition = target;
    }

    try {
      await _audioHandler.seek(target);
      if (serial != _seekSerial) {
        return;
      }
      _setPositionBase(target, playing: isPlaying);
      _emitPosition();
    } catch (_) {
      // idle 状态下底层播放器可能无音频源而抛出异常，此时已由 _pendingIdlePosition 兜底
    } finally {
      if (serial == _seekSerial) {
        _isSeeking = false;
        _isScrubbing = false;
      }
    }
  }

  /// 跳转到指定位置并起播（常用于歌词点击、准星跳转等场景）。
  /// 兼容冷启动/未播放 (idle) 状态，确保直接从指定位置加载并播放，绝不弹回 0 秒。
  Future<void> seekToAndPlay(Duration position) async {
    final song = currentSong;
    if (song == null) return;
    final target = _clampPosition(position);

    if (audioPlayer.processingState == ProcessingState.idle) {
      _pendingIdlePosition = null;
      await playSong(song, queue: queue, initialPosition: target);
    } else {
      await seek(target);
      if (!audioPlayer.playing) {
        await togglePlay();
      }
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
      if (audioPlayer.processingState == ProcessingState.idle) {
        await playSong(
          song,
          queue: queue,
          initialPosition: climax.startTime,
          preserveClimax: true,
        );
      } else {
        await seek(climax.startTime);
        if (!audioPlayer.playing) {
          await togglePlay();
        }
      }
      if (currentSong?.hash != song.hash) return false;
      _climaxEndTime = climax.endTime;
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
  @override
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
}
