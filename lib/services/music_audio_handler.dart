import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/music_models.dart';

const _kgUserAgent = 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

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
  String? _proxyTarget;
  String? _proxyLocalFile;
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

    if (url.startsWith('http://') || url.startsWith('https://')) {
      _proxyLocalFile = null;
      await _loadViaProxy(url);
    } else {
      _proxyLocalFile = url;
      await _loadViaProxy(url);
    }
  }

  Future<void> _ensureProxy() async {
    if (_proxy != null) return;
    _proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _proxy!.listen(_onProxyRequest, onError: (Object e) {
      debugPrint('[AudioHandler] proxy error: $e');
    });
  }

  void _onProxyRequest(HttpRequest req) async {
    final localFile = _proxyLocalFile;
    if (localFile != null) {
      await _serveLocalFile(req, localFile);
      return;
    }
    final target = _proxyTarget;
    if (target == null) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await req.response.close();
      return;
    }
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final upstream = await client.openUrl(req.method, Uri.parse(target));
      upstream.headers.set(HttpHeaders.userAgentHeader, _kgUserAgent);
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        upstream.headers.set(HttpHeaders.rangeHeader, range);
      }
      final resp = await upstream.close();

      req.response.statusCode = resp.statusCode;
      resp.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower == HttpHeaders.contentTypeHeader ||
            lower == HttpHeaders.transferEncodingHeader) {
          return;
        }
        req.response.headers.set(name, values);
      });
      req.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/mpeg');
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
      req.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/mpeg');

      if (range != null && range.startsWith('bytes=')) {
        final parts = range.substring(6).split('-');
        final start = int.tryParse(parts[0]) ?? 0;
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
    _proxyTarget = url;
    final seq = ++_loadSeq;
    final proxyUrl = 'http://127.0.0.1:${_proxy!.port}/play/$seq';
    try {
      await audioPlayer.setUrl(proxyUrl).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw Exception('音频加载超时，请检查网络后重试');
        },
      );
    } on PlayerException catch (e) {
      throw Exception('播放失败: ${e.message}');
    }
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
