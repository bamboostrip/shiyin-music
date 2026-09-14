// 候选映射为可播放 Song 的纯函数测试(不依赖 Rust 初始化/平台通道)。
//
// 注意:生成层 api.dart 只 import 不 re-export IdentifyCandidate,
// 与 lib/controllers/local_music_controller.dart 同款做法——直接 import
// 声明所在的 src/rust/services/identify.dart。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/rust_api_client.dart';
import 'package:shiyin_music/services/identify_service.dart';
import 'package:shiyin_music/src/rust/services/identify.dart' as rust;

void main() {
  group('candidateToSong', () {
    test('完整候选映射为可播放 Song,置信度 = 1 - dist', () {
      final c = rust.IdentifyCandidate(
        name: '晴天',
        singer: '周杰伦',
        hash: 'abc123',
        albumAudioId: '12345',
        albumId: '999',
        albumName: '叶惠美',
        cover: 'http://example.com/a.jpg',
        hash320: 'abc320',
        hashFlac: 'abcflac',
        durationMs: 269000,
        dist: 0.08,
      );
      final m = IdentifyService.candidateToSong(c);
      expect(m.song.hash, 'abc123');
      expect(m.song.id, '12345');
      expect(m.song.title, '晴天');
      expect(m.song.artist, '周杰伦');
      expect(m.song.albumName, '叶惠美');
      expect(m.song.duration, const Duration(milliseconds: 269000));
      expect(m.confidence, closeTo(0.92, 1e-9));
    });

    test('空字段兜底为未知歌曲/未知艺人,durationMs=0 → null', () {
      final c = rust.IdentifyCandidate(
        name: '',
        singer: '',
        hash: 'h1',
        albumAudioId: '',
        albumId: '',
        albumName: '',
        cover: '',
        hash320: '',
        hashFlac: '',
        durationMs: 0,
        dist: 1.0,
      );
      final m = IdentifyService.candidateToSong(c);
      expect(m.song.title, '未知歌曲');
      expect(m.song.artist, '未知艺人');
      expect(m.song.id, 'h1'); // 无 albumAudioId 时用 hash 兜底
      expect(m.song.duration, isNull);
      expect(m.confidence, 0.0);
    });

    test('cover 相对路径补酷狗图床前缀', () {
      final c = rust.IdentifyCandidate(
        name: 'x',
        singer: 'y',
        hash: 'h',
        albumAudioId: '',
        albumId: '',
        albumName: '',
        cover: 'stdmusic/20210101/a.jpg',
        hash320: '',
        hashFlac: '',
        durationMs: 0,
        dist: 0.5,
      );
      final m = IdentifyService.candidateToSong(c);
      expect(m.song.coverUrl, startsWith('http'));
    });
  });

  group('identify', () {
    test('候选按置信度降序排列', () async {
      // 构造两条候选:dist 越小置信度越高,验证 identify 输出排序。
      final candidates = [
        _candidate(hash: 'far', dist: 0.8),
        _candidate(hash: 'near', dist: 0.1),
      ];
      final api = _FakeRustApiClient(candidates);
      final matches = await IdentifyService.identify(api, Uint8List(0));
      expect(matches.map((m) => m.song.hash), ['near', 'far']);
      expect(matches.first.confidence, closeTo(0.9, 1e-9));
    });
  });
}

/// 便捷构造:只填差异化字段,其余给合法缺省。
rust.IdentifyCandidate _candidate({
  required String hash,
  required double dist,
}) => rust.IdentifyCandidate(
  name: '歌',
  singer: '艺人',
  hash: hash,
  albumAudioId: 'id-$hash',
  albumId: '',
  albumName: '',
  cover: '',
  hash320: '',
  hashFlac: '',
  durationMs: 0,
  dist: dist,
);

/// 注入假客户端:identify 直接回放预置候选,不触发 RustLib;
/// 其余接口成员(tokens/get/post 等)测试不会触达,noSuchMethod 兜底。
class _FakeRustApiClient implements RustApiClient {
  _FakeRustApiClient(this.candidates);

  final List<rust.IdentifyCandidate> candidates;

  @override
  Future<List<rust.IdentifyCandidate>> identify(Uint8List pcm) async =>
      candidates;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
