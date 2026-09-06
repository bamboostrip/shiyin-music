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

  static const _tokenKey = 'ka_music_token';
  static const _t1Key = 'ka_music_t1';
  static const _sessionIdKey = 'ka_music_session_id';
  static const _userIdKey = 'ka_music_user_id';
  static const _playlistCachePrefix = 'ka_music_cached_playlists';
  static const _playlistEmptyCountPrefix = 'ka_music_playlist_empty_count';
  static const _likedHashesKey = 'ka_music_liked_hashes';
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

  bool get isLoggedIn => session?.isValid == true;

  bool isLiked(Song song) => _likedHashes.contains(song.hash);

  int get likedCount {
    final playlist = likedPlaylist;
    if (playlist != null && playlist.songCount != null) {
      return playlist.songCount!;
    }
    return _likedHashes.length;
  }

  Future<void> toggleLike(Song song) async {
    final playlist = likedPlaylist;
    if (playlist == null) return;

    final liked = _likedHashes.contains(song.hash);
    final targetListId = playlist.listId?.isNotEmpty == true
        ? playlist.listId!
        : playlist.id;
    try {
      Map<String, dynamic>? resp;
      if (liked) {
        var fileId = _resolvePlaylistFileId(song);
        if (fileId == null) {
          await _syncLikedSongs();
          fileId = _hashToFileId[song.hash];
        }
        if (fileId == null) return;
        resp = await _api.removeSongsFromPlaylist(
          targetListId,
          [song],
          fileIds: [fileId],
        );
        _likedHashes.remove(song.hash);
        _hashToFileId.remove(song.hash);
      } else {
        resp = await _api.addToPlaylist(targetListId, song);
        _likedHashes.add(song.hash);
        if (resp != null) {
          final info = resp['info'];
          if (info is List && info.isNotEmpty) {
            final fid = info[0]['fileid'];
            if (fid is int) _hashToFileId[song.hash] = fid;
          }
        }
      }
      _updateLikedCountFromResponse(resp);
      await _persistLikedHashes();
      notifyListeners();
    } catch (error) {
      if (liked) {
        _likedHashes.add(song.hash);
      } else {
        _likedHashes.remove(song.hash);
        _hashToFileId.remove(song.hash);
      }
      rethrow;
    }
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
        for (final song in songs) {
          _likedHashes.remove(song.hash);
          _hashToFileId.remove(song.hash);
        }
        await _persistLikedHashes();
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
        await _cacheService.write(_userCacheKey, profile!.toCache());
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
        _api.setSession(null);
        await prefs.remove(_tokenKey);
        await prefs.remove(_t1Key);
        await prefs.remove(_sessionIdKey);
        await prefs.remove(_userIdKey);
        await prefs.remove(cacheKey);
        await prefs.remove(emptyCountKey);
        await prefs.remove(_likedHashesKey);
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

  Future<void> _syncLikedSongs() async {
    final playlist = likedPlaylist;
    if (playlist == null) return;

    try {
      final songs = await _api.playlistSongs(playlist.id, fetchAll: true);
      _likedHashes.clear();
      _hashToFileId.clear();
      for (final song in songs) {
        _likedHashes.add(song.hash);
        final fid = int.tryParse(song.id);
        if (fid != null) _hashToFileId[song.hash] = fid;
      }
      await _persistLikedHashes();
    } catch (_) {
      await _loadLikedHashes();
    }
  }

  Future<void> _persistLikedHashes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_likedHashesKey, jsonEncode(_likedHashes.toList()));
  }

  Future<void> _loadLikedHashes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_likedHashesKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        _likedHashes.addAll(list.whereType<String>());
      }
    } catch (_) {}
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
    _api.setSession(null);
    await prefs.remove(_tokenKey);
    await prefs.remove(_t1Key);
    await prefs.remove(_userIdKey);
    await prefs.remove(_playlistCacheKey);
    await prefs.remove(_playlistEmptyCountKey);
    await prefs.remove(_likedHashesKey);
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
    super.dispose();
  }
}
