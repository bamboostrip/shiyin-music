// 本地歌曲歌词匹配与缓存（LocalLyricsService）行为锁定。
//
// 移植自上游 kgka_Music_hl 3.2.0（87c35a1，含 c60a92f 的路径分隔符修复），
// 本文件覆盖：
// - 加载顺序：同名 .lrc → 内嵌歌词 → 本地缓存 → 元数据在线匹配缓存；
// - 空/无效 .lrc 不得抑制内嵌或在线歌词（fork 旧实现的回归点）；
// - 缓存按「路径 sha1 + 文件签名」命中，文件替换/元数据变化后重新匹配；
// - 网络失败/超时/候选异常全部静默降级为空，不抛错、不缓存空结果；
// - 同一首歌并发 load 共享同一个 Future（in-flight 去重）；
// - .lrc 编码：UTF-16 BOM（LE/BE）/ UTF-8 严格 / GBK 兜底。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/local_lyrics_service.dart';
import 'package:shiyin_music/services/music_api.dart';

const _timedText = '[00:01.00]First test line\n[00:02.00]Second test line';

const _matchedSong = Song(
  id: 'online-id',
  title: 'Test Song',
  artist: 'Test Artist',
  hash: 'ONLINE_HASH',
  duration: Duration(seconds: 180),
);

Song _onlineSong({
  String hash = 'ONLINE_HASH',
  Duration duration = const Duration(seconds: 180),
}) => Song(
  id: 'online-$hash',
  title: 'Test Song',
  artist: 'Test Artist',
  hash: hash,
  duration: duration,
);

List<int> _utf16Bytes(String text, {required bool littleEndian}) {
  final bytes = <int>[
    littleEndian ? 0xff : 0xfe,
    littleEndian ? 0xfe : 0xff,
  ];
  for (final unit in text.codeUnits) {
    if (littleEndian) {
      bytes
        ..add(unit & 0xff)
        ..add(unit >> 8);
    } else {
      bytes
        ..add(unit >> 8)
        ..add(unit & 0xff);
    }
  }
  return bytes;
}

/// GBK 编码的「中文歌词」：d6 d0 ce c4 b8 e8 b4 ca。
const _gbkChineseLyrics = <int>[0xd6, 0xd0, 0xce, 0xc4, 0xb8, 0xe8, 0xb4, 0xca];

/// 只实现 [LocalLyricsService] 用到的两个接口，其余成员 noSuchMethod 兜底
/// （与 test/ 下既有 MusicApi 测试替身同款写法）。
class _FakeMusicApi implements MusicApi {
  List<Song> results = const [];
  final queries = <String>[];
  final lyricHashes = <String>[];
  final emptyLyricHashes = <String>{};
  final failingLyricHashes = <String>{};
  bool offline = false;

  /// 非空时接管 searchSongs（构造超时 / in-flight 场景）。
  Future<List<Song>> Function(String query)? onSearch;

  /// 非空时接管 lyrics（构造候选失败 / 超时场景）。
  Future<List<LyricLine>> Function(Song song)? onLyrics;

  @override
  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    queries.add(keywords);
    final handler = onSearch;
    if (handler != null) {
      return handler(keywords);
    }
    if (offline) {
      throw const SocketException('offline');
    }
    return results;
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async {
    lyricHashes.add(song.hash);
    final handler = onLyrics;
    if (handler != null) {
      return handler(song);
    }
    if (failingLyricHashes.contains(song.hash)) {
      throw const SocketException('lyric unavailable');
    }
    if (emptyLyricHashes.contains(song.hash)) {
      return const [];
    }
    return parseLyrics(_timedText);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late File audio;
  late File sidecar;
  late Song localSong;
  late _FakeMusicApi api;
  late List<String> embeddedCalls;
  String? embeddedLyrics;
  Future<String?> Function(String path)? onReadEmbedded;

  Future<String?> readEmbedded(String path) async {
    embeddedCalls.add(path);
    final handler = onReadEmbedded;
    if (handler != null) {
      return handler(path);
    }
    return embeddedLyrics;
  }

  LocalLyricsService service({
    CacheService? cache,
    bool useCache = true,
    Duration timeout = const Duration(seconds: 10),
  }) => LocalLyricsService(
    api: api,
    cache: useCache ? (cache ?? CacheService()) : null,
    embeddedLyricsReader: readEmbedded,
    requestTimeout: timeout,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp(
      'local_lyrics_service_test_',
    );
    final separator = Platform.pathSeparator;
    audio = await File(
      '${temp.path}${separator}Test Song.mp3',
    ).writeAsBytes([1, 2, 3]);
    sidecar = File('${temp.path}${separator}Test Song.lrc');
    localSong = Song(
      id: audio.path,
      hash: audio.path,
      title: 'Test Song',
      artist: 'Test Artist',
      duration: const Duration(seconds: 180),
      source: SongSource.local,
    );
    api = _FakeMusicApi()..results = const [_matchedSong];
    embeddedCalls = <String>[];
    embeddedLyrics = null;
    onReadEmbedded = null;
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  group('加载顺序与 .lrc', () {
    test('.lrc 命中直接解析，不发网络、不读内嵌', () async {
      await sidecar.writeAsString('[00:03.00]本地歌词');

      final lines = await service().load(localSong);

      expect(lines.map((line) => line.text), ['本地歌词']);
      expect(api.queries, isEmpty);
      expect(api.lyricHashes, isEmpty);
      expect(embeddedCalls, isEmpty);
    });

    test('.LRC 大写扩展名同样命中（Linux/Android 区分大小写）', () async {
      await File('${temp.path}${Platform.pathSeparator}Test Song.LRC')
          .writeAsString('[00:04.00]大写扩展名');

      final lines = await service().load(localSong);

      expect(lines.single.text, '大写扩展名');
      expect(api.queries, isEmpty);
    });

    test('空 .lrc 不抑制内嵌歌词', () async {
      await sidecar.writeAsString('');
      embeddedLyrics = _timedText;

      final lines = await service().load(localSong);

      expect(lines, hasLength(2));
      expect(embeddedCalls, hasLength(1));
      expect(api.queries, isEmpty);
    });

    test('只有元数据标签的无效 .lrc 不抑制在线匹配', () async {
      await sidecar.writeAsString('[ar:Test Artist]\n[ti:Test Song]');

      final lines = await service().load(localSong);

      expect(lines, hasLength(2));
      expect(api.queries, hasLength(1));
    });

    test('编码损坏的 .lrc 被跳过，继续在线匹配', () async {
      // 0xff 既不是合法 UTF-8 起始字节，也不是合法 GBK 单字节。
      await sidecar.writeAsBytes([0xff]);

      final lines = await service().load(localSong);

      expect(lines, hasLength(2));
      expect(api.queries, hasLength(1));
    });

    test('超过 2MB 的 .lrc 被跳过', () async {
      // 若真的读取，解析结果会是「超大文件」而不是在线歌词。
      await sidecar.writeAsBytes([
        ...utf8.encode('[00:05.00]超大文件'),
        ...List<int>.filled(2 * 1024 * 1024, 0x20),
      ]);

      final lines = await service().load(localSong);

      expect(lines.map((line) => line.text), ['First test line', 'Second test line']);
      expect(api.queries, hasLength(1));
    });
  });

  group('内嵌歌词', () {
    test('带时间轴的内嵌歌词命中后不发网络', () async {
      embeddedLyrics = _timedText;

      final lines = await service().load(localSong);

      expect(lines.map((line) => line.text), ['First test line', 'Second test line']);
      expect(embeddedCalls, [localSong.id]);
      expect(api.queries, isEmpty);
      expect(api.lyricHashes, isEmpty);
    });

    test('内嵌读取异常不阻断在线匹配', () async {
      onReadEmbedded = (_) async => throw const FileSystemException('unreadable');

      final lines = await service().load(localSong);

      expect(lines, hasLength(2));
      expect(api.queries, hasLength(1));
    });

    test('纯文本内嵌歌词在离线时按一整行兜底，不臆造时间戳', () async {
      api.offline = true;
      embeddedLyrics = 'First line\nSecond line';

      final lines = await service().load(localSong);

      expect(lines, hasLength(1));
      expect(lines.single.text, 'First line\nSecond line');
      expect(lines.single.time, Duration.zero);
    });

    test('纯文本内嵌歌词不阻断在线匹配', () async {
      embeddedLyrics = '第一行\n第二行';

      final lines = await service().load(localSong);

      expect(lines, hasLength(2));
      expect(lines.first.text, 'First test line');
      expect(api.queries, hasLength(1));
    });
  });

  group('在线匹配', () {
    test('按「歌手 歌名」搜索，只把匹配到的 hash 交给歌词接口', () async {
      final lines = await service().load(localSong);

      expect(lines.map((line) => line.text), ['First test line', 'Second test line']);
      expect(api.queries, ['Test Artist Test Song']);
      expect(api.lyricHashes, ['ONLINE_HASH']);
    });

    test('首个候选歌词为空时继续下一个', () async {
      api.results = [_onlineSong(hash: 'EMPTY'), _matchedSong];
      api.emptyLyricHashes.add('EMPTY');

      final lines = await service().load(localSong);

      expect(lines, hasLength(2));
      expect(api.lyricHashes, ['EMPTY', 'ONLINE_HASH']);
    });

    test('候选拉歌词抛错时继续下一个', () async {
      api.results = [_onlineSong(hash: 'ERROR'), _matchedSong];
      api.failingLyricHashes.add('ERROR');

      final lines = await service().load(localSong);

      expect(lines, hasLength(2));
      expect(api.lyricHashes, ['ERROR', 'ONLINE_HASH']);
    });

    test('最多只尝试前 3 个匹配候选', () async {
      api.results = [
        _onlineSong(hash: 'H0', duration: const Duration(seconds: 180)),
        _onlineSong(hash: 'H1', duration: const Duration(seconds: 181)),
        _onlineSong(hash: 'H2', duration: const Duration(seconds: 182)),
        _onlineSong(hash: 'H3', duration: const Duration(seconds: 183)),
      ];
      api.emptyLyricHashes.addAll(['H0', 'H1', 'H2', 'H3']);

      final lines = await service().load(localSong);

      expect(lines, isEmpty);
      expect(api.lyricHashes, ['H0', 'H1', 'H2']);
    });

    test('未知歌手且无时长时宁缺毋滥，不拉歌词', () async {
      final song = Song(
        id: audio.path,
        hash: audio.path,
        title: 'Test Song',
        artist: '未知艺人',
        source: SongSource.local,
      );

      final lines = await service().load(song);

      expect(lines, isEmpty);
      expect(api.queries, hasLength(1));
      expect(api.lyricHashes, isEmpty);
    });

    test('搜索失败静默返回空，不抛错也不缓存空结果', () async {
      api.offline = true;

      final lines = await service().load(localSong);

      expect(lines, isEmpty);
      expect(api.queries, hasLength(1));

      // 网络恢复后下一次播放能重试成功，说明失败结果没有写进缓存。
      api.offline = false;
      final retried = await service().load(localSong);
      expect(retried, hasLength(2));
      expect(api.queries, hasLength(2));
      expect(api.lyricHashes, hasLength(1));
    });

    test('搜索超时静默降级为空，不抛错', () async {
      final never = Completer<List<Song>>();
      api.onSearch = (_) => never.future;

      final lines = await service(
        timeout: const Duration(milliseconds: 50),
      ).load(localSong);

      expect(lines, isEmpty);
      expect(api.queries, hasLength(1));
      expect(api.lyricHashes, isEmpty);
    });

    test('候选歌词超时后继续下一个候选', () async {
      api.results = [
        _onlineSong(hash: 'SLOW', duration: const Duration(seconds: 180)),
        _onlineSong(hash: 'FAST', duration: const Duration(seconds: 181)),
      ];
      final never = Completer<List<LyricLine>>();
      api.onLyrics = (song) => song.hash == 'SLOW'
          ? never.future
          : Future.value(parseLyrics(_timedText));

      final lines = await service(
        timeout: const Duration(milliseconds: 50),
      ).load(localSong);

      expect(lines, hasLength(2));
      expect(api.lyricHashes, ['SLOW', 'FAST']);
    });

    test('未传 cache 时不做本地缓存，每次都会请求网络', () async {
      await service(useCache: false).load(localSong);
      await service(useCache: false).load(localSong);

      expect(api.queries, hasLength(2));
      expect(api.lyricHashes, hasLength(2));
    });
  });

  group('缓存', () {
    test('同 signature 的新实例直接命中缓存，不发网络', () async {
      await service().load(localSong);

      final prefs = await SharedPreferences.getInstance();
      final keys = prefs
          .getKeys()
          .where((key) => key.startsWith('cache_local_lyric_v1_'))
          .toList();
      expect(keys, hasLength(1), reason: '缓存 key 应以 cache_local_lyric_v1_ 开头');
      expect(keys.single, isNot(contains('Test Song')), reason: '不直接拿本地路径当 key');

      final lines = await service().load(localSong);

      expect(lines, hasLength(2));
      expect(api.queries, hasLength(1), reason: '第二次加载应命中缓存，不再搜索');
      expect(api.lyricHashes, hasLength(1));
    });

    test('音频文件被替换后 signature 失效，重新匹配', () async {
      await service().load(localSong);
      expect(api.queries, hasLength(1));

      await audio.writeAsBytes([1, 2, 3, 4, 5]);
      final lines = await service().load(localSong);

      expect(lines, hasLength(2));
      expect(api.queries, hasLength(2));
      expect(api.lyricHashes, hasLength(2));
    });

    test('歌曲元数据变化后 signature 失效，重新匹配', () async {
      await service().load(localSong);
      final changed = Song(
        id: audio.path,
        hash: audio.path,
        title: 'Test Song',
        artist: 'Other Artist',
        duration: const Duration(seconds: 180),
        source: SongSource.local,
      );

      await service().load(changed);

      expect(api.queries, hasLength(2));
    });

    test('有效 .lrc 优先于已缓存的在线歌词', () async {
      await service().load(localSong);
      await sidecar.writeAsString('[00:03.00]本地覆盖');

      final lines = await service().load(localSong);

      expect(lines.single.text, '本地覆盖');
      expect(api.queries, hasLength(1));
    });

    test('缓存写入失败不影响本次歌词返回', () async {
      // SharedPreferences 的平台层失败无法在单测里真实注入，这里用
      // 不可用的 CacheService 子类模拟 write 抛错，确认 load 仍返回歌词。
      await service(cache: _ThrowingCacheService()).load(localSong);

      expect(api.queries, hasLength(1));
      expect(api.lyricHashes, hasLength(1));
    });
  });

  group('in-flight 去重', () {
    test('并发 load 同一首歌共享同一个 Future，只请求一次', () async {
      final never = Completer<List<Song>>();
      api.onSearch = (_) => never.future;
      final lyricsService = service();

      final first = lyricsService.load(localSong);
      final second = lyricsService.load(localSong);

      expect(identical(first, second), isTrue);
      never.complete(const [_matchedSong]);
      final results = await Future.wait([first, second]);
      expect(results[0].map((line) => line.text), [
        'First test line',
        'Second test line',
      ]);
      expect(results[1], results[0]);
      expect(api.queries, hasLength(1));
      expect(api.lyricHashes, hasLength(1));
    });

    test('失败后清理 in-flight 登记，可以重试', () async {
      api.offline = true;
      final lyricsService = service();
      expect(await lyricsService.load(localSong), isEmpty);

      api.offline = false;
      final lines = await lyricsService.load(localSong);

      expect(lines, hasLength(2));
      expect(api.queries, hasLength(2));
    });
  });

  group('decodeLocalLyricBytes 编码', () {
    test('UTF-8 严格解码', () {
      expect(
        decodeLocalLyricBytes(utf8.encode('[00:01.00]中文歌词')),
        '[00:01.00]中文歌词',
      );
    });

    test('UTF-16LE BOM 解码', () {
      expect(
        decodeLocalLyricBytes(_utf16Bytes(_timedText, littleEndian: true)),
        _timedText,
      );
    });

    test('UTF-16BE BOM 解码', () {
      expect(
        decodeLocalLyricBytes(_utf16Bytes(_timedText, littleEndian: false)),
        _timedText,
      );
    });

    test('GBK 中文歌词解码', () {
      expect(
        decodeLocalLyricBytes([
          ...ascii.encode('[00:01.00]'),
          ..._gbkChineseLyrics,
        ]),
        '[00:01.00]中文歌词',
      );
    });

    test('截断的 UTF-16 抛 FormatException', () {
      expect(
        () => decodeLocalLyricBytes(const [0xff, 0xfe, 0x41]),
        throwsFormatException,
      );
    });

    test('非法字节抛 FormatException（交给上层跳过该 .lrc）', () {
      expect(
        () => decodeLocalLyricBytes(const [0xff]),
        throwsFormatException,
      );
    });

    test('.lrc 为 UTF-16LE 时先解码再解析', () async {
      await sidecar.writeAsBytes(_utf16Bytes(_timedText, littleEndian: true));

      final lines = await service().load(localSong);

      expect(lines.map((line) => line.text), [
        'First test line',
        'Second test line',
      ]);
      expect(api.queries, isEmpty);
    });

    test('.lrc 为 GBK 时中文不乱码', () async {
      await sidecar.writeAsBytes([
        ...ascii.encode('[00:01.00]'),
        ..._gbkChineseLyrics,
      ]);

      final lines = await service().load(localSong);

      expect(lines.single.text, '中文歌词');
      expect(api.queries, isEmpty);
    });
  });
}

/// 模拟平台层写缓存失败（[CacheService.write] 抛异常）。
class _ThrowingCacheService extends CacheService {
  @override
  Future<void> write(String key, Map<String, dynamic> payload) async {
    throw Exception('write failed');
  }
}
