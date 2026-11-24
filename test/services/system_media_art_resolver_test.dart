// SystemMediaArtResolver 的时序单测：本地封面要落盘后才能下发，落盘期间
// 不能挡住 MediaItem、不能把上一首的封面贴到新歌、失败要能重试。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/local_artwork_service.dart';
import 'package:shiyin_music/services/system_media_art.dart';

Song _localSong(String path) => Song(
      id: path,
      title: '晴天',
      artist: '周杰伦',
      hash: path,
      coverUrl: LocalArtworkService.artworkUrlFor(path),
      source: SongSource.local,
    );

const _onlineSong = Song(
  id: '1',
  title: '晴天',
  artist: '周杰伦',
  hash: 'hash_1',
  coverUrl: 'https://example.com/cover.jpg',
);

/// 等已排队的 Future 回调跑完（解析完成后的收尾是微任务链）。
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('在线封面原样透传，不触发落盘', () {
    var resolves = 0;
    final resolver = SystemMediaArtResolver(
      resolve: (_) async {
        resolves++;
        return null;
      },
      onReady: () => fail('在线歌不应回调就绪'),
    )..ensure(_onlineSong);

    expect(
      resolver.artUriFor(_onlineSong.coverUrl),
      Uri.parse('https://example.com/cover.jpg'),
    );
    expect(resolves, 0);
  });

  test('无封面的歌既不解析也不下发', () {
    final resolver = SystemMediaArtResolver(
      resolve: (_) async => fail('无封面不应解析'),
      onReady: () => fail('无封面不应回调就绪'),
    )..ensure(const Song(id: '1', title: 't', artist: 'a', hash: 'h'));

    expect(resolver.artUriFor(null), isNull);
  });

  test('本地封面：落盘完成前不下发，完成后给出 file URI 并通知重发一次',
      () async {
    final pending = Completer<Uri?>();
    var ready = 0;
    final resolver = SystemMediaArtResolver(
      resolve: (_) => pending.future,
      onReady: () => ready++,
    );
    final song = _localSong('/m/a.flac');

    resolver.ensure(song);
    // 未就绪：伪 URL 对系统没有意义，宁可先按无图发。
    expect(resolver.artUriFor(song.coverUrl), isNull);
    expect(ready, 0);

    pending.complete(Uri.file('/cache/a.jpg'));
    await _flush();

    expect(resolver.artUriFor(song.coverUrl), Uri.file('/cache/a.jpg'));
    expect(ready, 1);
  });

  test('同曲重载不重复解析，已有封面持续可用', () async {
    var resolves = 0;
    final resolver = SystemMediaArtResolver(
      resolve: (_) async {
        resolves++;
        return Uri.file('/cache/a.jpg');
      },
      onReady: () {},
    );
    final song = _localSong('/m/a.flac');

    resolver.ensure(song);
    resolver.ensure(song); // 在途：不重复发起
    await _flush();
    resolver.ensure(song); // 已就绪：不重复发起
    await _flush();

    expect(resolves, 1);
    expect(resolver.artUriFor(song.coverUrl), Uri.file('/cache/a.jpg'));
  });

  test('解析期间切歌：旧歌结果丢弃，不会把上一首的封面贴到新歌', () async {
    final first = Completer<Uri?>();
    final second = Completer<Uri?>();
    final requests = <String>[];
    var ready = 0;
    final resolver = SystemMediaArtResolver(
      resolve: (target) {
        requests.add(target);
        return requests.length == 1 ? first.future : second.future;
      },
      onReady: () => ready++,
    );
    final a = _localSong('/m/a.flac');
    final b = _localSong('/m/b.flac');

    resolver.ensure(a);
    resolver.ensure(b);

    first.complete(Uri.file('/cache/a.jpg'));
    await _flush();

    expect(ready, 0, reason: '旧歌的结果不属于当前歌，不能触发重发');
    expect(resolver.artUriFor(a.coverUrl), isNull);
    expect(resolver.artUriFor(b.coverUrl), isNull);

    second.complete(Uri.file('/cache/b.jpg'));
    await _flush();

    expect(ready, 1);
    expect(resolver.artUriFor(b.coverUrl), Uri.file('/cache/b.jpg'));
    // 非当前歌的伪 URL 永远不下发。
    expect(resolver.artUriFor(a.coverUrl), isNull);
    expect(requests, ['/m/a.flac', '/m/b.flac']);
  });

  test('无图/读取失败不缓存否定结果：同曲再 ensure 会重试', () async {
    var resolves = 0;
    final resolver = SystemMediaArtResolver(
      resolve: (_) async {
        resolves++;
        return resolves >= 3 ? Uri.file('/cache/a.jpg') : null;
      },
      onReady: () {},
    );
    final song = _localSong('/m/a.flac');

    resolver.ensure(song);
    await _flush();
    expect(resolver.artUriFor(song.coverUrl), isNull);

    // 外接盘第一次读不到，挂载后同曲重载（重试/切音质）必须能补上封面。
    resolver.ensure(song);
    await _flush();
    resolver.ensure(song);
    await _flush();

    expect(resolves, 3);
    expect(resolver.artUriFor(song.coverUrl), Uri.file('/cache/a.jpg'));
  });

  test('落盘抛错被吞掉且可重试，不变成未处理异步异常', () async {
    var resolves = 0;
    final resolver = SystemMediaArtResolver(
      resolve: (_) async {
        resolves++;
        if (resolves == 1) throw StateError('disk full');
        return Uri.file('/cache/a.jpg');
      },
      onReady: () {},
    );
    final song = _localSong('/m/a.flac');

    resolver.ensure(song);
    await _flush();
    expect(resolver.artUriFor(song.coverUrl), isNull);

    resolver.ensure(song);
    await _flush();
    expect(resolver.artUriFor(song.coverUrl), Uri.file('/cache/a.jpg'));
  });

  test('切到在线歌会清掉本地目标：切回同一首本地歌必须重新解析', () async {
    var resolves = 0;
    final resolver = SystemMediaArtResolver(
      resolve: (_) async {
        resolves++;
        return Uri.file('/cache/a.jpg');
      },
      onReady: () {},
    );
    final local = _localSong('/m/a.flac');

    resolver.ensure(local);
    await _flush();
    expect(resolves, 1);

    // 在线歌没有 localart 目标；如果这里不把 _target 清空，切回本地歌时
    // 会误以为封面仍在缓存里，系统清掉 cache 文件后永远不补图。
    resolver.ensure(_onlineSong);
    expect(resolver.artUriFor(local.coverUrl), isNull);

    resolver.ensure(local);
    await _flush();
    expect(resolves, 2);
    expect(resolver.artUriFor(local.coverUrl), Uri.file('/cache/a.jpg'));
  });

  test('onReady 抛错被吞掉，不产生未处理异步异常', () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final resolver = SystemMediaArtResolver(
        resolve: (_) async => Uri.file('/cache/a.jpg'),
        onReady: () => throw StateError('handler disposed'),
      );
      resolver.ensure(_localSong('/m/a.flac'));
      await _flush();
    }, (error, stack) => errors.add(error));

    expect(errors, isEmpty);
  });
}
