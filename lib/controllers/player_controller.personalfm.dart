// player_controller.personalfm.dart —— PlayerController 的职责分片：私人 FM。
//
// 对应酷狗官方「猜你喜欢」入口（api.json 的 `/personal/fm`，mode=normal 即
// 「红心 Radio」+ 根据听歌口味推荐）。会话语义：
// - [startPersonalFm] 拉首批（或复用首页已预取的预览批次）并开播；拉取期间
//   用户已暂停/断连/打断结束时只预载队列与音源、不起播，等用户显式播放；
//   若其间用户已重新开始播放，则放弃预载、不打断当前音频；
// - 会话进行中队列播到末尾时自动续拉下一批（自然播完 isOverplay=true、
//   手动"下一首" isOverplay=false），不循环、不随机；
// - 手动"上一首"仍可在本次会话已推荐过的歌里回退；
// - 用户在其它列表点歌（播放队列被替换）时自动退出会话；
// - 播放地址统一走 hash-only（FM 歌曲没有可靠的专辑/音频 id）。
// 成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

/// 私人 FM 队列软上限：与播放状态持久化只存前 `_playbackStateMaxQueueSize`
/// 条对齐。否则长会话（每批 +5）队列无限增长，冷启动恢复时 currentIndex
/// 超出持久化窗口会恢复成错歌；超过上限时丢弃最老的推荐（只影响回退深度）。
const _kPersonalFmMaxQueueLength = _playbackStateMaxQueueSize;

mixin _PlayerPersonalFm on _PlayerControllerBase {
  @override
  bool get _isAtQueueEnd {
    final index = currentIndex;
    return index >= 0 && index == queue.length - 1;
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

    // 用户点按「私人 FM」是显式播放意图：意图要在**网络拉取之前**登记。
    // 拉取期间用户暂停、蓝牙/耳机断开、来电打断结束（默认不自动恢复）都
    // 会推进企图代次；拉取完成后的 playSong 用入口代次校验，对不上就只
    // 装载队列与音源、不起播（用户显式播放即可从这一首继续）。
    // 若期间用户反而重新开始播放（暂停后又按播放/原曲重播，详见下方
    // isPlaying 分支），则放弃预载，别把正在播的音频换掉。
    // 上游 3.3.0 `9426621` 在代次对不上时直接放弃整个启动；本 fork 保留
    // 「队列预载、等用户按播放」的体验，所以把代次带进 playSong。
    _handleManualPlay();
    final intentSerial = _playbackIntentSerial;
    _pendingPlaybackIntent = intentSerial;

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
      if (intentSerial != _playbackIntentSerial && isPlaying) {
        // 拉取期间用户已经重新开始播放（暂停后又按播放、原曲重播等）：
        // 这比点按 FM 更晚，不能用 FM 预载把正在播的音频换掉变成静音。
        // 不返回错误：首页不该弹「加载失败」，FM 卡片也保持未激活。
        return true;
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
        // 意图已在方法入口声明过，这里不能再声明（会解掉拉取期间建立的
        // 断连/打断保护）；把入口代次带进去，拉取期间的暂停/断连/打断
        // 结束才能作废这次起播。被拦下时队列与音源仍装载，用户按播放
        // 就能从这一首继续。
        userInitiated: false,
        expectedIntent: intentSerial,
      );
      return errorMessage == null;
    } catch (error) {
      if (requestSerial == _personalFmRequestSerial) {
        errorMessage = error.toString();
      }
      return false;
    } finally {
      if (requestSerial == _personalFmRequestSerial) {
        // 拉取失败/为空时入口登记的企图不得残留（会被打断开始的
        // 「本来就要播」采样误读）。
        if (_pendingPlaybackIntent == intentSerial) {
          _pendingPlaybackIntent = null;
        }
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
        if (!_disposed) {
          Toast.info('私人 FM 暂时没有新的推荐歌曲，稍后再试');
        }
        return;
      }

      queue = [...queue, ...additions];
      if (queue.length > _kPersonalFmMaxQueueLength) {
        queue = queue.sublist(queue.length - _kPersonalFmMaxQueueLength);
      }
      await playSong(
        additions.first,
        queue: queue,
        preservePersonalFmSession: true,
        // 队列播到末尾的自动续批，不是用户点的「播放」：不能借它解除
        // 「蓝牙断开停止播放」的保护，否则断开后会自己续播到扬声器。
        userInitiated: false,
      );
    } catch (error) {
      if (requestSerial == _personalFmRequestSerial) {
        errorMessage = error.toString();
        // 完成处理已消费掉本次 completed 事件（_completedSongHash 标记），
        // 续批失败后清掉标记：用户重试下一首/重播后还能再次触发自然续批。
        _completedSongHash = null;
        if (!_disposed) {
          Toast.error('私人 FM 加载失败，请稍后再试');
        }
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
