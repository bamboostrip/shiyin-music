// 搜索页联想视图回归：
//   1. 输入未提交时展示联想列表（首行「搜索 <关键词>」+ 命中高亮）；
//   2. 提交后展示结果；改词未提交不再显示上一轮结果，回到联想；
//   3. 右上角按钮有输入时「搜索」、清空后「取消」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/app_theme.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/search_page.dart';

class _FakeApi implements MusicApi {
  int searchCalls = 0;

  @override
  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    searchCalls++;
    return [
      Song(
        id: 'id-$keywords',
        title: '结果-$keywords',
        artist: '测试歌手',
        hash: 'hash-$keywords',
        duration: const Duration(seconds: 100),
      ),
    ];
  }

  @override
  Future<List<String>> searchSuggest(String keywords) async =>
      ['$keywords 告白气球'];

  @override
  Future<List<SearchHotCategory>> searchHotKeywords() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  bool isPersonalFmActive = false;
  @override
  bool isLoadingPersonalFm = false;
  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;
  @override
  Song? get currentSong => null;
  @override
  bool get isPlaying => false;
  @override
  bool get isPreparing => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => Duration.zero;
  @override
  bool get searchPlayReplaceQueue => false;
  @override
  DownloadController? get downloadController => null;
  @override
  final ValueNotifier<Duration> positionListenable = ValueNotifier(
    Duration.zero,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool get isLoggedIn => false;
  @override
  bool isLiked(Song song) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('联想首行/高亮、提交后结果、改词回落联想、按钮切换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      debugDesktopFormFactorOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final api = _FakeApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: SearchPage(
          api: api,
          auth: _FakeAuthController(),
          player: _FakePlayerController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1) 输入未提交：联想列表 + 首行「搜索 <kw>」
    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('搜索 周杰伦'), findsOneWidget);
    expect(find.text('周杰伦 告白气球'), findsOneWidget);

    // 命中片段被拆成多个 span（高亮）
    final suggestionWidget = tester.widget<Text>(find.text('周杰伦 告白气球'));
    final span = suggestionWidget.textSpan! as TextSpan;
    expect(span.children, isNotNull);
    expect(span.children!.length, greaterThanOrEqualTo(2));

    // 有输入时按钮是「搜索」
    expect(find.widgetWithText(TextButton, '搜索'), findsOneWidget);

    // 2) 提交后展示结果
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('结果-周杰伦'), findsWidgets);
    expect(find.text('搜索 周杰伦'), findsNothing);

    // 3) 改词未提交：旧结果不再显示，回到联想视图
    await tester.enterText(find.byType(TextField), '林俊杰');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('结果-周杰伦'), findsNothing);
    expect(find.text('搜索 林俊杰'), findsOneWidget);
    expect(find.text('林俊杰 告白气球'), findsOneWidget);

    // 4) 清空后按钮变回「取消」
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
  });
}
