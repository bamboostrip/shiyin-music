import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

/// `PlaylistSummary.fromSearch` 的字段契约测试。
///
/// 契约来源是仓库根目录的 `api.json`（KuGou Music API 网关 OpenAPI 文档）：
/// `/search/special` 返回 `SearchPlaylistItem[]`，字段为
/// `specialname` / `specialid` / `gid` / `song_count` / `nickname` /
/// `total_play_count` / `img` / `publish_time` / `status`。
void main() {
  group('PlaylistSummary.fromSearch 字段契约', () {
    test('按 api.json 的 SearchPlaylistItem 真实形状解析出全部展示字段', () {
      // 取真实取值类型：specialid/song_count/total_play_count 声明为
      // int|string 双类型，img 是可能含 `{size}` 占位符的地址。
      final playlist = PlaylistSummary.fromSearch({
        'specialname': '华语经典',
        'specialid': 123456789,
        'gid': 'global-abc',
        'song_count': '50',
        'nickname': '小酷',
        'total_play_count': 9876543,
        'img': 'https://imge.kugou.com/special/{size}/cover.jpg',
        'publish_time': '2024-01-01',
        'status': 0,
      });

      // 详情/曲目接口按全局 ID 取数，非空 gid 必须优先。
      expect(playlist.id, 'global-abc');
      expect(playlist.title, '华语经典');
      expect(playlist.subtitle, '小酷');
      expect(playlist.creatorName, '小酷');
      expect(playlist.songCount, 50);
      expect(playlist.playCount, 9876543);
      // `{size}` 占位符应被归一化成具体尺寸，否则是死链。
      expect(playlist.coverUrl, contains('/480/'));
      expect(playlist.coverUrl, isNot(contains('{size}')));
      // sourceGlobalId 与 id 一致，供详情页判定「普通歌单」。
      expect(playlist.sourceGlobalId, 'global-abc');
    });

    test('gid 缺失或为空串时 id 为空串：数字 specialid 打不开详情', () {
      // 实测 /playlist/detail 只接受全局 ID，传 specialid 返回空数据，
      // 因此不能回退数字 ID，否则搜索列表会出现点开是空页面的死条目。
      final missingGid = PlaylistSummary.fromSearch({
        'specialname': '无 gid',
        'specialid': '99887766',
      });
      expect(missingGid.id, '');
      expect(missingGid.sourceGlobalId, isNull);

      final emptyGid = PlaylistSummary.fromSearch({
        'specialname': 'gid 为空串',
        'gid': '   ',
        'specialid': 42,
      });
      expect(emptyGid.id, '');
    });

    test('gid 与 specialid 都缺失时 id 为空串，交由服务层过滤', () {
      final playlist = PlaylistSummary.fromSearch({'specialname': '没有 ID 的歌单'});

      expect(playlist.id, '');
      // 不抛异常，仍能解析其余展示字段。
      expect(playlist.title, '没有 ID 的歌单');
    });

    test('specialname 为空时回落「未命名歌单」，nickname 缺失时为 null', () {
      final emptyName = PlaylistSummary.fromSearch({
        'gid': 'g1',
        'specialname': '   ',
      });
      expect(emptyName.title, '未命名歌单');
      expect(emptyName.subtitle, isNull);

      final missingName = PlaylistSummary.fromSearch({'gid': 'g2'});
      expect(missingName.title, '未命名歌单');
      expect(missingName.creatorName, isNull);
      expect(missingName.songCount, isNull);
      expect(missingName.playCount, isNull);
      expect(missingName.coverUrl, isNull);
    });

    test('搜索结果不会被 isCollectedAlbum 误判为收藏专辑', () {
      final playlist = PlaylistSummary.fromSearch({
        'gid': 'global-abc',
        'specialid': 123,
        'specialname': '普通歌单',
        'nickname': '创建者',
        'song_count': 12,
      });

      // 若误判为收藏专辑，详情页会走 /album/songs 分支导致歌曲列表为空。
      expect(playlist.isCollectedAlbum, isFalse);
      expect(playlist.albumId, isNull);
      expect(playlist.canDeleteOrUncollect, isFalse);
    });

    test('数值字段兼容 int 与字符串两种声明类型', () {
      final fromStrings = PlaylistSummary.fromSearch({
        'gid': 'g1',
        'song_count': '3',
        'total_play_count': '10086',
      });
      expect(fromStrings.songCount, 3);
      expect(fromStrings.playCount, 10086);

      final fromInts = PlaylistSummary.fromSearch({
        'gid': 'g2',
        'song_count': 7,
        'total_play_count': 42,
      });
      expect(fromInts.songCount, 7);
      expect(fromInts.playCount, 42);
    });
  });
}
