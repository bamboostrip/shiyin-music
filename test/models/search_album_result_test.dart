import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

/// `SearchAlbumResult` 的字段契约测试。
///
/// 契约来源是仓库根目录的 `api.json`（KuGou Music API 网关 OpenAPI 文档）：
/// `/search/album` 返回 `SearchAlbumItem[]`，字段为
/// `albumid` / `albumname` / `singer` / `songcount` / `publish_time` /
/// `ostremark` / `img` / `status`。
///
/// 这里的用例专门锁住"歌手名取自 `singer`"这条——历史上只认
/// `singername`/`author_name`，而这两个字段在专辑搜索结果里并不存在，
/// 导致专辑 tab 的歌手名恒为空（上层是 `if (artistName.isNotEmpty)`，
/// 因此表现为静默不显示，不会报错）。
void main() {
  group('SearchAlbumResult.fromJson 字段契约', () {
    test('按 api.json 的 SearchAlbumItem 真实形状解析出全部展示字段', () {
      // 与 api.json:10145 SearchAlbumItem 的字段一一对应，取真实取值类型：
      // albumid 可为整数（int64），songcount 亦可为字符串。
      final album = SearchAlbumResult.fromJson({
        'albumid': 123456789,
        'albumname': '范特西',
        'singer': '周杰伦',
        'songcount': '10',
        'publish_time': '2001-09-14',
        'ostremark': '',
        'img': 'https://imge.kugou.com/album/{size}/abc.jpg',
        'status': 0,
      });

      expect(album.albumId, '123456789');
      expect(album.albumName, '范特西');
      // 回归点：歌手名必须来自 `singer`。
      expect(album.artistName, '周杰伦');
      expect(album.songCount, 10);
      // `{size}` 占位符应被归一化成具体尺寸，否则是死链。
      expect(album.coverUrl, contains('/480/'));
      expect(album.coverUrl, isNot(contains('{size}')));
    });

    test('albumid 为字符串时同样解析（网关声明 int|string 双类型）', () {
      final album = SearchAlbumResult.fromJson({
        'albumid': '99887766',
        'albumname': '叶惠美',
        'singer': '周杰伦',
      });

      expect(album.albumId, '99887766');
      expect(album.artistName, '周杰伦');
    });

    test('保留 singername / author_name 兜底，兼容其他专辑来源', () {
      expect(
        SearchAlbumResult.fromJson({'albumid': '1', 'singername': 'A'}).artistName,
        'A',
      );
      expect(
        SearchAlbumResult.fromJson({'albumid': '1', 'author_name': 'B'})
            .artistName,
        'B',
      );
      expect(
        SearchAlbumResult.fromJson({'albumid': '1', 'singer_name': 'C'})
            .artistName,
        'C',
      );
      // `singer` 优先于其他候选（真实契约字段）。
      expect(
        SearchAlbumResult.fromJson({
          'albumid': '1',
          'singer': '真实',
          'singername': '兜底',
        }).artistName,
        '真实',
      );
    });

    test('字段缺失时不抛异常，给出稳定的默认值', () {
      final album = SearchAlbumResult.fromJson(const {});

      expect(album.albumId, '');
      expect(album.albumName, '未知专辑');
      expect(album.artistName, '');
      expect(album.coverUrl, isNull);
      expect(album.songCount, 0);
    });

    test('albumId 为空是调用方的过滤条件（专辑 tab 靠它判空）', () {
      // searchAlbums 用 `albumId.isNotEmpty` 过滤；这里锁住解析侧不会
      // 把非空 id 误判为空，否则整页专辑会被静默丢光（上游 cb3a039f 的
      // 同类症状）。
      final album = SearchAlbumResult.fromJson({'albumid': '0'});
      expect(album.albumId, '0');
      expect(album.albumId.isNotEmpty, isTrue);
    });
  });
}
