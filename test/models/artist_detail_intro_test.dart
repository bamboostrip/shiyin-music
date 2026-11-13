import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  group('ArtistDetail 简介解析', () {
    test('intro 是正文主体，long_intro 非空分段追加在后（不丢正文）', () {
      // 实测 /artist/detail?id=3520：intro 本身就是长文本，long_intro 是
      // [{content: …}] 补充分段（见 docs/upstream-sync/2026-11-10-upstream-nov5-triage.md §7）。
      // 旧实现「有分段就整段丢弃 intro」会把正文简介吞掉。
      final detail = ArtistDetail.fromJson({
        'author_name': '周杰伦',
        'intro': '周杰伦，华语流行男歌手。',
        'long_intro': [
          {'content': '补充段落。'},
        ],
      }, id: '3520');

      expect(detail.name, '周杰伦');
      expect(detail.introSections.length, 1);
      expect(detail.introText, '周杰伦，华语流行男歌手。\n\n补充段落。');
    });

    test('分段正文与 intro 重复时不重复输出', () {
      final detail = ArtistDetail.fromJson({
        'author_name': '某歌手',
        'intro': '同一段简介正文。',
        'long_intro': [
          {'title': '简介', 'content': '同一段简介正文。'},
        ],
      }, id: '4');

      expect(detail.introText, '同一段简介正文。');
    });

    test('只有标题、没有正文的分段整段跳过（不得输出孤立标题）', () {
      final detail = ArtistDetail.fromJson({
        'author_name': '某歌手',
        'intro': '正文简介。',
        'long_intro': [
          {'title': '荣誉记录', 'content': ''},
          {'title': '   ', 'content': '   '},
          {'title': '其他', 'content': '真正的补充内容。'},
        ],
      }, id: '5');

      expect(
        detail.introText,
        '正文简介。\n\n其他\n真正的补充内容。',
        reason: '空 content 的「荣誉记录」不能留下孤零零的标题',
      );
    });

    test('无 intro 时退回 long_intro 分段（带标题分段保留标题）', () {
      final detail = ArtistDetail.fromJson({
        'author_name': '某歌手',
        'long_intro': [
          {'title': '简介', 'content': '分段正文。'},
          {'title': '', 'content': '补充段落。'},
        ],
      }, id: '6');

      expect(detail.introText, '简介\n分段正文。\n\n补充段落。');
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
