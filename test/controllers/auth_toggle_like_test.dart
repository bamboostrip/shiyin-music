import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 点赞链路假客户端：增/删可用 Completer 门控，精确控制"服务端回包时机"；
/// 全量同步（GET /playlist/track/all）可桩。
class _FakeLikeClient implements ApiClientInterface {
  Completer<Map<String, dynamic>>? addGate;
  Completer<Map<String, dynamic>>? delGate;
  bool failNext = false;

  /// 覆盖默认的点赞回包（默认含 fileid=7，用于填充 fileId 映射）。
  Map<String, dynamic>? addRespOverride;

  /// 全量同步回包；为 null 时同步链路抛错（模拟 fileId 无法定位）。
  Map<String, dynamic>? trackAllResp;

  final posts = <String>[];
  String? lastDelFileIds;

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(
    String path, [
    Map<String, Object?> query = const {},
  ]) async {
    if (path == '/playlist/track/all') {
      final resp = trackAllResp;
      if (resp != null) return resp;
      throw UnimplementedError(path);
    }
    throw UnimplementedError(path);
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async {
    posts.add(path);
    if (failNext) {
      failNext = false;
      throw Exception('server boom');
    }
    if (path == '/playlist/tracks/add') {
      final gate = addGate;
      if (gate != null) return gate.future;
      return addRespOverride ??
          {
            'info': [
              {'fileid': 7}
            ],
            'count': 1,
          };
    }
    if (path == '/playlist/tracks/del') {
      lastDelFileIds = query['fileids']?.toString();
      final gate = delGate;
      if (gate != null) return gate.future;
      return {'count': 0};
    }
    throw ArgumentError('unexpected path: $path');
  }

  @override
  void close() {}
}

const _likedPlaylist = PlaylistSummary(
  id: '1',
  title: '我喜欢',
  listId: '100',
);

/// 数字 id：取消时可经 song.id 兜底定位 fileId，不触发全量同步。
const _song = Song(id: '12345', title: '歌名', artist: '歌手', hash: 'h1');

/// 非数字 id 且点赞回包不带 fileid：取消时 fileId 缺失，走全量同步慢路径。
const _songNoFileId = Song(id: 'abc', title: '歌名', artist: '歌手', hash: 'h2');

AuthController _buildAuth(_FakeLikeClient client) {
  final auth = AuthController(MusicApi(client), CacheService());
  addTearDown(auth.dispose);
  auth.playlists = [_likedPlaylist];
  return auth;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('点赞当帧生效：服务端回包前红心已翻转并通知', () async {
    final client = _FakeLikeClient()..addGate = Completer();
    final auth = _buildAuth(client);
    var notified = 0;
    auth.addListener(() => notified++);

    final future = auth.toggleLike(_song);

    // 服务端尚未回包：本地状态已翻转且已通知 UI。
    expect(auth.isLiked(_song), isTrue, reason: '乐观更新应同步生效');
    expect(notified, 1, reason: '应立即 notifyListeners 让红心当帧变色');

    client.addGate!.complete({
      'info': [
        {'fileid': 7}
      ],
      'count': 1,
    });
    await future;
    expect(auth.isLiked(_song), isTrue);
    expect(client.posts, contains('/playlist/tracks/add'));
  });

  test('点赞服务端失败：回滚本地状态并抛错', () async {
    final client = _FakeLikeClient()..failNext = true;
    final auth = _buildAuth(client);

    await expectLater(auth.toggleLike(_song), throwsException);
    expect(auth.isLiked(_song), isFalse, reason: '失败应回滚乐观状态');
  });

  test('取消点赞当帧生效：服务端回包前红心已熄灭', () async {
    final client = _FakeLikeClient();
    final auth = _buildAuth(client);
    await auth.toggleLike(_song);
    expect(auth.isLiked(_song), isTrue);

    client.delGate = Completer();
    final future = auth.toggleLike(_song);

    expect(auth.isLiked(_song), isFalse, reason: '取消也应乐观即时生效');
    client.delGate!.complete({'count': 0});
    await future;
    expect(auth.isLiked(_song), isFalse);
    expect(client.posts, contains('/playlist/tracks/del'));
  });

  test('快速连点两次方向正确：先取消后重赞终态为赞', () async {
    final client = _FakeLikeClient();
    final auth = _buildAuth(client);
    await auth.toggleLike(_song);

    client.delGate = Completer();
    client.addGate = Completer();
    final unlikeFuture = auth.toggleLike(_song);
    expect(auth.isLiked(_song), isFalse);
    // 第二次点按读到的是已翻转状态，应判定为"重赞"并立即翻回。
    final relikeFuture = auth.toggleLike(_song);
    expect(auth.isLiked(_song), isTrue, reason: '连点方向不应反转');

    client.delGate!.complete({'count': 0});
    await unlikeFuture;
    client.addGate!.complete({
      'info': [
        {'fileid': 7}
      ],
      'count': 1,
    });
    await relikeFuture;
    expect(auth.isLiked(_song), isTrue);
    expect(client.posts, [
      '/playlist/tracks/add',
      '/playlist/tracks/del',
      '/playlist/tracks/add',
    ]);
  });

  test('取消时缺 fileId：先全量同步定位再删，终态正确', () async {
    final client = _FakeLikeClient()
      ..addRespOverride = {'count': 1}
      ..trackAllResp = {
        'songs': [
          {'hash': 'h2', 'fileid': 9, 'name': '歌名'},
        ],
      };
    final auth = _buildAuth(client);
    await auth.toggleLike(_songNoFileId);
    expect(auth.isLiked(_songNoFileId), isTrue);

    // 乐观熄灭不应等待后台的全量同步。
    final future = auth.toggleLike(_songNoFileId);
    expect(auth.isLiked(_songNoFileId), isFalse);
    await future;

    expect(auth.isLiked(_songNoFileId), isFalse);
    expect(client.lastDelFileIds, '9', reason: '应经同步拿到 fileid 后删除');
  });

  test('取消时同步成功但服务端无此歌：保持熄灭，不回滚成收藏', () async {
    final client = _FakeLikeClient()
      ..addRespOverride = {'count': 1}
      // 同步成功但服务端喜欢的列表里没有 h2（如另一台设备已取消）。
      ..trackAllResp = {
        'songs': [
          {'hash': 'other', 'fileid': 100, 'name': '别的歌'},
        ],
      };
    final auth = _buildAuth(client);
    await auth.toggleLike(_songNoFileId);
    expect(auth.isLiked(_songNoFileId), isTrue);

    await auth.toggleLike(_songNoFileId);

    // 同步结果即真值：保持乐观移除，不得回滚加回（否则本地与服务端分叉）。
    expect(auth.isLiked(_songNoFileId), isFalse);
    expect(client.posts, isNot(contains('/playlist/tracks/del')));
  });

  test('取消首删失败后重同步发现服务端已无此歌：保持熄灭不回滚', () async {
    // 快照 fileId 直删的路径：首次删除请求失败（快照 fileId 已失效等），
    // 重同步后服务端喜欢的列表里已无此歌——与上一用例同语义（同步结果即
    // 真值），此前这里会 rethrow 把红心回滚加回，与主路径分叉。
    final client = _FakeLikeClient()
      ..addRespOverride = {
        'info': [
          {'fileid': 9}
        ],
        'count': 1,
      }
      ..trackAllResp = {
        'songs': [
          {'hash': 'other', 'fileid': 100, 'name': '别的歌'},
        ],
      };
    final auth = _buildAuth(client);
    await auth.toggleLike(_songNoFileId);
    expect(auth.isLiked(_songNoFileId), isTrue);

    client.failNext = true; // 首次 /playlist/tracks/del 抛错，触发重同步分支
    await auth.toggleLike(_songNoFileId);

    expect(auth.isLiked(_songNoFileId), isFalse, reason: '同步已确认服务端无此歌，保持移除');
    expect(client.posts, contains('/playlist/tracks/del'));
  });

  test('取消时同步失败：无法定真值，回滚成收藏', () async {
    final client = _FakeLikeClient()
      ..addRespOverride = {'count': 1}
      ..trackAllResp = null; // 同步链路抛错（模拟断网）
    final auth = _buildAuth(client);
    await auth.toggleLike(_songNoFileId);
    expect(auth.isLiked(_songNoFileId), isTrue);

    // 拿不到服务端真值：回滚并抛错（调用方据此弹 toast），红心回弹。
    // 与「点赞服务端失败」用例同契约：失败必回滚 + 必 rethrow。
    await expectLater(auth.toggleLike(_songNoFileId), throwsException);

    // 拿不到服务端真值：恢复点按前状态，红心回弹。
    expect(auth.isLiked(_songNoFileId), isTrue);
    expect(client.posts, isNot(contains('/playlist/tracks/del')));
  });
}
