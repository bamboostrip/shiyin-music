import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/search_page.dart';

class _FakeMusicApi implements MusicApi {
  @override
  Future<List<SearchHotCategory>> searchHotKeywords() async => _categories;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// 7 字长名：9 个胶囊总宽远超 390 逻辑宽（轨道内容区约 320px），第 3 个
// 胶囊起初始就被截在轨道外——正是「切榜后选中胶囊看不见」的复现前提。
const _categoryNames = [
  '热搜榜分类第零',
  '飙升榜分类第一',
  'DJ榜分类第二',
  '外语热搜分类第三',
  '找歌词分类第四',
  '热搜榜分类第五',
  '飙升榜分类第六',
  'DJ榜分类第七',
  '外语热搜分类第八',
];

final _categories = [
  for (var i = 0; i < _categoryNames.length; i++)
    SearchHotCategory(
      name: _categoryNames[i],
      keywords: [
        for (var j = 0; j < 4; j++)
          SearchHotKeyword(keyword: '分类$i词$j'),
      ],
    ),
];

Rect _pillRect(WidgetTester tester, String label) {
  final pill = find
      .ancestor(of: find.text(label), matching: find.byType(AnimatedContainer))
      .first;
  final box = tester.renderObject<RenderBox>(pill);
  return box.localToGlobal(Offset.zero) & box.size;
}

void main() {
  setUp(() {
    debugDesktopFormFactorOverride = false;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget buildSubject() {
    return MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: SearchPage(
          api: _FakeMusicApi(),
          auth: _FakeAuthController(),
          player: _FakePlayerController(),
        ),
      ),
    );
  }

  // 真实画布设为 390×844（dpr 1）：布局宽度跟画布走，默认 800×600 的
  // 测试画布下 tab 条放得下 6 个胶囊，复现不了截断。
  Future<void> pumpSubject(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();
  }

  group('热搜面板切榜后选中胶囊滚入 tab 条视野', () {
    testWidgets('箭头连翻到第 5 榜：选中胶囊完全可见', (tester) async {
      await pumpSubject(tester);

      // 前置：第 5 个胶囊初始被截在屏幕外（问题真实存在，非平凡通过）。
      expect(_pillRect(tester, _categoryNames[4]).right, greaterThan(390));

      final next = find.byIcon(Icons.chevron_right_rounded);
      for (var i = 0; i < 4; i++) {
        await tester.tap(next);
        await tester.pumpAndSettle();
      }
      expect(find.text('5 / 9'), findsOneWidget);

      final rect = _pillRect(tester, _categoryNames[4]);
      expect(rect.left, greaterThanOrEqualTo(-.5));
      expect(rect.right, lessThanOrEqualTo(390.5));
    });

    testWidgets('横滑榜单区翻到第 3 榜：选中胶囊同样完全可见', (tester) async {
      await pumpSubject(tester);

      expect(_pillRect(tester, _categoryNames[2]).right, greaterThan(390));

      await tester.drag(find.text('分类0词0'), const Offset(-360, 0));
      await tester.pumpAndSettle();
      await tester.drag(find.text('分类1词0'), const Offset(-360, 0));
      await tester.pumpAndSettle();
      expect(find.text('3 / 9'), findsOneWidget);

      final rect = _pillRect(tester, _categoryNames[2]);
      expect(rect.left, greaterThanOrEqualTo(-.5));
      expect(rect.right, lessThanOrEqualTo(390.5));
    });

    testWidgets('切到已在视野内的相邻榜：tab 条不滚动（无多余抖动）', (tester) async {
      await pumpSubject(tester);

      // 只比左缘：pill0 点击前是选中态（字重宽），点击后变窄，宽度本身
      // 会变；左缘 = 轨道原点 + 滚动偏移，不动即未滚动。
      final beforeLeft = _pillRect(tester, _categoryNames[0]).left;
      await tester.tap(find.text(_categoryNames[1]));
      await tester.pumpAndSettle();

      expect(_pillRect(tester, _categoryNames[0]).left, beforeLeft);
    });
  });
}
