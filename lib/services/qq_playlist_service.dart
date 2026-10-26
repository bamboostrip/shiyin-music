import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/music_models.dart';

/// 读取 QQ 音乐公开歌单元数据（歌名/歌手/时长），不携带酷狗登录态。
///
/// 移植自上游 kgka_Music_hl 3.2.0（`dc92cfd`，兼容性修复见 `c60a92f`）。
///
/// 为什么允许 Dart 直连：QQ 音乐公开歌单接口无需登录、也不属于酷狗接口，
/// 不破坏「酷狗请求必须走 Rust engine」的约束（见任务书 0.4 第 2 条）。
/// 酷狗接口仍只能经 `ApiClientInterface` → `rust/src/engine.rs`。
///
/// 复杂度主要在三处：
/// 1. 分享文本里的链接形态很多（短链 `c6.y.qq.com/...?__=`、`playlist/123`、
///    `taoge.html?id=`、`disstid=` 等），先 [`shareUri`] 白名单提取，再
///    [`_resolveId`] 跟随最多 6 跳 302 找歌单编号；
/// 2. 曲目必须分页拉取（每页 100 首，上限 100 页），QQ 偶发重复返回同一页，
///    用 mid 去重 + 「本页新增为 0 即报错」防止死循环；
/// 3. 字段容错：`singer` 既可能是数组也可能是对象，`interval` 为秒。
class QqPlaylistService {
  QqPlaylistService(this._client, {Duration timeout = const Duration(seconds: 15)})
    : _timeout = timeout;

  final http.Client _client;
  final Duration _timeout;

  /// 不带酷狗会话；带上 QQ 音乐来源页 Referer 与常规浏览器 UA（`c60a92f`）。
  static const _headers = {
    'Referer': 'https://y.qq.com/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  /// 从任意分享文本中提取 QQ 音乐链接；非 QQ 音乐链接返回 null。
  ///
  /// 白名单：host 必须是 `y.qq.com` 或其子域（`*.y.qq.com`），
  /// 拒绝 userInfo（`https://y.qq.com@evil.com/...` 这类钓鱼写法）与非 http(s)。
  static Uri? shareUri(String text) {
    for (final match in RegExp(
      r'''https?://[^\s<>"'\]\[)），。]+''',
    ).allMatches(text)) {
      final uri = Uri.tryParse(match.group(0)!);
      if (uri != null && _isQq(uri)) return uri;
    }
    return null;
  }

  static bool _isQq(Uri uri) =>
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.userInfo.isEmpty &&
      (uri.host == 'y.qq.com' || uri.host.endsWith('.y.qq.com'));

  /// 从链接里直接取歌单编号：`disstid` / `id`（仅 playlist|taoge|playsquare
  /// 路径下）/ 路径式 `/playlist/123` 或 `/playsquare/123`。
  static String? _playlistId(Uri uri) {
    final id =
        uri.queryParameters['disstid'] ??
        (RegExp(r'playlist|taoge|playsquare').hasMatch(uri.path)
            ? uri.queryParameters['id']
            : null) ??
        RegExp(r'/(?:playlist|playsquare)/(\d+)').firstMatch(uri.path)?.group(1);
    return id != null && RegExp(r'^\d+$').hasMatch(id) ? id : null;
  }

  /// 短链需要跟随 302 才能拿到歌单编号；最多 6 跳，且每一跳都必须是 QQ 域。
  Future<String> _resolveId(Uri uri) async {
    for (var hop = 0; hop < 6; hop++) {
      if (!_isQq(uri)) {
        throw const FormatException('分享链接跳转到了非 QQ 音乐页面');
      }
      final id = _playlistId(uri);
      if (id != null) return id;
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll(_headers);
      final response = await _client.send(request).timeout(_timeout);
      await response.stream.drain<void>().timeout(_timeout);
      final location = response.headers['location'];
      if (response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null) {
        uri = uri.resolve(location);
      } else {
        break;
      }
    }
    throw const FormatException('未找到 QQ 歌单编号，请在 QQ 音乐中重新复制歌单分享链接');
  }

  /// 分页读取公开歌单，返回歌单名/总曲数/带歌手时长的曲目列表。
  Future<ExternalPlaylistParseResult> load(Uri share) async {
    final id = await _resolveId(share);
    final tracks = <ExternalPlaylistTrack>[];
    final seen = <String>{};
    var offset = 0;
    var total = 0;
    var name = 'QQ 音乐歌单';
    for (var page = 0; page < 100; page++) {
      final uri = Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg', {
        'data': jsonEncode({
          'comm': {'ct': 24, 'cv': 0},
          'req_0': {
            'module': 'music.srfDissInfo.aiDissInfo',
            'method': 'uniform_get_Dissinfo',
            'param': {
              'disstid': int.parse(id),
              'userinfo': 1,
              'tag': 1,
              'orderlist': 1,
              'song_begin': offset,
              'song_num': 100,
            },
          },
        }),
      });
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw const FormatException('QQ 音乐暂时无法访问，请稍后重试');
      }
      final root = asMap(jsonDecode(utf8.decode(response.bodyBytes)));
      final request = asMap(root['req_0']);
      final data = asMap(request['data']);
      final rootCode = asInt(root['code']);
      final requestCode = asInt(request['code']);
      final dataCode = asInt(data['code']);
      if ((rootCode != null && rootCode != 0) ||
          (requestCode != null && requestCode != 0) ||
          (dataCode != null && dataCode != 0) ||
          data.isEmpty) {
        throw const FormatException('QQ 歌单不可读取，请确认歌单已公开且分享链接有效');
      }
      final info = asMap(data['dirinfo']);
      name = asString(info['title']) ?? name;
      total = asInt(info['songnum']) ?? total;
      final items = asList(data['songlist']);
      var newItems = 0;
      for (final item in items) {
        final song = asMap(item);
        final songId = asString(song['mid'] ?? song['id']);
        if (songId != null && !seen.add(songId)) continue;
        newItems++;
        final title = asString(song['name'] ?? song['title']);
        if (title == null) continue;
        final seconds = asInt(song['interval']);
        tracks.add(
          ExternalPlaylistTrack(
            title: title,
            artist: _artistNames(song['singer']),
            duration: seconds == null || seconds <= 0
                ? null
                : Duration(seconds: seconds),
          ),
        );
      }
      offset += items.length;
      if (items.isEmpty || offset >= total) {
        if (tracks.isEmpty) {
          throw const FormatException('歌单为空或歌曲均不可读取，请确认歌单已公开且分享链接有效');
        }
        return ExternalPlaylistParseResult(
          sourcePlatform: 'QQ音乐',
          playlistName: name,
          songNames: tracks.map((track) => track.title).toList(),
          tracks: tracks,
          totalSongCount: total > 0 ? total : null,
        );
      }
      // 没能推进游标说明 QQ 一直返回同一页，继续请求只会死循环。
      if (newItems == 0) {
        throw const FormatException('QQ 音乐未返回后续歌曲，请稍后重试');
      }
    }
    throw const FormatException('歌单过大，请分成多个歌单后导入');
  }

  /// `singer` 容错：可能是 `[{name: 'A'}, {name: 'B'}]`、`{name: 'A'}` 或
  /// `'A / B'` 字符串；统一用 `' / '` 拼接。
  static String _artistNames(Object? value) {
    if (value is String) return value.trim();
    final items = value is List ? value : (value is Map ? [value] : const []);
    return items
        .map((item) {
          if (item is String) return item.trim();
          return asString(asMap(item)['name']) ?? '';
        })
        .where((name) => name.isNotEmpty)
        .join(' / ');
  }
}
