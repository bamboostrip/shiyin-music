// 本机播放代理的 URL 形态与 Content-Type 推断（iOS `(-11828) Cannot Open`
// 回归用例）：
//
// 背景：所有音源都经 `http://127.0.0.1:<port>/play/<seq>` 交给引擎。iOS 的
// AVPlayer（AVURLAsset）判断容器格式只认 URL 后缀或响应 Content-Type，
// 纯数字路径 + CDN 的 `application/octet-stream` 会让它直接拒绝加载
// （AVFoundationErrorDomain -11828 "Cannot Open"），安卓 ExoPlayer / 桌面
// libmpv 会嗅探字节所以只有 iOS 复现。
//
// 用例锁的是三件事：
//   1. 代理路径把目标音频后缀带进去（`/play/7.flac`），且路由序号仍可解析；
//   2. 后缀只从 URL 的 path 取，查询串里的 `.mp3`（网易云外链）不算；
//   3. Content-Type 后缀优先、其次上游、最后兜底 audio/mpeg。
//
// 注意：这些都是 MusicAudioHandler 上的 static 纯函数，单测不创建
// MusicAudioHandler（其字段初始化会 new 真实 AudioPlayer）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

void main() {
  group('MusicAudioHandler.proxyPathFor', () {
    test('远端 flac 直链把后缀带进代理路径', () {
      expect(
        MusicAudioHandler.proxyPathFor(
          7,
          'https://fs.audio.kugou.com/20260101/abc123.flac?auth=xyz&from=x',
        ),
        '/play/7.flac',
      );
    });

    test('后缀统一小写', () {
      expect(
        MusicAudioHandler.proxyPathFor(
          3,
          'http://cdn.example.com/A/TRACK.FLAC',
        ),
        '/play/3.flac',
      );
    });

    test('查询串里的 .mp3 不算后缀（网易云外链）', () {
      expect(
        MusicAudioHandler.proxyPathFor(
          1,
          'https://music.163.com/song/media/outer/url?id=123.mp3',
        ),
        '/play/1',
      );
    });

    test('本地 Windows 路径（含中文与反斜杠）取到后缀', () {
      expect(
        MusicAudioHandler.proxyPathFor(12, r'D:\Music\那些年\胡夏 - 那些年.flac'),
        '/play/12.flac',
      );
    });

    test('本地无后缀 / 未知后缀不加后缀', () {
      expect(MusicAudioHandler.proxyPathFor(2, r'D:\Music\no_ext'), '/play/2');
      expect(
        MusicAudioHandler.proxyPathFor(2, 'http://cdn.example.com/a.bin'),
        '/play/2',
      );
    });

    test('代理路径能与 proxySeqFromPath 往返', () {
      const url = 'https://fs.audio.kugou.com/x/y.m4a?token=1';
      expect(
        MusicAudioHandler.proxySeqFromPath(
          MusicAudioHandler.proxyPathFor(42, url),
        ),
        42,
      );
    });
  });

  group('MusicAudioHandler.proxySeqFromPath', () {
    test('带后缀与不带后缀都能取出序号', () {
      expect(MusicAudioHandler.proxySeqFromPath('/play/7'), 7);
      expect(MusicAudioHandler.proxySeqFromPath('/play/7.flac'), 7);
      expect(MusicAudioHandler.proxySeqFromPath('/play/12.MP3'), 12);
    });

    test('非序号路径返回 null（由调用方回 410）', () {
      expect(MusicAudioHandler.proxySeqFromPath('/play/x'), isNull);
      expect(MusicAudioHandler.proxySeqFromPath('/play/'), isNull);
      expect(MusicAudioHandler.proxySeqFromPath('/'), isNull);
      expect(MusicAudioHandler.proxySeqFromPath('/other/3.flac'), 3);
    });
  });

  group('MusicAudioHandler.audioExtensionOf', () {
    test('只看 URL path，不看查询串', () {
      expect(
        MusicAudioHandler.audioExtensionOf(
          'https://music.163.com/song/media/outer/url?id=9.mp3',
        ),
        isNull,
      );
      expect(
        MusicAudioHandler.audioExtensionOf(
          'https://cdn.example.com/a/b.mp3?fallback=http://x/c.flac',
        ),
        'mp3',
      );
    });

    test('常见音频后缀', () {
      for (final ext in ['mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus']) {
        expect(
          MusicAudioHandler.audioExtensionOf('https://cdn.example.com/a.$ext'),
          ext,
          reason: ext,
        );
      }
    });

    test('非音频后缀、无后缀、点号在开头都返回 null', () {
      expect(
        MusicAudioHandler.audioExtensionOf('https://cdn.example.com/a.json'),
        isNull,
      );
      expect(
        MusicAudioHandler.audioExtensionOf('https://cdn.example.com/noext'),
        isNull,
      );
      expect(MusicAudioHandler.audioExtensionOf('/tmp/.flac'), isNull);
      expect(MusicAudioHandler.audioExtensionOf('/tmp/a.'), isNull);
    });
  });

  group('MusicAudioHandler.resolveProxyContentType', () {
    test('后缀优先：CDN 标成 octet-stream / mpeg 时按后缀纠正', () {
      expect(
        MusicAudioHandler.resolveProxyContentType(
          extension: 'flac',
          upstream: 'application/octet-stream',
        ),
        'audio/flac',
      );
      expect(
        MusicAudioHandler.resolveProxyContentType(
          extension: 'flac',
          upstream: 'audio/mpeg',
        ),
        'audio/flac',
      );
    });

    test('拿不到后缀时透传上游类型', () {
      expect(
        MusicAudioHandler.resolveProxyContentType(
          extension: null,
          upstream: 'audio/flac',
        ),
        'audio/flac',
      );
    });

    test('既无后缀也无上游类型时兜底 audio/mpeg', () {
      expect(
        MusicAudioHandler.resolveProxyContentType(
          extension: null,
          upstream: null,
        ),
        'audio/mpeg',
      );
      expect(
        MusicAudioHandler.resolveProxyContentType(
          extension: '',
          upstream: '  ',
        ),
        'audio/mpeg',
      );
    });
  });

  group('MusicAudioHandler.contentTypeForPath', () {
    test('按后缀给类型，未知兜底 audio/mpeg', () {
      expect(MusicAudioHandler.contentTypeForPath('/a/b.flac'), 'audio/flac');
      expect(MusicAudioHandler.contentTypeForPath('/a/b.mp3'), 'audio/mpeg');
      expect(MusicAudioHandler.contentTypeForPath('/a/b.wav'), 'audio/wav');
      expect(MusicAudioHandler.contentTypeForPath('/a/b.m4a'), 'audio/mp4');
      expect(MusicAudioHandler.contentTypeForPath('/a/b.bin'), 'audio/mpeg');
      expect(
        MusicAudioHandler.contentTypeForPath(r'D:\Music\胡夏 - 那些年.FLAC'),
        'audio/flac',
      );
    });
  });

  group('MusicAudioHandler.parseByteRange', () {
    test('单段闭区间与开区间', () {
      expect(
        MusicAudioHandler.parseByteRange('bytes=0-1'),
        (start: 0, end: 1),
      );
      expect(
        MusicAudioHandler.parseByteRange('bytes=100-'),
        (start: 100, end: null),
      );
      expect(
        MusicAudioHandler.parseByteRange('  bytes=10-20  '),
        (start: 10, end: 20),
      );
    });

    test('畸形/多段/后缀式一律返回 null（交给上游处理）', () {
      expect(MusicAudioHandler.parseByteRange(null), isNull);
      expect(MusicAudioHandler.parseByteRange('bytes=-500'), isNull);
      expect(MusicAudioHandler.parseByteRange('bytes=5-2'), isNull);
      expect(MusicAudioHandler.parseByteRange('bytes=0-1,3-4'), isNull);
      expect(MusicAudioHandler.parseByteRange('bytes=abc'), isNull);
      expect(MusicAudioHandler.parseByteRange('items=0-1'), isNull);
      expect(MusicAudioHandler.parseByteRange('bytes='), isNull);
    });
  });

  group('MusicAudioHandler.sliceByteStream', () {
    // 上游分块到达的字节：[0,1,2] [3,4,5] [6,7,8,9]
    Stream<List<int>> chunks() =>
        Stream.fromIterable(const [[0, 1, 2], [3, 4, 5], [6, 7, 8, 9]]);

    Future<List<int>> collect(Stream<List<int>> stream) =>
        stream.expand((chunk) => chunk).toList();

    test('跨分块跳过前缀并截取指定长度', () async {
      expect(
        await collect(
          MusicAudioHandler.sliceByteStream(chunks(), skip: 2, count: 5),
        ),
        [2, 3, 4, 5, 6],
      );
    });

    test('探测请求只取前几字节（不做多余读取）', () async {
      expect(
        await collect(
          MusicAudioHandler.sliceByteStream(chunks(), skip: 0, count: 2),
        ),
        [0, 1],
      );
    });

    test('开区间切到末尾 / 跳过全部 / 长度为 0', () async {
      expect(
        await collect(
          MusicAudioHandler.sliceByteStream(chunks(), skip: 8),
        ),
        [8, 9],
      );
      expect(
        await collect(
          MusicAudioHandler.sliceByteStream(chunks(), skip: 99),
        ),
        isEmpty,
      );
      expect(
        await collect(
          MusicAudioHandler.sliceByteStream(chunks(), skip: 0, count: 0),
        ),
        isEmpty,
      );
    });

    test('取够指定字节后取消上游订阅（不把整首拉完）', () async {
      var cancelled = false;
      late StreamController<List<int>> controller;
      controller = StreamController<List<int>>(
        onListen: () {
          for (var i = 0; i < 100; i++) {
            controller.add([i]);
          }
        },
        onCancel: () => cancelled = true,
      );

      final collected = await collect(
        MusicAudioHandler.sliceByteStream(controller.stream, skip: 0, count: 3),
      );
      expect(collected, [0, 1, 2]);
      // cancel 在生成器 return 时同步触发，事件循环下一拍即可观测。
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue);
      await controller.close();
    });
  });
}
