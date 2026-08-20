import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  group('ArtistAlbum.fromJson 封面取值', () {
    test('上游 /artist/albums 实际结构：cover 仅为文件名，应优先取 sizable_cover 完整 URL', () {
      // 抓自真实响应（周杰伦 author_id=3520）：
      // cover 是裸文件名，sizable_cover 才是可加载的完整 URL。
      final album = ArtistAlbum.fromJson({
        'album_id': 179652761,
        'album_name': '太阳之子',
        'author_name': '周杰伦',
        'cover': '20260319101420611881.jpg',
        'sizable_cover':
            'http://imge.kugou.com/stdmusic/400/20260319/20260319101420611881.jpg',
        'publish_date': '2026-03-25',
      });

      expect(album.id, '179652761');
      expect(album.name, '太阳之子');
      expect(
        album.coverUrl,
        'http://imge.kugou.com/stdmusic/400/20260319/20260319101420611881.jpg',
        reason: 'cover 字段只是文件名不是 URL，必须优先使用 sizable_cover',
      );
    });

    test('仅返回带 {size} 占位符的 sizable_cover 时应替换为具体尺寸', () {
      final album = ArtistAlbum.fromJson({
        'album_id': 1,
        'album_name': 'demo',
        'sizable_cover':
            'http://imge.kugou.com/stdmusic/{size}/20260319/20260319101420611881.jpg',
      });

      expect(
        album.coverUrl,
        'http://imge.kugou.com/stdmusic/480/20260319/20260319101420611881.jpg',
      );
    });

    test('仅有 cover 且为完整 URL 时仍可使用', () {
      final album = ArtistAlbum.fromJson({
        'album_id': 2,
        'album_name': 'demo2',
        'cover': 'http://imge.kugou.com/stdmusic/400/a.jpg',
      });

      expect(album.coverUrl, 'http://imge.kugou.com/stdmusic/400/a.jpg');
    });
  });
}
