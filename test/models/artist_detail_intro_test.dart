import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  group('ArtistDetail 简介解析', () {
    test('long_intro 分段优先，拼成完整简介', () {
      final detail = ArtistDetail.fromJson({
        'author_name': '周杰伦',
        'intro': '短简介（应被 long_intro 覆盖）',
        'long_intro': [
          {'title': '简介', 'content': '周杰伦，华语流行男歌手。'},
          {'title': '', 'content': '补充段落。'},
        ],
      }, id: '3520');

      expect(detail.name, '周杰伦');
      expect(detail.intro, '短简介（应被 long_intro 覆盖）');
      expect(detail.introSections.length, 2);
      expect(detail.introText, '简介\n周杰伦，华语流行男歌手。\n\n补充段落。');
    });

    test('无 long_intro 时退回 intro', () {
      final detail = ArtistDetail.fromJson({
        'author_name': '某歌手',
        'intro': '  只有短简介  ',
      }, id: '1');

      expect(detail.introSections, isEmpty);
      expect(detail.introText, '只有短简介');
    });

    test('字段缺失/空串时安全降级', () {
      final detail = ArtistDetail.fromJson({'author_name': '歌手'}, id: '2');
      expect(detail.intro, isNull);
      expect(detail.introText, isEmpty);

      final withEmpty = ArtistDetail.fromJson({
        'author_name': '歌手',
        'intro': '   ',
        'long_intro': [
          {'title': '', 'content': ''},
        ],
      }, id: '3');
      expect(withEmpty.introText, isEmpty);
    });
  });
}
