import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../core/api_client.dart';
import '../models/music_models.dart';
import '../services/cache_service.dart';
import '../services/music_api.dart';
import '../services/network_monitor.dart';
import '../services/vip_background_task.dart';

class AuthController extends ChangeNotifier {
  AuthController(this._api, this._cacheService) {
    _vipBackgroundTask.onClaimSuccess = () => refreshProfile(silent: true);
    // 断网启动时 refreshProfile（含 VIP 状态查询）与每日 VIP 领取都会失败，
    // 且没有其他时机补跑；恢复网络后静默刷新用户数据并补跑领取任务
    // （schedule 自带当日去重，当天已领过则直接跳过）。
    _networkRestoredSub = NetworkMonitor.instance.onConnectivityRestored.listen(
      (_) {
        if (!isLoggedIn) return;
        unawaited(() async {
          await refreshProfile(silent: true);
          _vipBackgroundTask.schedule(session);
        }());
      },
    );
  }

  static const _tokenKey = 'shiyin_token';
  static const _t1Key = 'shiyin_t1';
  static const _sessionIdKey = 'shiyin_session_id';
  static const _userIdKey = 'shiyin_user_id';
  static const _playlistCachePrefix = 'shiyin_cached_playlists';
  static const _playlistEmptyCountPrefix = 'shiyin_playlist_empty_count';
  static const _likedHashesKey = 'shiyin_liked_hashes';
  static const _likedFileIdsKey = 'shiyin_liked_fileids';
  final MusicApi _api;
  final CacheService _cacheService;
  late final VipBackgroundTask _vipBackgroundTask = VipBackgroundTask(_api);

  /// 自动领取 VIP 任务，供设置页绑定开关 / 立即领取 / 状态展示。
  VipBackgroundTask get vipClaim => _vipBackgroundTask;

  bool isRestoring = true;
  bool isLoading = false;
  String? errorMessage;
  LoginSession? session;
  UserProfile? profile;
  UserVipInfo? vipInfo;
  List<PlaylistSummary> playlists = const [];

  final Set<String> _likedHashes = {};
  final Map<String, int> _hashToFileId = {};
  StreamSubscription<void>? _networkRestoredSub;

  /// 收藏写操作互斥链：服务端全量同步（清空重建）、单曲点赞增删、
  /// 歌单批量增删对收藏集合的写改统一串行执行，
  /// 避免并发写互相覆盖（刚点下的赞被同步的旧列表清掉）。
  Future<void> _likedMutationLock = Future.value();

  /// 入队一段已持锁的收藏集合变更。链上吞掉错误保证后续任务不被卡死；
  /// 返回原 task 供调用方感知错误（不得在已持有锁的上下文内调用）。
  Future<void> _enqueueLikedMutation(Future<void> Function() body) {
    final task = _likedMutationLock.then((_) => body());
    _likedMutationLock = task.catchError((Object _) {});
    return task;
  }

  bool get isLoggedIn => session?.isValid == true;

  bool isLiked(Song song) => _likedHashes.contains(song.hash);

  int get likedCount {
    final playlist = likedPlaylist;
    if (playlist != null && playlist.songCount != null) {
      return playlist.songCount!;
    }
    return _likedHashes.length;
  }

  /// 点赞切换（乐观更新）：
  ///
  /// 点下瞬间即翻转本地收藏状态并 [notifyListeners]，红心当帧变色；
  /// 服务端确认仍走 [_likedMutationLock] 互斥链串行，失败则回滚本地
  /// 状态并重新通知、原样 rethrow（调用方的 toast 逻辑不变）。
  ///
  /// 乐观翻转与动作快照都在同步段执行（首个 await 之前）：快速连点时
  /// 第二次读到的是已翻转后的状态，方向判定天然正确；链内只执行本次
  /// 点按快照到的动作（增 / 删），不再重新判定方向。
  Future<void> toggleLike(Song song) async {
    final playlist = likedPlaylist;
    if (playlist == null) return;

    final targetListId = playlist.listId?.isNotEmpty == true
        ? playlist.listId!
        : playlist.id;
    // 本次点按的动作快照 + 回滚所需的前态（同步段，无 await）。
    final wasLiked = _likedHashes.contains(song.hash);
    final prevFileId = _hashToFileId[song.hash];
    if (wasLiked) {
      _likedHashes.remove(song.hash);
      _hashToFileId.remove(song.hash);
    } else {
      _likedHashes.add(song.hash);
    }
    notifyListeners();

    // 服务端增删入互斥链，避免被并发的全量同步覆盖。
    final task = _likedMutationLock.then((_) async {
      try {
        Map<String, dynamic>? resp;
        if (wasLiked) {
          // fileId 来源优先级（已持有互斥锁，同步直接跑执行体）：
          // 1. 点按前快照 prevFileId（最可信；乐观段已清映射，必须用快照）；
          // 2. 无快照时先全量同步拿服务端真值，再用映射；
          //    绝不能直接信任 song.id——搜索/首页来的 Song 其 id 是
          //    MixSongID 而非 fileid，用它删服务端会静默失败，
          //    本地乐观移除在下次同步时被打回（“取消红心不生效”）。
          // 3. 同步失败才回退试 song.id（歌单页的 Song 其 id 即 fileid）。
          var fileId = prevFileId;
          if (fileId == null) {
            final synced = await _syncLikedSongsLocked();
            fileId = _hashToFileId[song.hash];
            if (fileId == null) {
              if (synced) {
                // 同步成功但服务端没有此歌：同步结果即真值（比如另一台
                // 设备已取消、或前一次点赞请求失败），保持乐观移除，
                // 不得回滚加回——否则本地与服务端永久分叉。
                notifyListeners();
                await _persistLikedHashes();
                return;
              }
              fileId = _resolvePlaylistFileId(song);
              if (fileId == null) {
                _likedHashes.add(song.hash);
                if (prevFileId != null) _hashToFileId[song.hash] = prevFileId;
                notifyListeners();
                throw Exception('无法定位歌曲在歌单中的 fileid，请下拉刷新后重试');
              }
            }
          }
          try {
            resp = await _api.removeSongsFromPlaylist(
              targetListId,
              [song],
              fileIds: [fileId],
            );
            // Rust 层业务失败不抛错（只回传 status/error_code 信封），
            // 不校验就会“本地已取消、服务端没删”，重启同步后红心回来。
            _ensurePlaylistMutationSuccess(resp, '取消收藏');
          } catch (error) {
            // 快照 fileId 可能是旧值（另一设备删后重加，fileid 已变）：
            // 同步一次拿新 fileId 重试，仍失败才走外层回滚。
            if (prevFileId != null && fileId == prevFileId) {
              final synced = await _syncLikedSongsLocked();
              final freshId = _hashToFileId[song.hash];
              if (synced && freshId != null && freshId != prevFileId) {
                resp = await _api.removeSongsFromPlaylist(
                  targetListId,
                  [song],
                  fileIds: [freshId],
                );
                _ensurePlaylistMutationSuccess(resp, '取消收藏');
                _likedHashes.remove(song.hash);
                _hashToFileId.remove(song.hash);
                _updateLikedCountFromResponse(resp);
                notifyListeners();
                await _persistLikedHashes();
                return;
              }
            }
            rethrow;
          }
          // 幂等确认（同步段已做乐观移除；期间若被全量同步重建则清掉）。
          _likedHashes.remove(song.hash);
          _hashToFileId.remove(song.hash);
        } else {
          resp = await _api.addToPlaylist(targetListId, song);
          _ensurePlaylistMutationSuccess(resp, '收藏');
          // 幂等确认（期间若被全量同步清空则补回）。
          _likedHashes.add(song.hash);
          if (resp != null) {
            final info = resp['info'];
            if (info is List && info.isNotEmpty) {
              final fid = info[0]['fileid'];
              if (fid is int) {
                _hashToFileId[song.hash] = fid;
              } else if (fid is String) {
                final parsed = int.tryParse(fid);
                if (parsed != null) _hashToFileId[song.hash] = parsed;
              }
            }
          }
        }
        _updateLikedCountFromResponse(resp);
        // 先通知再落盘：红心不经过磁盘写等待；await 的仍是完整任务。
        notifyListeners();
        await _persistLikedHashes();
      } catch (error) {
        // 服务端失败：回滚到点按前状态并通知，调用方感知原错误。
        if (wasLiked) {
          _likedHashes.add(song.hash);
          if (prevFileId != null) _hashToFileId[song.hash] = prevFileId;
        } else {
          _likedHashes.remove(song.hash);
          _hashToFileId.remove(song.hash);
        }
        notifyListeners();
        rethrow;
      }
    });
    // 链上吞掉错误，保证后续互斥任务不被前置失败卡死；调用方仍感知原错误。
    _likedMutationLock = task.catchError((Object _) {});
    await task;
  }

  PlaylistSummary? get likedPlaylist {
    for (final playlist in playlists) {
      if (playlist.isLikedPlaylist) {
        return playlist;
      }
    }
    return null;
  }

  List<PlaylistSummary> get createdPlaylists {
    return playlists
        .where(
          (playlist) =>
              !playlist.isCollectedAlbum &&
              (playlist.isCreatedPlaylist || playlist.isSystemDefaultCollect),
        )
        .toList();
  }

  List<PlaylistSummary> get collectedPlaylists {
    return playlists
        .where(
          (playlist) =>
              !playlist.isLikedPlaylist &&
              !playlist.isCollectedAlbum &&
              !playlist.isSystemDefaultCollect &&
              !playlist.isCreatedPlaylist,
        )
        .toList();
  }

  List<PlaylistSummary> get collectedAlbums {
    return playlists.where((playlist) => playlist.isCollectedAlbum).toList();
  }

  PlaylistSummary? findUserPlaylist(PlaylistSummary playlist) {
    for (final item in playlists) {
      if (item.id == playlist.id ||
          (playlist.listId != null && item.listId == playlist.listId) ||
          (item.sourceGlobalId != null && item.sourceGlobalId == playlist.id) ||
          (playlist.sourceGlobalId != null &&
              item.sourceGlobalId == playlist.sourceGlobalId)) {
        return item;
      }
    }
    return null;
  }

  bool isPlaylistInLibrary(PlaylistSummary playlist) {
    return findUserPlaylist(playlist) != null;
  }

  bool canEditPlaylist(PlaylistSummary playlist) {
    if (!isLoggedIn) return false;
    final item = findUserPlaylist(playlist);
    if (item != null) {
      return item.canEditTracks;
    }
    final myUserId = session?.userId;
    if (myUserId != null &&
        myUserId.isNotEmpty &&
        playlist.creatorUserId != null &&
        playlist.creatorUserId!.isNotEmpty &&
        myUserId == playlist.creatorUserId) {
      return playlist.canEditTracks;
    }
    return false;
  }

  Future<void> createPlaylist(String name, {bool private = false}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _run(() async {
      await _api.createPlaylist(trimmed, private: private);
      playlists = await _loadUserPlaylistsWithCache();
    });
  }

  Future<void> collectPlaylist(PlaylistSummary playlist) async {
    await _run(() async {
      await _api.collectPlaylist(
        name: playlist.title,
        globalCollectionId: playlist.id,
      );
      playlists = await _loadUserPlaylistsWithCache();
    });
  }

  Future<void> deleteOrUncollectPlaylist(PlaylistSummary playlist) async {
    final target = findUserPlaylist(playlist) ?? playlist;
    if (target.isLikedPlaylist || target.isSystemDefaultCollect) {
      throw Exception(
        target.isSystemDefaultCollect
            ? '「默认收藏」为系统歌单，无法删除'
            : '「我喜欢」无法删除',
      );
    }
    final listId = _playlistListId(target);
    if (listId == null) {
      throw Exception('无法删除：缺少歌单 listid');
    }
    await _run(() async {
      await _api.deletePlaylist(listId);
      playlists = await _loadUserPlaylistsWithCache();
      await _syncLikedSongs();
    });
  }

  Future<void> addSongToPlaylist(PlaylistSummary playlist, Song song) async {
    await addSongsToPlaylist(playlist, [song]);
  }

  /// 批量添加（一次 API 请求）。
  Future<void> addSongsToPlaylist(
    PlaylistSummary playlist,
    List<Song> songs,
  ) async {
    if (songs.isEmpty) return;
    final listId = _playlistListId(playlist);
    if (listId == null) return;
    await _run(() async {
      final resp = await _api.addSongsToPlaylist(listId, songs);
      playlists = await _loadUserPlaylistsWithCache();
      if (playlist.isLikedPlaylist) {
        // 收藏集合写改入互斥链，避免与并发的全量同步互相覆盖。
        await _enqueueLikedMutation(() async {
          for (final song in songs) {
            if (song.hash.isNotEmpty) {
              _likedHashes.add(song.hash);
            }
          }
          final info = resp?['info'];
          if (info is List) {
            for (var i = 0; i < info.length && i < songs.length; i++) {
              final item = info[i];
              if (item is Map) {
                final fid = item['fileid'];
                final hash = songs[i].hash;
                if (fid is int && hash.isNotEmpty) {
                  _hashToFileId[hash] = fid;
                }
              }
            }
          }
          await _persistLikedHashes();
        });
      }
    });
  }

  Future<void> removeSongFromPlaylist(
    PlaylistSummary playlist,
    Song song,
  ) async {
    await removeSongsFromPlaylist(playlist, [song]);
  }

  /// 批量从歌单删除（一次 API 请求）。
  Future<void> removeSongsFromPlaylist(
    PlaylistSummary playlist,
    List<Song> songs,
  ) async {
    if (songs.isEmpty) return;
    final target = findUserPlaylist(playlist) ?? playlist;
    final listId = _playlistListId(target);
    if (listId == null) return;
    await _run(() async {
      if (target.isLikedPlaylist) {
        final missing = songs.any((s) => _resolvePlaylistFileId(s) == null);
        if (missing) {
          await _syncLikedSongs();
        }
      }
      final fileIds = <int>[];
      for (final song in songs) {
        final fid = _resolvePlaylistFileId(song);
        if (fid != null) fileIds.add(fid);
      }
      if (fileIds.isEmpty) {
        throw Exception('无法定位歌曲在歌单中的 fileid');
      }
      await _api.removeSongsFromPlaylist(
        listId,
        songs,
        fileIds: fileIds,
      );
      playlists = await _loadUserPlaylistsWithCache();
      if (target.isLikedPlaylist) {
        // 收藏集合写改入互斥链，避免与并发的全量同步互相覆盖。
        await _enqueueLikedMutation(() async {
          for (final song in songs) {
            _likedHashes.remove(song.hash);
            _hashToFileId.remove(song.hash);
          }
          await _persistLikedHashes();
        });
      }
    });
  }

  int? _resolvePlaylistFileId(Song song) {
    final mapped = _hashToFileId[song.hash];
    if (mapped != null && mapped != 0) {
      return mapped;
    }
    // 歌单曲目 Song.fromPlaylist 的 id 即为 fileid
    final fromId = int.tryParse(song.id);
    if (fromId != null && fromId != 0) {
      return fromId;
    }
    return null;
  }

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedUserId = prefs.getString(_userIdKey);
      final restored = LoginSession(
        userId: storedUserId,
        token: prefs.getString(_tokenKey),
        t1: prefs.getString(_t1Key),
        sessionId: prefs.getString(_sessionIdKey),
      );

      if (!restored.isValid) {
        return;
      }

      session = restored;
      _api.setSession(restored);

      try {
        final refreshed = await _api.refreshToken();
        if (storedUserId != null &&
            refreshed.userId != null &&
            storedUserId != refreshed.userId) {
          await _clearSession();
          return;
        }
        session = refreshed;
        _api.setSession(refreshed);
        await prefs.setString(_tokenKey, refreshed.token ?? '');
        await prefs.setString(_t1Key, refreshed.t1 ?? '');
        await prefs.setString(_userIdKey, refreshed.userId ?? '');
      } catch (_) {
        // /login/token failed, continue with stored token
      }

      playlists = await _loadCachedPlaylists();
      await _loadLikedHashes();
      // 先读缓存的用户信息，静默刷新由 refreshProfile 完成
      final cachedProfile = await _cacheService.read<UserProfile>(
        _userCacheKey,
        decode: UserProfile.fromCache,
        ttl: AppConfig.userProfileTtl,
      );
      if (cachedProfile != null) {
        profile = cachedProfile.data;
      }
      // 缓存数据已就绪，立即通知 UI 显示，API 刷新在后台进行
      isRestoring = false;
      notifyListeners();
      await refreshProfile(silent: true);
      _vipBackgroundTask.schedule(session);
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isRestoring = false;
      notifyListeners();
    }
  }

  /// 删除/增删歌曲必须用数字 listid，不能用 global_collection_id。
  String? _playlistListId(PlaylistSummary playlist) {
    final raw = playlist.listId?.trim();
    if (raw != null && raw.isNotEmpty && int.tryParse(raw) != null) {
      return raw;
    }
    // 自建歌单 list_create_listid 通常等于 listid
    final source = playlist.sourceListId?.trim();
    if (source != null && source.isNotEmpty && int.tryParse(source) != null) {
      return source;
    }
    // collection_3_{userid}_{listid}_0
    final id = playlist.id;
    final m = RegExp(r'collection_\d+_\d+_(\d+)_\d+').firstMatch(id);
    if (m != null) {
      return m.group(1);
    }
    return null;
  }

  Future<void> refreshSession() async {
    if (session == null) return;
    final prefs = await SharedPreferences.getInstance();
    final storedUserId = prefs.getString(_userIdKey);
    try {
      final refreshed = await _api.refreshToken();
      if (storedUserId != null &&
          refreshed.userId != null &&
          storedUserId != refreshed.userId) {
        await _clearSession();
        return;
      }
      session = refreshed;
      _api.setSession(refreshed);
      await prefs.setString(_tokenKey, refreshed.token ?? '');
      await prefs.setString(_t1Key, refreshed.t1 ?? '');
      await prefs.setString(_userIdKey, refreshed.userId ?? '');
    } catch (_) {
      // Refresh failed, continue with existing session
    }
  }

  Future<void> sendCode(String mobile) async {
    await _run(() => _api.sendLoginCode(mobile));
  }

  Future<void> loginWithSession(LoginSession session) async {
    await _run(() async {
      this.session = session;
      _api.setSession(session);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, session.token ?? '');
      await prefs.setString(_t1Key, session.t1 ?? '');
      // session.sessionId 可能为 null（扫码登录），但 ApiClient 内部
      // 已从登录响应 header 保存了后端的 session key，这里也持久化一份。
      await prefs.setString(_sessionIdKey, _api.clientSessionId ?? '');
      await prefs.setString(_userIdKey, session.userId ?? '');

      // 扫码登录返回的 QrLoginStatusResponse 只有 token，缺少 t1。
      // 后续 /user/detail 等接口需要 t1 header 鉴权，否则会失败导致
      // profile/歌单拉取不到。这里先调 /login/token 刷新拿到 t1。
      if (session.t1 == null || session.t1!.isEmpty) {
        try {
          final refreshed = await _api.refreshToken();
          if (refreshed.token != null && refreshed.token!.isNotEmpty) {
            // 合并：保留扫码返回的 nickname/avatar，用刷新结果的 token/t1
            session = LoginSession(
              userId: refreshed.userId ?? session.userId,
              token: refreshed.token,
              t1: refreshed.t1,
              sessionId: _api.clientSessionId,
              nickname: session.nickname,
              avatarUrl: session.avatarUrl,
            );
            this.session = session;
            _api.setSession(session);
            await prefs.setString(_tokenKey, session.token ?? '');
            await prefs.setString(_t1Key, session.t1 ?? '');
            await prefs.setString(_sessionIdKey, _api.clientSessionId ?? '');
            await prefs.setString(_userIdKey, session.userId ?? '');
          }
        } catch (_) {
          // 刷新失败，继续用原 token
        }
      }

      // 用 session 数据构造临时 profile，UI 立即展示用户信息；
      // refreshProfile 成功后会覆盖为完整数据。
      if (session.nickname != null && session.nickname!.isNotEmpty) {
        profile = UserProfile(
          nickname: session.nickname!,
          avatarUrl: session.avatarUrl,
        );
      }

      await refreshProfile(silent: true);
      _vipBackgroundTask.schedule(session);
    });
  }

  Future<PhoneLoginResult?> login(
    String mobile,
    String code, {
    String? userId,
  }) async {
    PhoneLoginResult? result;
    await _run(() async {
      _api.setSession(null);
      result = await _api.loginWithPhone(
        mobile: mobile,
        code: code,
        userId: userId,
      );
      if (result?.requiresUserSelection == true) {
        return;
      }
      final nextSession = result!.session!;
      session = nextSession;
      _api.setSession(nextSession);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, nextSession.token ?? '');
      await prefs.setString(_t1Key, nextSession.t1 ?? '');
      // nextSession.sessionId 可能为 null，用 ApiClient 实际持有的 session key
      await prefs.setString(_sessionIdKey, _api.clientSessionId ?? '');
      await prefs.setString(_userIdKey, nextSession.userId ?? '');

      await refreshProfile(silent: true);
      _vipBackgroundTask.schedule(session);
    });
    return result;
  }

  Future<void> refreshProfile({bool silent = false}) async {
    await _run(() async {
      profile = await _api.userDetail();
      if (profile != null) {
        // 缓存写失败（磁盘满/平台异常）不应把成功的接口结果变成登录
        // 错误：吞掉即可，下次刷新重写。
        try {
          await _cacheService.write(_userCacheKey, profile!.toCache());
        } catch (_) {}
      }
      try {
        vipInfo = await _api.userVipDetail();
      } catch (_) {
        vipInfo = null;
      }
      playlists = await _loadUserPlaylistsWithCache();
      await _syncLikedSongs();
    }, silent: silent);
  }

  Future<void> logout() async {
    await _run(() async {
      try {
        await _api.logout();
      } finally {
        final prefs = await SharedPreferences.getInstance();
        final cacheKey = _playlistCacheKey;
        final emptyCountKey = _playlistEmptyCountKey;
        session = null;
        profile = null;
        vipInfo = null;
        playlists = const [];
        _likedHashes.clear();
        _hashToFileId.clear();
        _api.setSession(null);
        await prefs.remove(_tokenKey);
        await prefs.remove(_t1Key);
        await prefs.remove(_sessionIdKey);
        await prefs.remove(_userIdKey);
        await prefs.remove(cacheKey);
        await prefs.remove(emptyCountKey);
        await prefs.remove(_likedHashesKey);
        await prefs.remove(_likedFileIdsKey);
        await _clearSession();
      }
    });
  }

  void _updateLikedCountFromResponse(Map<String, dynamic>? resp) {
    if (resp == null) return;
    final count = resp['count'];
    if (count is! int) return;
    final index = playlists.indexWhere((p) => p.isLikedPlaylist);
    if (index < 0) return;
    playlists[index] = playlists[index].copyWith(songCount: count);
  }

  /// Rust 传输层业务失败不抛错（见 transport.rs：失败只 warn 并回传
  /// 原始 status/error_code 信封），Dart 必须显式校验，否则会出现
  /// “本地已翻转、服务端没写，重启同步后打回原形”的假成功。
  void _ensurePlaylistMutationSuccess(
    Map<String, dynamic>? resp,
    String action,
  ) {
    if (resp == null) return;
    final status = resp['status'];
    final errorCode = resp['error_code'] ?? resp['errcode'];
    final okStatus = status == null || status == 1 || status == 200;
    final okCode = errorCode == null || errorCode == 0;
    if (okStatus && okCode) return;
    final msg = resp['error'] ?? resp['err'] ?? resp['msg'] ?? resp['message'];
    final detail = msg is String && msg.trim().isNotEmpty
        ? '：$msg'
        : errorCode != null
        ? '（错误码 $errorCode）'
        : '';
    throw ApiException('$action失败$detail');
  }

  /// 全量同步入队入口（外部调用走互斥链）。
  Future<void> _syncLikedSongs() {
    return _enqueueLikedMutation(_syncLikedSongsLocked);
  }

  /// 全量同步执行体：只在已持有 [_likedMutationLock] 时调用
  /// （toggleLike 任务体内与 [_syncLikedSongs] 入队后各一处）。
  ///
  /// 返回是否成功应用了服务端真值：失败时内部回退到本地持久化集合并
  /// 返回 false，调用方（toggleLike 的取消收藏分支）据此区分"服务端确无
  /// 此歌"与"同步失败无法定真值"两种 fileId 缺失场景。
  Future<bool> _syncLikedSongsLocked() async {
    try {
      final playlist = likedPlaylist;
      if (playlist == null) return false;
      final songs = await _api.playlistSongs(playlist.id, fetchAll: true);
      _likedHashes.clear();
      _hashToFileId.clear();
      for (final song in songs) {
        _likedHashes.add(song.hash);
        final fid = int.tryParse(song.id);
        if (fid != null) _hashToFileId[song.hash] = fid;
      }
      await _persistLikedHashes();
      return true;
    } catch (_) {
      try {
        await _loadLikedHashes();
      } catch (_) {}
      return false;
    }
  }

  Future<void> _persistLikedHashes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_likedHashesKey, jsonEncode(_likedHashes.toList()));
    // fileId 映射同样落盘：否则重启后 _hashToFileId 为空，取消收藏时
    // 回退用 song.id（MixSongID，非 fileid）删服务端会静默失败，
    // 本地乐观移除在下次同步时被打回——“取消红心不生效”。
    try {
      await prefs.setString(
        _likedFileIdsKey,
        jsonEncode(_hashToFileId.map((k, v) => MapEntry(k, v))),
      );
    } catch (_) {}
  }

  Future<void> _loadLikedHashes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_likedHashesKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          _likedHashes.addAll(list.whereType<String>());
        }
      } catch (_) {}
    }
    // 兼容老版本：没有 fileId 映射时保持空，toggleLike 会按需全量同步补齐。
    final rawIds = prefs.getString(_likedFileIdsKey);
    if (rawIds != null && rawIds.isNotEmpty) {
      try {
        final map = jsonDecode(rawIds);
        if (map is Map) {
          map.forEach((key, value) {
            if (key is! String || key.isEmpty) return;
            if (value is int && value != 0) {
              _hashToFileId[key] = value;
            } else if (value is String) {
              final parsed = int.tryParse(value);
              if (parsed != null && parsed != 0) _hashToFileId[key] = parsed;
            }
          });
        }
      } catch (_) {}
    }
  }

  Future<List<PlaylistSummary>> _loadUserPlaylistsWithCache() async {
    final prefs = await SharedPreferences.getInstance();
    final fetched = await _api.userPlaylists(pageSize: 100);

    if (fetched.isNotEmpty) {
      await prefs.setInt(_playlistEmptyCountKey, 0);
      await _saveCachedPlaylists(fetched);
      return fetched;
    }

    final emptyCount = (prefs.getInt(_playlistEmptyCountKey) ?? 0) + 1;
    await prefs.setInt(_playlistEmptyCountKey, emptyCount);

    final cached = await _loadCachedPlaylists();
    if (cached.isNotEmpty && emptyCount < 2) {
      return cached;
    }

    // 清理旧 key 与 CacheService 索引
    await prefs.remove(_playlistCacheKey);
    await _cacheService.remove(_playlistCacheKeyV2);
    return const [];
  }

  Future<List<PlaylistSummary>> _loadCachedPlaylists() async {
    // 优先读 CacheService（统一管理），回退旧 key（兼容旧版本）
    final cached = await _cacheService.read<List<PlaylistSummary>>(
      _playlistCacheKeyV2,
      decode: (json) => (json['playlists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlaylistSummary.fromCache)
          .where((playlist) => playlist.id.isNotEmpty)
          .toList(),
      ttl: AppConfig.userProfileTtl,
    );
    if (cached != null) {
      return cached.data;
    }
    // 回退旧 key
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playlistCacheKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      final json = jsonDecode(raw);
      if (json is! List) {
        return const [];
      }
      return json
          .whereType<Map>()
          .map((item) => PlaylistSummary.fromCache(asMap(item)))
          .where((playlist) => playlist.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveCachedPlaylists(List<PlaylistSummary> playlists) async {
    // 双写：CacheService（统一管理）+ 旧 key（兼容）
    await _cacheService.write(_playlistCacheKeyV2, {
      'playlists': playlists.map((p) => p.toCache()).toList(),
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _playlistCacheKey,
      jsonEncode(playlists.map((playlist) => playlist.toCache()).toList()),
    );
  }

  String get _playlistCacheKey {
    return '${_playlistCachePrefix}_${session?.userId ?? 'default'}';
  }

  String get _playlistEmptyCountKey {
    return '${_playlistEmptyCountPrefix}_${session?.userId ?? 'default'}';
  }

  String get _userCacheKey => 'cache_user_${session?.userId ?? 'default'}';

  String get _playlistCacheKeyV2 =>
      'cache_user_playlists_${session?.userId ?? 'default'}';

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    session = null;
    profile = null;
    playlists = const [];
    _likedHashes.clear();
    _hashToFileId.clear();
    _api.setSession(null);
    await prefs.remove(_tokenKey);
    await prefs.remove(_t1Key);
    await prefs.remove(_sessionIdKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_playlistCacheKey);
    await prefs.remove(_playlistEmptyCountKey);
    await prefs.remove(_likedHashesKey);
    await prefs.remove(_likedFileIdsKey);
    await _cacheService.clearUserCache(null);
    notifyListeners();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool silent = false,
  }) async {
    if (!silent) {
      isLoading = true;
      errorMessage = null;
      notifyListeners();
    }

    try {
      await action();
      errorMessage = null;
    } catch (error) {
      errorMessage = _errorText(error);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  String _errorText(Object error) {
    if (error is ApiException) {
      return error.message;
    }
    return error.toString();
  }

  @override
  void dispose() {
    _networkRestoredSub?.cancel();
    // 摘除 VIP 后台任务的成功回调：VipBackgroundTask 由 PlayerController
    // 长期持有，不摘除的话本控制器销毁后领取成功仍会调 refreshProfile →
    // notifyListeners（对已 dispose 的 ChangeNotifier）。
    _vipBackgroundTask.onClaimSuccess = null;
    super.dispose();
  }
}
