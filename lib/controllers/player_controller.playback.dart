// player_controller.playback.dart —— PlayerController 的职责分片：播放主流程（加载/播放/seek/完成回调/高潮试听/音量与倍速）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerPlayback on _PlayerControllerBase {
  /// 当前用户音量（0.0–1.0）。桌面播放栏音量滑杆使用。
  /// 注意：返回用户值而非引擎值——引擎值含响度系数，直接读它滑块会跳。
  double get volume => userVolume;

  /// 设置用户音量（0.0–1.0），越界值自动夹取。
  /// 经响度系数合成后 instant 应用（打断在途 ramp 跟手），不破坏响度比。
  /// 音量会被快捷键等非 UI 入口修改，通知监听者以同步播放栏滑块。
  /// 拖动滑杆/滚轮调节会高频调用：引擎音量即时应用保持跟手，SharedPreferences
  /// 落盘防抖合并（此前每 tick 一次磁盘写，且写完才应用音量，拖动发涩）。
  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    userVolume = clamped;
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = Timer(const Duration(milliseconds: 500), () {
      _volumePersistDebounce = null;
      unawaited(_persistUserVolume(clamped));
    });
    await _applyLoudnessGain(instant: true);
    notifyListeners();
  }

  Future<void> _persistUserVolume(double clamped) async {
    _persistedUserVolume = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_userVolumeSettingKey, clamped);
  }

  /// 尽快落盘未写入的用户音量（dispose 时防抖窗口内还有最后一次调节）。
  void _flushPendingVolumePersist() {
    final pending = _volumePersistDebounce?.isActive ?? false;
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = null;
    if (pending && userVolume != _persistedUserVolume) {
      unawaited(_persistUserVolume(userVolume));
    }
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
      // 切换新歌立即暂停旧歌，避免新歌加载/解析期间旧音频继续播放导致音画脱节
      unawaited(_audioHandler.pause());
      duration = song.duration ?? Duration.zero;
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
      } else {
        // 未命中:新歌增益未知,上一首的增益先中性化(渐变回用户音量),
        // 杜绝新歌开头带着旧增益播放(分析完成后会再渐变到真实值)。
        _resetStaleLoudnessGain();
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
      // 起播成功：连续失败 streak 整体归零（含已自动跳过的计数）。
      _consecutivePlayFailures = 0;
      _autoSkippedInStreak = 0;
      _autoSkipStreakSince = null;
      // 记录播放历史与本地播放统计（后台执行，不阻塞播放）
      unawaited(_historyService.record(song));
      unawaited(_statsService.recordPlay(song));
      // 首播后后台缓存（仅当本次用的是网络 URL，且当前网络允许）。
      // 蜂窝网络默认跳过音频下载（只播不存），避免移动流量翻倍；
      // 用户在设置中放行后才缓存。
      if (networkUrl != null && isAudioPrecacheAllowed) {
        unawaited(
          downloadController?.cacheForPlayback(song, audioQuality, networkUrl),
        );
      } else if (networkUrl != null) {
        debugPrint('[时音][player] 蜂窝网络跳过播后缓存: ${song.title}');
      }
    } catch (error) {
      if (_disposed) return;
      // VIP 过期：自动领取后重试一次（转发定位/队列上下文，避免冷启动
      // 定位与高潮试听从 0 秒重播）。isRetry 内不再领取：重试后仍报 VIP
      // 说明领取无效/服务端持续拒绝，不设限会形成"领取→重试→再领取"无限循环。
      if (!isRetry && error is VipRequiredException && vipClaim != null) {
        final claimed = await _tryClaimVipAndRetry(
          song,
          queue: queue,
          initialPosition: initialPosition,
          preserveClimax: preserveClimax,
        );
        if (claimed) return;
      }
      // 网络类失败（非 VIP、非首次重试）：短暂等待后自动重试一次。
      // 车机弱网/网络切换瞬间首次请求常失败，重试后即可恢复；
      // 确定性错误（如"没有可播放地址"）重试成本低，统一兜底一次。
      //
      // 例外：已进入"连续失败自动跳过"状态（_autoSkippedInStreak > 0）时
      // 不再逐首重试——此时基本是网络/服务端级故障，每首再等 2 秒会把
      // 跳过扫描拖成数分钟的跳歌风暴，直接计入失败并继续跳。
      if (!isRetry &&
          error is! VipRequiredException &&
          _autoSkippedInStreak == 0) {
        // 等待期间用户可能已切歌：旧歌的自动重试不得抢回播放权。
        if (currentSong?.hash != song.hash) {
          debugPrint('[时音][player] 重试前歌曲已切换，放弃重试: ${song.title}');
          return;
        }
        errorMessage = '播放失败，正在重试...';
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 2));
        if (_disposed) return;
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
      unawaited(_audioHandler.pause());
      duration = song.duration ?? Duration.zero;
      _pendingInitialPosition = null;
      _setPositionBase(Duration.zero, playing: false);
      _lastSmoothPosition = Duration.zero;
      _emitPosition();
      errorMessage = error.toString();
      isPreparing = false;
      notifyListeners();
      // 已走完 VIP 领取与自动重试仍失败：计一次最终失败，达阈值自动前进。
      _registerPlaybackFailure(song);
    } finally {
      var depth = _changingSourceDepth;
      if (depth > 0) {
        depth = --_changingSourceDepth;
      }
      if (!_disposed) {
        // 守卫归属：_pendingInitialPosition / isPreparing 属于"最新的在途
        // 加载流程"。本流程被更新流程抢先而中止时（hash 检查 return），
        // finally 不得清掉新流程刚设置的守卫——否则加载期间引擎的 0 秒
        // 位置事件会把进度/歌词闪回开头、加载态提前消失。仅在深度归零
        // （没有任何在途流程）时才允许清。
        if (depth == 0) {
          _pendingInitialPosition = null;
          if (isPreparing) {
            isPreparing = false;
            notifyListeners();
          }
        }
        _scheduleSavePlaybackState();
      }
    }
  }

  /// 播放中的中途错误处理（接入点见构造器 `_errorSub`）。
  ///
  /// 断流/解码失败发生时 load 早已成功、[playSong] 已返回，错误不经其
  /// catch 分支；底层 `playing` 不变（mpv 只是停止出数据），没有这里的
  /// 话 isPlaying 恒为 true、smoothPosition 持续外推，界面"假播放"到
  /// 曲尾。与 playSong 失败路径做相同收尾（暂停引擎、复位位置展示），
  /// 并计入连续失败 streak 复用 3 次阈值自动跳过；同时写入 errorMessage
  /// ——网络恢复钩子（onConnectivityRestored）会据此自动重播一次。
  void _handleMidPlaybackError(PlayerException error) {
    if (_disposed) return;
    final song = currentSong;
    if (song == null) return;
    // 加载/换源期的错误由 playSong 的失败路径统一处理，避免双重计数。
    if (isPreparing || _isChangingSource) return;
    // 用户已暂停时迟到的错误不处理（无"假播放"问题，保留现场等用户操作）。
    if (!isPlaying) return;
    debugPrint('[时音][player] 播放中出错: ${song.title} ($error)');
    unawaited(_audioHandler.pause());
    duration = song.duration ?? duration;
    _setPositionBase(Duration.zero, playing: false);
    _lastSmoothPosition = Duration.zero;
    _emitPosition();
    errorMessage = '播放中断，请稍后重试';
    notifyListeners();
    _registerPlaybackFailure(song);
  }

  /// 记录一次最终播放失败（已走完 VIP 领取与自动重试）。
  ///
  /// 连续失败达 [_kAutoSkipFailureThreshold] 次后自动跳到下一首：坏源
  /// （无版权/地址失效）与断网场景下，播放器此前会永久卡在同一首的错误态，
  /// 用户只能手动一首首点。跳过策略：
  /// - 单曲队列不跳（无处可去，保持错误态提示）；
  /// - 本轮 streak 内跳过次数上限 = min(队列长度, [_kMaxAutoSkipsPerStreak])：
  ///   连续多首失败说明是网络/服务端问题而非单曲问题，早点停下报错——
  ///   每首都要走一遍自动重试（2s 等待），长队列会变成数分钟的跳歌风暴；
  /// - 墙钟预算 [_kAutoSkipWallClockBudget]：弱网下每首跳过仍要 15-20s
  ///   的地址解析，只按次数限制最坏要 2-3 分钟才停，超时即停；
  /// - 任一首成功起播即整体归零（见 playSong 起播后的清零）。
  void _registerPlaybackFailure(Song song) {
    if (_disposed) return;
    _consecutivePlayFailures++;
    if (_consecutivePlayFailures < _kAutoSkipFailureThreshold) {
      Toast.error('《${song.title}》暂无可播放音源');
      return;
    }

    final queueLength = queue.length;
    if (queueLength <= 1) {
      Toast.error('《${song.title}》暂无可播放音源');
      return;
    }
    final skipLimit = queueLength < _kMaxAutoSkipsPerStreak
        ? queueLength
        : _kMaxAutoSkipsPerStreak;
    final since = _autoSkipStreakSince ??= DateTime.now();
    final overBudget =
        DateTime.now().difference(since) >= _kAutoSkipWallClockBudget;
    if (_autoSkippedInStreak >= skipLimit || overBudget) {
      debugPrint(
        '[时音][player] 连续失败 $_consecutivePlayFailures 次，本轮已自动跳过 '
        '$_autoSkippedInStreak 首（上限 $skipLimit'
        '${overBudget ? '，已超墙钟预算 $_kAutoSkipWallClockBudget' : ''}），停止跳转',
      );
      Toast.error('连续多首歌曲播放失败，已停止播放');
      return;
    }
    _autoSkippedInStreak++;
    debugPrint(
      '[时音][player] 连续失败 $_consecutivePlayFailures 次，自动跳过: ${song.title}',
    );
    Toast.show('《${song.title}》播放失败，已跳过');
    // 脱离当前调用栈：本流程的 finally 尚未执行，直接 await next() 会形成
    // 逐曲嵌套的 await 链；延后一拍让本次收尾先完成（finally 的深度计数
    // 随后归零，不会误清新流程的守卫）。
    Future<void>.delayed(Duration.zero, () {
      if (_disposed) return;
      unawaited(next());
    });
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
    // listener 必须在拿到图/出错后自摘（与 precacheImage 内部同款）：
    // 常驻监听会让 ImageStreamCompleter 永远判定为 live，解码后的封面
    // 脱离 ImageCache 的 LRU 淘汰，长会话播放数百首后内存持续累积。
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) => stream.removeListener(listener),
      onError: (_, _) => stream.removeListener(listener),
    );
    stream.addListener(listener);
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
  /// 转发调用方的队列/定位/高潮上下文，避免重试丢定位。
  @override
  Future<bool> _tryClaimVipAndRetry(
    Song song, {
    List<Song>? queue,
    Duration? initialPosition,
    bool preserveClimax = false,
  }) async {
    try {
      final result = await vipClaim!.claimNow(null);
      if (result.status == VipClaimStatus.success ||
          result.status == VipClaimStatus.alreadyClaimed) {
        debugPrint('[时音][player] VIP 已领取，重试播放: ${song.title}');
        final playUrl = await _api.songUrl(song, quality: audioQuality);
        if (playUrl.url.isNotEmpty) {
          errorMessage = null;
          // 重新走完整播放流程（保留定位与高潮武装）；
          // isRetry 防止服务端反复在"下发 URL"与 VIP 异常之间抖动时形成无限领取/重试递归。
          unawaited(
            playSong(
              song,
              queue: queue,
              initialPosition: initialPosition,
              preserveClimax: preserveClimax,
              isRetry: true,
            ),
          );
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
      // 仅 idle 吞错：无音频源时靠 _pendingIdlePosition 兜底。
      // 非 idle 下的引擎错误（蓝牙断开/后端抖动）必须抛给调用方，
      // 否则 UI 已显示目标进度、引擎仍在旧位，声画脱节且无错误。
      if (audioPlayer.processingState != ProcessingState.idle) {
        rethrow;
      }
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
      try {
        await seek(target);
      } catch (error) {
        // UI 调用方（歌词行点击等）丢弃本 Future：seek 在非 idle 引擎错误
        // （蓝牙断开/后端抖动）下会故意 rethrow（见 seek 注释），这里不接住
        // 就成了未捕获异步异常。与 queue.dart 的 _seekToStartSafe 同理。
        debugPrint('[时音][player] seekToAndPlay 失败: $error');
        return;
      }
      if (!audioPlayer.playing) {
        // 调用方（歌词点击等）常丢弃本 Future，togglePlay 失败必须就地接住，
        // 否则成为未取消认领的异步异常（与上方 seek 的处理同理）。
        try {
          await togglePlay();
        } catch (error) {
          debugPrint('[时音][player] seekToAndPlay 起播失败: $error');
        }
      }
    }
  }

  Future<void> _handleCompleted() async {
    final song = currentSong;
    if (song == null) return;
    if (_completedSongHash == song.hash) return;
    if (_isHandlingCompletion) {
      // 旧歌仍在处理（弱网解析下一首可能挂起数秒）：同歌去重，
      // 不同歌说明用户已切走且新歌又播完，放行新歌，旧流程自弃
      if (_handlingCompletedHash == song.hash) return;
      debugPrint('[时音][player] 上一首完成处理中，新歌又完成，直接处理新歌');
    }
    _isHandlingCompletion = true;
    _handlingCompletedHash = song.hash;
    _completionFallbackTimer?.cancel();
    _completedSongHash = song.hash;

    try {
      if (_sleepFinishCurrentSong) {
        _sleepFinishCurrentSong = false;
        _sleepFinishCurrentSongOption = false;
        sleepTimerRemaining = null;
        notifyListeners();
        unawaited(_audioHandler.pause());
        return;
      }

      if (playbackMode == PlaybackMode.singleLoop) {
        // 重启完成后再清去重 hash：重启在途中重复 completed 事件仍去重，
        // 避免 self-loop 打转；下一轮正常播完可再次触发
        await seek(Duration.zero);
        if (currentSong?.hash != song.hash) return;
        await _audioHandler.play();
        _completedSongHash = null;
        return;
      }

      final nextSong = _nextSong();
      if (nextSong == null) {
        await seek(Duration.zero);
        return;
      }
      await playSong(nextSong, queue: queue);
    } catch (error) {
      // playSong 内部不抛；这里只可能是 seek/play 引擎异常，记日志
      // 落错误态，避免 unawaited 调用方的未处理异常
      debugPrint('[时音][player] 完成处理失败: $error');
      if (currentSong?.hash == song.hash) {
        errorMessage = error.toString();
        notifyListeners();
      }
    } finally {
      // 只复位自己绑定的锁：并发的新歌流程不受旧 finally 影响
      if (_handlingCompletedHash == song.hash) {
        _isHandlingCompletion = false;
        _handlingCompletedHash = null;
      }
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
      // 建 timer 时绑定歌曲：触发时已切歌则丢弃，避免旧 timer 推新歌连跳
      final songHash = currentSong?.hash;
      _completionFallbackTimer = Timer(delay, () {
        if (!isPlaying || _isSeeking || _isScrubbing) return;
        if (currentSong?.hash != songHash) return;
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
  /// 返回 true 表示成功开始播放（或用户在恢复期间手动接管了播放）。
  Future<bool> resumePlayback() async {
    if (currentSong == null || queue.isEmpty) return false;

    final maxAttempts = queue.length;
    var songToPlay = currentSong!;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      errorMessage = null;
      await playSong(songToPlay, queue: queue);
      // 恢复链可能耗时数秒（地址解析+重试），期间用户可能已手动点了别的歌：
      // currentSong 已换人时立即收手，绝不再用 _nextSong() 抢占用户的选择。
      if (currentSong?.hash != songToPlay.hash) return true;
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
