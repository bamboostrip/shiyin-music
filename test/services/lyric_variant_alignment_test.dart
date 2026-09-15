import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/music_api.dart';

void main() {
  group('KRC 译/音变体轨与主歌词对齐', () {
    /// 复现实测粤语歌的变体轨结构：
    /// - 主歌词：2 行带英文尾巴的 Credits + 6 行歌词（开头段重复出现）；
    /// - 音译轨（type 0）：与主歌词 1:1（Credits 也有粤拼）；
    /// - 谐音轨（type 1）：自带“以下谐音标注由AI工具生产”声明头，且
    ///   完全没有 Credits 行 —— 行数比主歌词少，旧固定偏移逻辑必然错位。
    final krc = _buildKrc(
      mainLines: const [
        '出品：鲸鱼向海@S.A.G',
        '混音：王晨雨@S.A.G /Vhypher',
        '缠绵的晚风 吹熄爱的梦',
        '为何love is gone gone gone',
        '全部散在幽幽半空',
        '缠绵的晚风 吹熄爱的梦',
        '为何love is gone gone gone',
        '全部散在幽幽半空',
      ],
      romanization: const [
        'coetban：kingyuhoenghoi@s.a.g',
        'wanjam：wongsanyu@s.a.g/vhypher',
        'cinmindikmanfongceoisikoidikmong',
        'waiholoveisgongongong',
        'cyunbousanzaijauyaubunhung',
        'cinmindikmanfongceoisikoidikmong',
        'waiholoveisgongongong',
        'cyunbousanzaijauyaubunhung',
      ],
      translation: const [
        '以下谐音标注由AI工具生产',
        '情 悯 滴 曼 风 崔 斯 爱 滴 梦',
        '歪 吼 love is gone gone gone',
        '群 卜 散 在 要 要 羌 虹',
        '情 悯 滴 曼 风 崔 斯 爱 滴 梦',
        '歪 吼 love is gone gone gone',
        '群 卜 散 在 要 要 羌 虹',
      ],
    );

    final lines = parseLyrics(krc);

    test('解析出全部主歌词行且顺序正确', () {
      expect(lines.length, 8);
      expect(lines[2].text, '缠绵的晚风 吹熄爱的梦');
      expect(lines[3].text, '为何love is gone gone gone');
      expect(lines[7].text, '全部散在幽幽半空');
    });

    test('谐音（译）与所属歌词行一一对应，不受声明头/Credits 行数差影响', () {
      // Credits 行在谐音轨中没有对应内容
      expect(lines[0].translation, isNull);
      expect(lines[1].translation, isNull);
      // 歌词行各配各的谐音
      expect(lines[2].translation, '情 悯 滴 曼 风 崔 斯 爱 滴 梦');
      expect(lines[3].translation, '歪 吼 love is gone gone gone');
      expect(lines[4].translation, '群 卜 散 在 要 要 羌 虹');
      // 重复出现的段落同样对上
      expect(lines[5].translation, '情 悯 滴 曼 风 崔 斯 爱 滴 梦');
      expect(lines[6].translation, '歪 吼 love is gone gone gone');
      expect(lines[7].translation, '群 卜 散 在 要 要 羌 虹');
      // 声明头不应成为任何一行的“翻译”
      for (final line in lines) {
        expect(line.translation ?? '', isNot(contains('谐音标注')));
      }
    });

    test('音译（粤拼）与所属歌词行一一对应', () {
      expect(lines[0].romanization, 'coetban：kingyuhoenghoi@s.a.g');
      expect(lines[1].romanization, 'wanjam：wongsanyu@s.a.g/vhypher');
      expect(lines[3].romanization, 'waiholoveisgongongong');
      expect(lines[7].romanization, 'cyunbousanzaijauyaubunhung');
    });
  });

  group('纯英文行无谐音条目时空档落在英文行上', () {
    /// 复刻实测粤语歌的残余错位：谐音/粤拼轨对纯英文行（无汉字可转写）
    /// 不生成条目，对齐必须把空档放在英文行上，而不是推移前后行。
    final krc = _buildKrc(
      mainLines: const [
        '出品：鲸鱼向海@S.A.G',
        '缠绵的晚风 吹熄爱的梦',
        '为何love is gone gone gone',
        '全部散在幽幽半空',
        '霓虹照亮痛 唤不到心动',
        'Just leave me alone alone alone',
        '留下我在记忆里沉重',
        '爱令我沉重 想你懂',
      ],
      romanization: const [
        'coetban：kingyuhoenghoi@s.a.g',
        'cinmindikmanfongceoisikoidikmong',
        'waiholoveisgonegonegone',
        'cyunbousanzoiyouyoubunhong',
        'aihongziuloengtongwunbeddousamdong',
        'louhaozoigeiyileoicemzong',
        'oilingocemzongsoengneidong',
      ],
      translation: const [
        '以下谐音标注由AI工具生产',
        '情 悯 滴 曼 风 崔 斯 爱 滴 梦',
        '歪 吼 love is gone gone gone',
        '群 卜 散 在 要 要 笨 虹',
        '唉 虹 就 郎 痛 问 吧 斗 散 动',
        '老 哈 哦 在 给 忆 勒 灿 匆',
        '爱 令 哦 灿 匆 桑 内 懂',
      ],
    );

    test('空档落在纯英文行，其余一一对应', () {
      final lines = parseLyrics(krc);
      expect(lines.length, 8);
      // 纯英文行：谐音/粤拼轨均无条目
      expect(lines[5].text, 'Just leave me alone alone alone');
      expect(lines[5].translation, isNull);
      expect(lines[5].romanization, isNull);
      // 前后各行各配各的
      expect(lines[3].translation, '群 卜 散 在 要 要 笨 虹');
      expect(lines[4].translation, '唉 虹 就 郎 痛 问 吧 斗 散 动');
      expect(lines[6].translation, '老 哈 哦 在 给 忆 勒 灿 匆');
      expect(lines[7].translation, '爱 令 哦 灿 匆 桑 内 懂');
      expect(lines[4].romanization, 'aihongziuloengtongwunbeddousamdong');
      expect(lines[6].romanization, 'louhaozoigeiyileoicemzong');
    });
  });

  group('英文歌翻译轨（版权头 + 空占位）', () {
    /// 结构 1（真实 Because of You 数据结构）：
    /// 酷狗翻译轨总长度与主歌词严格 1:1，第 0 槽（对应标题行）填入
    /// "腾讯享有本翻译作品的著作权"，中间空串对应 Credits 与 Ooh 段。
    /// 此时不得因剔除版权头而导致数组长度缩水、后续行全部前移错位。
    test('版权头占第 0 槽（原始 1:1）：版权头不作为翻译显示，后续行严格对齐', () {
      final krc = _buildKrc(
        mainLines: const [
          'Because of You - Kelly Clarkson',
          'Lyrics by：Kelly Clarkson/David Hodges',
          'Ooh ooh ooh',
          'Ooh ooh ooh ooh ooh',
          'I will not make the same mistakes that you did',
          'I will not let myself cause my heart so much misery',
          'Because of you',
          'I never stray too far from the sidewalk',
          'Because of you',
          'Because of you mmh ooh',
        ],
        translation: const [
          '腾讯享有本翻译作品的著作权',
          '',
          '',
          '',
          '我不会重蹈你的覆辙',
          '也不会让内心如此痛苦',
          '因为你',
          '我从不偏离轨道半分',
          '因为你',
          '因为你',
        ],
      );
      final lines = parseLyrics(krc);
      expect(lines.length, 10);
      expect(lines[0].translation, isNull);
      expect(lines[1].translation, isNull);
      expect(lines[2].translation, isNull);
      expect(lines[3].translation, isNull);
      expect(lines[4].translation, '我不会重蹈你的覆辙');
      expect(lines[5].translation, '也不会让内心如此痛苦');
      expect(lines[6].translation, '因为你');
      expect(lines[7].translation, '我从不偏离轨道半分');
      expect(lines[8].translation, '因为你');
      expect(lines[9].translation, '因为你');
    });

    /// 结构 2（额外插入版权行）：
    /// 翻译轨比主歌词多一行（插入了版权头），剔除版权头后与主歌词等长。
    test('版权头为额外插入行：剔除后空占位精确 1:1 对齐', () {
      final krc = _buildKrc(
        mainLines: const [
          'Because of You - Kelly Clarkson',
          'Lyrics by：Kelly Clarkson/David Hodges',
          'Ooh ooh ooh',
          'Ooh ooh ooh ooh ooh',
          'I will not make the same mistakes that you did',
          'I will not let myself cause my heart so much misery',
          'Because of you',
          'I never stray too far from the sidewalk',
          'Because of you',
          'Because of you mmh ooh',
        ],
        translation: const [
          '',
          '',
          '',
          '',
          '腾讯享有本翻译作品的著作权',
          '我不会重蹈你的覆辙',
          '也不会让内心如此痛苦',
          '因为你',
          '我从不偏离轨道半分',
          '因为你',
          '因为你',
        ],
      );
      final lines = parseLyrics(krc);
      expect(lines.length, 10);
      for (var i = 0; i < 4; i++) {
        expect(lines[i].translation, isNull, reason: 'line#$i');
      }
      expect(lines[4].translation, '我不会重蹈你的覆辙');
      expect(lines[5].translation, '也不会让内心如此痛苦');
      expect(lines[6].translation, '因为你');
      expect(lines[7].translation, '我从不偏离轨道半分');
      expect(lines[8].translation, '因为你');
      expect(lines[9].translation, '因为你');
      for (final line in lines) {
        expect(line.translation ?? '', isNot(contains('著作权')));
      }
    });
  });

  group('无锚点时保持旧的按序对齐', () {
    test('纯中文等长翻译轨仍按索引一一对应', () {
      final krc = _buildKrc(
        mainLines: const ['第一句歌词', '第二句歌词', '第三句歌词'],
        translation: const ['翻译一', '翻译二', '翻译三'],
      );
      final lines = parseLyrics(krc);
      expect(lines[0].translation, '翻译一');
      expect(lines[1].translation, '翻译二');
      expect(lines[2].translation, '翻译三');
    });
  });
}

/// 构造带 [language:] 变体标签的 KRC 文本。
String _buildKrc({
  required List<String> mainLines,
  List<String>? translation,
  List<String>? romanization,
}) {
  final buffer = StringBuffer();
  for (var i = 0; i < mainLines.length; i++) {
    buffer.writeln('[${1000 + i * 3000},2000]${mainLines[i]}');
  }
  final content = <Map<String, Object?>>[
    if (romanization != null)
      {
        'type': 0,
        'lyricContent': [for (final row in romanization) [row]],
      },
    if (translation != null)
      {
        'type': 1,
        'lyricContent': [for (final row in translation) [row]],
      },
  ];
  if (content.isNotEmpty) {
    final encoded = base64.encode(utf8.encode(jsonEncode({'content': content})));
    buffer.writeln('[language:$encoded]');
  }
  return buffer.toString();
}
