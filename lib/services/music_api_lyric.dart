part of 'music_api.dart';

/// 歌词获取。
mixin _MusicApiLyric on _MusicApiBase {
  Future<List<LyricLine>> lyrics(Song song) async {
    _debugLyricLog(
      'request song="${song.title}" artist="${song.artist}" hash="${song.hash}" albumAudioId="${song.albumAudioId}"',
    );
    final candidate = await _searchLyricCandidate(song);
    _debugLyricLogObject('selected candidate', candidate);
    if (candidate == null) {
      _debugLyricLog('no lyric candidate found');
      return const [];
    }

    final krcLyrics = await _lyricByFormat(candidate, 'krc');
    if (krcLyrics.isNotEmpty) {
      return krcLyrics;
    }

    return _lyricByFormat(candidate, 'lrc');
  }

  Future<Map<String, dynamic>?> _searchLyricCandidate(Song song) async {
    final query = {'hash': song.hash};
    _debugLyricLogObject('search query', query);
    final searchJson = await _client.get('/search/lyric', query);
    _debugLyricLogObject('search response', searchJson);

    final candidate = _findLyricCandidate(searchJson);
    if (candidate != null) {
      _debugLyricLog('search found candidate by hash');
      return candidate;
    }
    return null;
  }

  Future<List<LyricLine>> _lyricByFormat(
    Map<String, dynamic> candidate,
    String format,
  ) async {
    final id =
        asString(candidate['id']) ??
        asString(candidate['lyrics_id']) ??
        asString(candidate['lyric_id']) ??
        asString(candidate['lyricid']);
    final accessKey =
        asString(candidate['accesskey']) ??
        asString(candidate['access_key']) ??
        asString(candidate['accessKey']);
    if (id == null || accessKey == null) {
      return const [];
    }

    final result = asMap(
      await _client.get('/lyric', {
        'id': id,
        'accesskey': accessKey,
        'fmt': format,
        'decode': true,
      }),
    );
    _debugLyricLogObject('$format lyric response keys', result.keys.toList());

    final candidates = [
      asString(result['decodedContent']),
      asString(result['rawContent']),
      asString(result['content']),
    ].whereType<String>().toList();
    _debugLyricLog('$format content candidate count=${candidates.length}');

    candidates.sort(
      (a, b) => _lyricContentScore(b).compareTo(_lyricContentScore(a)),
    );
    for (var index = 0; index < candidates.length; index++) {
      final content = candidates[index];
      _debugLyricContent(
        '$format content[$index] score=${_lyricContentScore(content)} length=${content.length}',
        content,
      );
      final lines = parseLyrics(content);
      _debugLyricLog('$format content[$index] parsed lines=${lines.length}');
      if (lines.isNotEmpty) {
        return lines;
      }
    }
    _debugLyricLog('$format lyric parsed no lines');
    return const [];
  }

  Map<String, dynamic>? _findLyricCandidate(Object? value) {
    final root = asMap(value);
    final direct = _asLyricCandidate(root);
    if (direct != null) {
      return direct;
    }

    final candidates = [
      root['candidates'],
      root['candidate'],
      root['list'],
      root['lyrics'],
      root['items'],
      root['info'],
      root['data'],
    ];

    for (final candidate in candidates) {
      if (candidate is List && candidate.isNotEmpty) {
        for (final item in candidate) {
          final found = _findLyricCandidate(item);
          if (found != null) {
            return found;
          }
        }
      }
      if (candidate is Map) {
        final found = _findLyricCandidate(candidate);
        if (found != null) {
          return found;
        }
      }
    }

    return null;
  }

  Map<String, dynamic>? _asLyricCandidate(Map<String, dynamic> value) {
    final hasId =
        asString(value['id']) != null ||
        asString(value['lyrics_id']) != null ||
        asString(value['lyric_id']) != null ||
        asString(value['lyricid']) != null;
    final hasAccessKey =
        asString(value['accesskey']) != null ||
        asString(value['access_key']) != null ||
        asString(value['accessKey']) != null;
    return hasId && hasAccessKey ? value : null;
  }
}
