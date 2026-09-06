// player_controller.lyrics.dart —— PlayerController 的职责分片：歌词与逐行广播（歌词加载/SuperLyric/车载蓝牙歌词）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerLyrics on _PlayerControllerBase {
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

  @override
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
      if (currentSong?.hash == song.hash && !listEquals(lyrics, fresh)) {
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

  /// 进入播放页时的兜底：[loadLyrics] 只在 [playSong] 成功加载音频后触发，
  /// 恢复播放/请求失败等路径下歌词可能为空，进页必须补拉一次。
  /// 已有歌词时直接返回，不产生额外请求。
  Future<void> ensureLyricsLoaded() async {
    final song = currentSong;
    if (song == null || lyrics.isNotEmpty) return;
    await loadLyrics(song);
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
      final lineEndTime =
          line.time +
          (line.duration ??
              _estimatedLineDuration(clampedIndex) ??
              Duration.zero);
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
}
