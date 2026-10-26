// player_controller.personalfm.dart —— PlayerController 的职责分片：私人 FM。
//
// 对应酷狗官方「猜你喜欢」入口（api.json 的 `/personal/fm`，mode=normal 即
// 「红心 Radio」+ 根据听歌口味推荐）。会话语义：
// - [startPersonalFm] 拉首批（或复用首页已预取的预览批次）并立即开播；
// - 会话进行中队列播到末尾时自动续拉下一批（自然播完 isOverplay=true、
//   手动"下一首" isOverplay=false），不循环、不随机；
// - 手动"上一首"仍可在本次会话已推荐过的歌里回退；
// - 用户在其它列表点歌（播放队列被替换）时自动退出会话；
// - 播放地址统一走 hash-only（FM 歌曲没有可靠的专辑/音频 id）。
// 成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerPersonalFm on _PlayerControllerBase {
  @override
  bool get _isAtQueueEnd {
    final index = currentIndex;
    return index >= 0 && index == queue.length - 1;
  }

  String _songIdentity(Song song) {
    if (song.hash.isNotEmpty) {
      return 'hash:${song.hash}';
    }
    if (song.albumAudioId?.isNotEmpty == true) {
      return 'audio:${song.albumAudioId}';
    }
    return song.id.isEmpty ? '' : 'id:${song.id}';
  }

  @override
  bool _isSameQueue(List<Song> a, List<Song> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_songIdentity(a[i]) != _songIdentity(b[i])) return false;
    }
    return true;
  }

  /// 启动固定为「红心 Radio + 根据口味」的私人 FM 会话。
  ///
  /// [initialSongs] 为首页已预取的预览批次：非空时直接复用，点按到出声之间
  /// 不再多等一次网络；为空则现拉。
  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async {
    if (_disposed || _isLoadingPersonalFm) {
      return false;
    }

    _isLoadingPersonalFm = true;
    final requestSerial = ++_personalFmRequestSerial;
    errorMessage = null;
    notifyListeners();
    try {
      final songs = initialSongs?.isNotEmpty == true
          ? List<Song>.of(initialSongs!)
          : await _api.personalFm();
      if (_disposed || requestSerial != _personalFmRequestSerial) {
        return false;
      }
      if (songs.isEmpty) {
        errorMessage = '暂时没有新的私人 FM 推荐';
        return false;
      }

      _isPersonalFmActive = true;
      await playSong(
        songs.first,
        queue: songs,
        preservePersonalFmSession: true,
      );
      return errorMessage == null;
    } catch (error) {
      if (requestSerial == _personalFmRequestSerial) {
        errorMessage = error.toString();
      }
      return false;
    } finally {
      if (requestSerial == _personalFmRequestSerial) {
        _isLoadingPersonalFm = false;
        if (!_disposed) {
          notifyListeners();
        }
      }
    }
  }

  @override
  Future<void> _loadNextPersonalFmBatch({required bool isOverplay}) async {
    final song = currentSong;
    if (_disposed || !_isPersonalFmActive || song == null || !_isAtQueueEnd) {
      return;
    }
    if (_isLoadingPersonalFm) {
      return;
    }

    _isLoadingPersonalFm = true;
    final requestSerial = ++_personalFmRequestSerial;
    errorMessage = null;
    notifyListeners();
    try {
      var incoming = await _api.personalFm(
        hash: song.hash.isEmpty ? null : song.hash,
        songId: song.id.isEmpty ? null : song.id,
        playtime: smoothPosition.inSeconds,
        isOverplay: isOverplay,
      );
      if (_disposed || requestSerial != _personalFmRequestSerial) {
        return;
      }
      if (!_isPersonalFmActive || currentSong != song || !_isAtQueueEnd) {
        return;
      }

      var additions = _personalFmAdditions(incoming, song);
      if (additions.isEmpty) {
        // 带播放反馈的请求没有新增（服务端同一首反复回同一批）时，退回
        // 「纯刷新」再拉一次，与上游行为一致。
        incoming = await _api.personalFm();
        if (_disposed ||
            requestSerial != _personalFmRequestSerial ||
            !_isPersonalFmActive ||
            currentSong != song ||
            !_isAtQueueEnd) {
          return;
        }
        additions = _personalFmAdditions(incoming, song);
      }
      if (additions.isEmpty) {
        errorMessage = '私人 FM 暂时没有新的推荐歌曲';
        return;
      }

      queue = [...queue, ...additions];
      await playSong(
        additions.first,
        queue: queue,
        preservePersonalFmSession: true,
      );
    } catch (error) {
      if (requestSerial == _personalFmRequestSerial) {
        errorMessage = error.toString();
      }
    } finally {
      if (requestSerial == _personalFmRequestSerial) {
        _isLoadingPersonalFm = false;
        if (!_disposed) {
          notifyListeners();
        }
      }
    }
  }

  /// 从一批推荐里筛出可追加的新歌：排除当前歌与队列里已有的歌（避免
  /// 长期 FM 会话把同一首重复插进队列），单批最多 5 首。
  List<Song> _personalFmAdditions(List<Song> incoming, Song current) {
    final currentIdentity = _songIdentity(current);
    final known = queue
        .map(_songIdentity)
        .where((identity) => identity.isNotEmpty)
        .toSet();
    final additions = <Song>[];
    for (final song in incoming) {
      final identity = _songIdentity(song);
      if (identity.isEmpty ||
          identity == currentIdentity ||
          !known.add(identity)) {
        continue;
      }
      additions.add(song);
      if (additions.length == 5) {
        break;
      }
    }
    return additions;
  }
}
