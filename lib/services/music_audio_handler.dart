import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../config/app_config.dart';
import '../models/music_models.dart';

const _kgUserAgent = AppConfig.kugouUserAgent;

/// 网易云域名（页 API/外链 CDN）统一在此判断：163 页面系（music.163.com）
/// 与音频 CDN 系（*.music.126.net）都要求 Referer，缺失时部分节点 403。
bool _isNeteaseHost(Uri uri) {
  final host = uri.host.toLowerCase();
  return host == '163.com' ||
      host.endsWith('.163.com') ||
      host == '126.net' ||
      host.endsWith('.126.net');
}

/// 单次 load 的代理路由：远端 URL 或本地文件二选一。
///
/// 按 seq（`/play/<seq>`）路由而非共享单槽：两次 loadSong 重叠（快速切歌、
/// 后端对同一 URL 的延迟 Range 补请求）时，单槽在"请求到达时刻"取值会
/// 让旧 load 的请求吃到新歌字节（时长/元数据与实际音频不一致，甚至
/// 标题 A 播出 B 的声音）。按 seq 隔离后每个请求拿到的是它自己的目标。
class _ProxyRoute {
  _ProxyRoute({this.url, this.localPath})
      : assert((url != null) != (localPath != null), 'url 与 localPath 二选一');

  final String? url;
  final String? localPath;
}

/// 车机与手机通知渠道解析（车机使用专属静默渠道防弹窗，手机使用标准媒体渠道支持灵动岛与锁屏控制）。
///
/// 渠道 ID 与原生 MusicApplication.setupNotificationChannels 创建的渠道一一对应，
/// 改动需双端同步。渠道在启动时随 AudioServiceConfig 定向，运行时切换车机模式
/// 不会生效，需重启进程。
({String channelId, String channelName}) resolvePlaybackNotificationChannel({
  required bool isCarMode,
  required bool isAutomotiveDevice,
}) {
  final isCar = isCarMode || isAutomotiveDevice;
  return (
    channelId:
        isCar ? 'kgka_music_hl.playback_car' : 'kgka_music_hl.playback_phone',
    channelName: isCar ? '时音 车机播放控制' : '时音 播放控制',
  );
}

class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  MusicAudioHandler() {
    audioPlayer.playbackEventStream
        .map(_playbackStateForEvent)
        .pipe(playbackState);
  }

  final AudioPlayer audioPlayer = AudioPlayer();

  Future<void> Function()? _onNext;
  Future<void> Function()? _onPrevious;
  int _queueIndex = 0;

  HttpServer? _proxy;
  final Map<int, _ProxyRoute> _proxyRoutes = {};
  int _loadSeq = 0;

  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
  }

  void detachTransportControls() {
    _onNext = null;
    _onPrevious = null;
  }

  /// 系统媒体会话队列上限（超长歌单只推送窗口，降低 MediaItem 堆积）。
  static const _maxSystemQueueSize = 80;

  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    final currentItem = _mediaItemFor(song, includeArt: true);
    final items = _buildSystemQueue(queueSongs, _queueIndex);

    if (items.isNotEmpty) {
      queue.add(items);
    }
    mediaItem.add(currentItem);

    // 本地文件与远端 URL 统一经代理（Range/UA 处理一致），
    // 路由按 seq 注册见 [_loadViaProxy]。
    await _loadViaProxy(url);
  }

  Future<void> _ensureProxy() async {
    if (_proxy != null) return;
    _proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _proxy!.listen(_onProxyRequest, onError: (Object e) {
      debugPrint('[AudioHandler] proxy error: $e');
    });
  }

  void _onProxyRequest(HttpRequest req) async {
    // 按 URL 里的 seq 取本请求自己的路由；过期请求（旧 load 的迟到
    // Range 补发）直接 410，让后端重新走当前源。
    final seq = int.tryParse(req.uri.path.split('/').last);
    final route = seq == null ? null : _proxyRoutes[seq];
    if (route == null) {
      req.response.statusCode = HttpStatus.gone;
      await req.response.close();
      return;
    }
    final localFile = route.localPath;
    if (localFile != null) {
      await _serveLocalFile(req, localFile);
      return;
    }
    final target = route.url;
    if (target == null) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await req.response.close();
      return;
    }
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final targetUri = Uri.parse(target);
      final upstream = await client.openUrl(req.method, targetUri);
      upstream.headers.set(HttpHeaders.userAgentHeader, _kgUserAgent);
      // 网易云外链（music.163.com / *.music.126.net）校验 Referer：
      // 只带 UA 不带 Referer 时部分 CDN 节点直接 403。酷狗 CDN 不吃
      // Referer，保持原样不动。
      if (_isNeteaseHost(targetUri)) {
        upstream.headers.set(HttpHeaders.refererHeader, 'https://music.163.com/');
      }
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        upstream.headers.set(HttpHeaders.rangeHeader, range);
      }
      final resp = await upstream.close();

      req.response.statusCode = resp.statusCode;
      String? upstreamContentType;
      resp.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower == HttpHeaders.contentTypeHeader ||
            lower == HttpHeaders.transferEncodingHeader) {
          // content-type 单独记录：上游有则透传（flac 等直链会带正确
          // 类型），没有再兜底 audio/mpeg——写死 mpeg 会把 flac 误标，
          // 遇到按 Content-Type 选解码器的路径会解码失败。
          if (lower == HttpHeaders.contentTypeHeader && values.isNotEmpty) {
            upstreamContentType = values.first;
          }
          return;
        }
        req.response.headers.set(name, values);
      });
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        upstreamContentType ?? 'audio/mpeg',
      );
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      await resp.pipe(req.response);
      client.close();
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 本地文件路径推断音频 Content-Type（默认 audio/mpeg）。
  @visibleForTesting
  static String contentTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) return 'audio/mp4';
    if (lower.endsWith('.aac')) return 'audio/aac';
    return 'audio/mpeg';
  }

  Future<void> _serveLocalFile(HttpRequest req, String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final fileSize = file.lengthSync();
      final range = req.headers.value(HttpHeaders.rangeHeader);
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        contentTypeForPath(path),
      );

      if (range != null && range.startsWith('bytes=')) {
        final parts = range.substring(6).split('-');
        final start = int.tryParse(parts[0]) ?? 0;
        // 起点越界（文件比后端以为的短，如缓存被清理）必须 416：
        // end<start 会让 contentLength 为负，直接抛异常挂在请求上。
        if (start >= fileSize) {
          req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$fileSize',
          );
          await req.response.close();
          return;
        }
        final end = parts.length > 1 && parts[1].isNotEmpty
            ? int.tryParse(parts[1]) ?? fileSize - 1
            : fileSize - 1;
        final length = end - start + 1;
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/$fileSize');
        req.response.headers.contentLength = length;
        final stream = file.openRead(start, end + 1);
        await stream.pipe(req.response);
      } else {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentLength = fileSize;
        final stream = file.openRead();
        await stream.pipe(req.response);
      }
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _loadViaProxy(String url) async {
    await _ensureProxy();
    final seq = ++_loadSeq;
    _proxyRoutes[seq] = url.startsWith('http://') || url.startsWith('https://')
        ? _ProxyRoute(url: url)
        : _ProxyRoute(localPath: url);
    // 只保留最近几个路由：后端换源后的旧请求应尽快失效，
    // 同时给在途的延迟 Range 补发留足窗口。
    while (_proxyRoutes.length > 3) {
      _proxyRoutes.remove(_proxyRoutes.keys.first);
    }
    final proxyUrl = 'http://127.0.0.1:${_proxy!.port}/play/$seq';
    try {
      await _enqueueEngineLoad(seq, proxyUrl);
    } on PlayerException catch (e) {
      throw Exception('播放失败: ${e.message}');
    }
  }

  // ---- 引擎加载串行门 ----------------------------------------------------
  //
  // just_audio_windows 的 WinRT MediaPlayer 在高频 setUrl（快速连点切歌）
  // 时，native 回调线程与 COM 平台线程竞态，会触发 "Lost connection to
  // device" 进程崩溃——与 completed→自动下一首的 100ms workaround
  // （player_controller._handleCompleted）同根源的上游后端缺陷。
  // 门规则：
  // 1. 串行：同一时刻至多一个 setUrl 在 native 侧执行（异步链排队）；
  // 2. 最小间隔：Windows 上两次 setUrl 发起至少间隔 [_minEngineLoadGap]，
  //    覆盖上一次加载/中止后 native 回调的尾部清理窗口；
  // 3. 只加载最新：排队期间出现更新的 load 注册时，旧 load 直接跳过
  //    （不碰引擎），上层 playSong 的 hash 守卫会把对应的旧流程收尾。
  // 连点 N 次的净效果：队列里的旧任务瞬间跳过，只有最后一次真正进引擎。

  /// Windows 两次引擎加载的最小间隔。与 completed workaround 的 100ms
  /// 同量级、稍保守：连点场景每次加载的 native 开销远大于 250ms 的
  /// 用户感知阈值，取安全值。
  static const _minEngineLoadGap = Duration(milliseconds: 250);

  /// 引擎加载串行链的尾端（Promise 链式排队）。
  Future<void> _engineLoadChain = Future<void>.value();

  /// 上一次 setUrl 发起时刻（仅 Windows 记录）。
  DateTime? _lastEngineLoadAt;

  Future<void> _enqueueEngineLoad(int seq, String proxyUrl) {
    final task = _engineLoadChain
        .then((_) => _performEngineLoad(seq, proxyUrl));
    // 推进链尾但不吞掉调用方的异常：失败的任务本身仍会把错误抛给
    // 等待它的 _loadViaProxy，链上后续任务不受影响。
    _engineLoadChain = task.then(
      (_) {},
      onError: (_) {},
    );
    return task;
  }

  Future<void> _performEngineLoad(int seq, String proxyUrl) async {
    if (seq != _loadSeq) return; // 已被更新的加载取代，跳过
    if (Platform.isWindows) {
      final last = _lastEngineLoadAt;
      if (last != null) {
        final elapsed = DateTime.now().difference(last);
        if (elapsed < _minEngineLoadGap) {
          await Future<void>.delayed(_minEngineLoadGap - elapsed);
          if (seq != _loadSeq) return; // 等待期间又被更新取代
        }
      }
      _lastEngineLoadAt = DateTime.now();
    }
    await audioPlayer.setUrl(proxyUrl).timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        throw Exception('音频加载超时，请检查网络后重试');
      },
    );
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    this.queue.add(queue);
  }

  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    queue.add(_buildSystemQueue(queueSongs, _queueIndex));
    if (currentSong != null) {
      mediaItem.add(_mediaItemFor(currentSong, includeArt: true));
    }
  }

  @override
  Future<void> play() async {
    await audioPlayer.play();
  }

  @override
  Future<void> pause() async {
    await audioPlayer.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await audioPlayer.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    await _onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onPrevious?.call();
  }

  @override
  Future<void> stop() async {
    await audioPlayer.stop();
  }

  Future<void> close() async {
    await _proxy?.close(force: true);
    _proxy = null;
    await audioPlayer.dispose();
  }

  /// 构建推给系统媒体会话的队列：当前曲含封面，其余精简；超长队列只保留窗口。
  List<MediaItem> _buildSystemQueue(List<Song> songs, int focusIndex) {
    if (songs.isEmpty) {
      return const [];
    }
    final safeFocus = focusIndex.clamp(0, songs.length - 1);
    if (songs.length <= _maxSystemQueueSize) {
      return [
        for (var i = 0; i < songs.length; i++)
          _mediaItemFor(songs[i], includeArt: i == safeFocus),
      ];
    }

    final half = _maxSystemQueueSize ~/ 2;
    var start = safeFocus - half;
    var end = start + _maxSystemQueueSize;
    if (start < 0) {
      start = 0;
      end = _maxSystemQueueSize;
    } else if (end > songs.length) {
      end = songs.length;
      start = end - _maxSystemQueueSize;
    }
    _queueIndex = safeFocus - start;
    return [
      for (var i = start; i < end; i++)
        _mediaItemFor(songs[i], includeArt: i == safeFocus),
    ];
  }

  MediaItem _mediaItemFor(Song song, {bool includeArt = false}) {
    return MediaItem(
      id: song.hash.isEmpty ? song.id : song.hash,
      album: song.albumName,
      title: song.title,
      artist: song.artist,
      duration: song.duration,
      artUri: includeArt && song.coverUrl != null
          ? Uri.tryParse(song.coverUrl!)
          : null,
      extras: {'hash': song.hash, 'songId': song.id},
    );
  }

  PlaybackState _playbackStateForEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (audioPlayer.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekBackward,
        MediaAction.seekForward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[audioPlayer.processingState]!,
      playing: audioPlayer.playing,
      updatePosition: audioPlayer.position,
      bufferedPosition: audioPlayer.bufferedPosition,
      speed: audioPlayer.speed,
      queueIndex: _queueIndex,
    );
  }
}
