// player_controller.queue.dart —— PlayerController 的职责分片：播放队列与切歌导航（模式切换/加入队列/上下曲/预缓存/播放状态持久化）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerQueue on _PlayerControllerBase {
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

  Future<bool> addToQueue(Song song) async {
    final added = await addSongsToQueue([song]);
    return added > 0;
  }

  /// 将歌曲插入到「下一首」位置播放
  Future<bool> insertNext(Song song) => addToQueue(song);

  /// 播放单曲但保留当前播放队列（搜索 / 听歌识曲点单曲的默认语义）。
  ///
  /// 与 [playSong] 传 `queue` 的区别：不整体替换播放队列，只把该曲插到
  /// 当前曲之后并立即起播；与 [insertNext] 的区别：会立刻切歌（后者只是
  /// 排队，「下一首播放」语义）。
  ///
  /// - 当前队列为空（冷启动/从未播放过）时退化为一次普通播放：有
  ///   [fallbackQueue] 用它当新队列（搜索/识曲结果列表，保留“连着试听”
  ///   的体验），否则只播这一首。
  /// - 点的就是当前在播歌曲：不重新载入（不打断进度），暂停中则恢复。
  /// - 歌曲已在队列中：直接按队列原位置起播，不重排。
  /// - 否则插到 `currentIndex + 1`（而不是末尾再跳转）：播完后「下一首」
  ///   回到原队列的下一首，顺序不断裂；末尾跳转会因曲末回绕跑到队列开头。
  Future<void> playSongKeepingQueue(
    Song song, {
    List<Song>? fallbackQueue,
    Duration? initialPosition,
  }) async {
    String keyOf(Song item) => item.hash.isNotEmpty ? item.hash : item.id;

    if (queue.isEmpty) {
      final nextQueue = fallbackQueue != null && fallbackQueue.isNotEmpty
          ? List<Song>.of(fallbackQueue)
          : <Song>[song];
      await playSong(song, queue: nextQueue, initialPosition: initialPosition);
      return;
    }

    final current = currentSong;
    if (current != null && keyOf(current) == keyOf(song)) {
      if (!isPlaying) {
        await togglePlay();
      }
      return;
    }

    final existingIndex = queue.indexWhere((item) => keyOf(item) == keyOf(song));
    if (existingIndex >= 0) {
      await playSong(song, queue: queue, initialPosition: initialPosition);
      return;
    }

    final insertAt = (currentIndex >= 0 ? currentIndex + 1 : 0).clamp(
      0,
      queue.length,
    );
    final nextQueue = List<Song>.of(queue)..insert(insertAt, song);
    await playSong(song, queue: nextQueue, initialPosition: initialPosition);
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

  @override
  Future<void> next() async {
    // 私人 FM：队列末尾的「下一首」= 续拉下一批推荐（不循环回第一首）。
    if (_isPersonalFmActive && _isAtQueueEnd) {
      await _loadNextPersonalFmBatch(isOverplay: false);
      return;
    }
    final nextSong = _nextSong();
    if (nextSong == null) return;
    await playSong(
      nextSong,
      queue: queue,
      preservePersonalFmSession: _isPersonalFmActive,
    );
  }

  /// 边界回零（空队列/单曲/首曲 previous）：引擎异常时落错误态而非上抛，
  /// 调用方（按钮直引/快捷键 unawaited）都不接错，上抛即未处理异常。
  Future<void> _seekToStartSafe() async {
    try {
      await seek(Duration.zero);
    } catch (error) {
      debugPrint('[时音][player] 回零失败: $error');
      errorMessage = '定位失败，请重试';
      notifyListeners();
    }
  }

  @override
  Future<void> previous() async {
    if (queue.isEmpty) {
      await _seekToStartSafe();
      return;
    }

    // 私人 FM：严格线性回退（不受随机播放模式影响）；已在会话第一首就回零。
    if (_isPersonalFmActive) {
      final fmIndex = currentIndex;
      if (fmIndex > 0) {
        await playSong(
          queue[fmIndex - 1],
          queue: queue,
          preservePersonalFmSession: true,
        );
      } else {
        await _seekToStartSafe();
      }
      return;
    }

    if (playbackMode == PlaybackMode.shuffle) {
      if (queue.length == 1) {
        await _seekToStartSafe();
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
      await _seekToStartSafe();
    }
  }

  void _maybePrecacheNext(Duration position) {
    final song = currentSong;
    if (song == null || duration <= Duration.zero) return;
    if (_precachedForSongHash == song.hash || _isPrecaching) return;

    final totalMs = duration.inMilliseconds;
    final currentMs = position.inMilliseconds;
    // 至少播放 15 秒（防快切）
    if (currentMs < 15000) return;
    final progress = totalMs > 0 ? currentMs / totalMs : 0.0;
    final remainMs = totalMs - currentMs;

    if (progress >= 0.70 || remainMs <= 25000) {
      _precachedForSongHash = song.hash;
      final next = _nextSong(peek: true);
      if (next != null && next.hash != song.hash) {
        // 蜂窝网络且用户未放行时：只预取歌词（几 KB），不下载音频，
        // 避免移动流量翻倍。_precacheTrack 内部同样有门控，这里
        // 提前标记 hash 避免每 tick 重复触发歌词请求。
        unawaited(_precacheTrack(next));
      }
    }
  }

  Future<void> _precacheTrack(Song song) async {
    _isPrecaching = true;
    try {
      // 1. 预拉取歌词并缓存（流量可忽略，蜂窝网络也执行）
      unawaited(loadLyrics(song));

      // 2. 蜂窝门控：未放行时不下载音频，只预取歌词
      if (!isAudioPrecacheAllowed) {
        debugPrint('[时音][player] 蜂窝网络跳过音频预缓存: ${song.title}');
        return;
      }

      // 3. 检查音频是否已有本地文件（已下载或播放缓存）
      final local = downloadController?.localPathFor(song, audioQuality);
      if (local != null || song.source == SongSource.local) {
        return;
      }

      // 4. 异步解析音频 URL 并后台下载落盘到 PlayCache
      final playUrl = await _resolvePlayUrl(song);
      if (playUrl.url.isNotEmpty) {
        await downloadController?.cacheForPlayback(
          song,
          audioQuality,
          playUrl.url,
        );
      }
    } catch (e) {
      debugPrint('[时音][player] 预缓存失败静默忽略: ${song.title} ($e)');
    } finally {
      _isPrecaching = false;
    }
  }

  @visibleForTesting
  String? get precachedForSongHash => _precachedForSongHash;

  @visibleForTesting
  bool get isPrecaching => _isPrecaching;

  @visibleForTesting
  void maybePrecacheNext(Duration position) => _maybePrecacheNext(position);

  @visibleForTesting
  Future<void> precacheTrack(Song song) => _precacheTrack(song);

  @visibleForTesting
  Song? nextSong({bool peek = false}) => _nextSong(peek: peek);
}
