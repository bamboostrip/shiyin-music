import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/app_theme.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/search_page.dart';

class _FakeMusicApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 记录真正发出的搜索请求（默认曲目搜索），用来确认 IME 守卫没有误发搜索。
class _RecordingMusicApi extends _FakeMusicApi {
  final List<String> searchCalls = <String>[];

  @override
  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    searchCalls.add(keywords);
    return const <Song>[];
  }
}

/// 固定返回一组联想词，用来验证首行与联想词的去重。
class _SuggestingMusicApi extends _RecordingMusicApi {
  _SuggestingMusicApi(this.suggestions);

  final List<String> suggestions;

  @override
  Future<List<String>> searchSuggest(String keywords) async => suggestions;
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
  final ValueNotifier<Duration> positionListenable = ValueNotifier(Duration.zero);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool get isLoggedIn => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('移动端搜索页 input 文字垂直居中且不被裁切底部', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    final theme = ThemeController();
    await theme.setCarModeEnabled(false);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: SearchPage(
          api: _FakeMusicApi(),
          auth: _FakeAuthController(),
          player: _FakePlayerController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final textFieldFinder = find.byType(TextField);
    expect(textFieldFinder, findsOneWidget);

    // 1. 初始状态：text 为空，hintText 正常居中展示
    final iconFinder = find.byIcon(Icons.search_rounded);
    expect(iconFinder, findsOneWidget);
    final iconRect = tester.getRect(iconFinder);

    // issue #17：搜索页提示补「歌单」，四类搜索入口在空态即可见。
    final hintFinder = find.text('搜索歌曲、歌手、专辑、歌单');
    expect(hintFinder, findsOneWidget);
    final hintRect = tester.getRect(hintFinder);

    final containerFinder = find.ancestor(
      of: iconFinder,
      matching: find.byType(Container),
    ).first;
    final containerRect = tester.getRect(containerFinder);

    final inputDecoratorFinder = find.byType(InputDecorator);
    expect(inputDecoratorFinder, findsOneWidget);

    // 空态装饰器高度（空态保留后缀 32px 槽位，与输入态等高，
    // 使 textAlignVertical.center 在空态同样把光标行垂直居中）
    final emptyDecoratorHeight = tester.getSize(inputDecoratorFinder).height;

    final editableFinder = find.byWidgetPredicate((w) => w.runtimeType.toString() == 'EditableText');
    expect(editableFinder, findsOneWidget);
    final editableBox = tester.renderObject(editableFinder) as RenderBox;

    // 提示文案为叠放的普通 Text（不再走 InputDecorator.hintText）
    final hintRenderBox = tester.renderObject(hintFinder.first) as RenderBox;

    // 占位符与输入框基线完全对齐、高度一致
    final editableBaseline = editableBox.getDryBaseline(editableBox.constraints, TextBaseline.alphabetic);
    final hintBaseline = hintRenderBox.getDryBaseline(hintRenderBox.constraints, TextBaseline.alphabetic);
    expect((editableBaseline! - hintBaseline!).abs(), lessThan(0.5));
    expect(hintRenderBox.size.height, equals(editableBox.size.height));

    // hintText 与 icon 垂直中心必须与 36px 胶囊容器垂直中心居中对齐
    expect((hintRect.center.dy - containerRect.center.dy).abs(), lessThan(0.5));
    expect((iconRect.center.dy - containerRect.center.dy).abs(), lessThan(0.5));

    RenderEditable? renderEditable;
    void findRenderEditable(RenderObject ro) {
      if (ro is RenderEditable) {
        renderEditable = ro;
        return;
      }
      ro.visitChildren(findRenderEditable);
    }
    findRenderEditable(editableBox);

    expect(renderEditable, isNotNull);
    // RenderEditable 布局高度必须满足字体的 preferredLineHeight，不能被挤压裁切底部
    expect(renderEditable!.size.height, greaterThanOrEqualTo(renderEditable!.preferredLineHeight));

    // 2. 输入文字：检查 RenderEditable 完整展示，高度不被 contentPadding 挤压截断，且垂直居中
    await tester.enterText(textFieldFinder, '我的歌单gyjp');
    await tester.pumpAndSettle();

    final inputRect = tester.getRect(editableFinder);
    expect((inputRect.center.dy - containerRect.center.dy).abs(), lessThan(0.5));
    expect(renderEditable!.size.height, greaterThanOrEqualTo(renderEditable!.preferredLineHeight));

    // 输入态与空态装饰器近似等高（容差 2px：输入态多出聚焦描边）：
    // 高度接近才能让 textAlignVertical.center 在空态同样居中光标行
    final typedDecoratorHeight = tester.getSize(inputDecoratorFinder).height;
    expect(typedDecoratorHeight, closeTo(emptyDecoratorHeight, 2.0));

    // 3. 清除按钮测试
    final closeBtnFinder = find.byIcon(Icons.close_rounded);
    expect(closeBtnFinder, findsOneWidget);
    await tester.tap(closeBtnFinder);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(find.text('搜索歌曲、歌手、专辑、歌单'), findsOneWidget);

    // 4. 输入长文字测试
    await tester.enterText(textFieldFinder, '这是一段非常长非常长的搜索测试文字用于验证字体底部不被截断gyjp');
    await tester.pumpAndSettle();
    expect(renderEditable!.size.height, greaterThanOrEqualTo(renderEditable!.preferredLineHeight));
  });

  testWidgets('组词中的 Enter 不误发搜索；上屏后 Enter 才搜索', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    final api = _RecordingMusicApi();
    final theme = ThemeController();
    await theme.setCarModeEnabled(false);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    final field = tester.widget<TextField>(find.byType(TextField));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(field.focusNode!.hasFocus, isTrue);

    // 组词中：拼音进入 composing 区间。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    // 守卫必须拦在 onSubmitted 之前（composing 在 framework 里先被清空）。
    expect(
      api.searchCalls,
      isEmpty,
      reason: '组词中的回车是选词，不能把拼音当关键词搜出去',
    );
    expect(
      field.controller!.value.composing,
      const TextRange(start: 0, end: 5),
      reason: '守卫不得打断组词',
    );
    expect(field.focusNode!.hasFocus, isTrue, reason: '组词中不得失焦');

    // IME 上屏后再回车：正常搜索。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(api.searchCalls, <String>['你好']);
  });

  Future<void> pumpSearchPage(WidgetTester tester, MusicApi api) async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);
    final theme = ThemeController();
    await theme.setCarModeEnabled(false);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
  }

  testWidgets('联想请求失败/为空：首行「搜索 <词>」入口仍在，正文不空白', (tester) async {
    // _FakeMusicApi 的 searchSuggest 直接抛 NoSuchMethodError，等价于接口失败。
    final api = _RecordingMusicApi();
    await pumpSearchPage(tester, api);

    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(
      find.byType(ListView),
      findsOneWidget,
      reason: '联想失败也必须保留联想视图（首行搜索词），不能整块空白',
    );
    expect(find.byType(ListTile), findsOneWidget, reason: '只有首行「搜索 周杰伦」');
    expect(find.textContaining('周杰伦'), findsWidgets);
  });

  testWidgets('组词中点右上角「搜索」不误发；上屏后再点才搜索', (tester) async {
    final api = _RecordingMusicApi();
    await pumpSearchPage(tester, api);

    final field = tester.widget<TextField>(find.byType(TextField));
    await tester.tap(find.byType(TextField));
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhoujielun',
        selection: TextSelection.collapsed(offset: 10),
        composing: TextRange(start: 0, end: 10),
      ),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, '搜索'));
    await tester.pump();
    expect(
      api.searchCalls,
      isEmpty,
      reason: '组词中 controller.text 还是拼音原文，点按钮不得把拼音当关键词',
    );
    expect(field.focusNode!.hasFocus, isTrue, reason: '组词中不得失焦打断选字');

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '周杰伦',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '搜索'));
    await tester.pumpAndSettle();
    expect(api.searchCalls, <String>['周杰伦']);
  });

  testWidgets('联想里与输入词相同的项不与首行重复', (tester) async {
    final api = _SuggestingMusicApi(<String>['周杰伦', '周杰伦 告白气球']);
    await pumpSearchPage(tester, api);

    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(
      find.byType(ListTile),
      findsNWidgets(2),
      reason: '首行「搜索 周杰伦」+ 一条联想；与输入词重复的联想不再占一行',
    );
    expect(find.text('周杰伦 告白气球'), findsOneWidget);
  });

  testWidgets('组词期间改词触发页面重建（回落联想）：composing 与焦点都不丢', (tester) async {
    final api = _RecordingMusicApi();
    await pumpSearchPage(tester, api);

    // 先搜一次，让 _searched 成立：之后改词会走「不再展示上一轮结果 → 回落
    // 联想」的重建路径，覆盖新增的每次改词 setState 与 IME 组词的冲突面。
    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    await tester.tap(find.byType(TextField));
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhoujielun',
        selection: TextSelection.collapsed(offset: 10),
        composing: TextRange(start: 0, end: 10),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      field.controller!.value.composing,
      const TextRange(start: 0, end: 10),
      reason: '页面重建不得清掉 composing（否则候选框被打断）',
    );
    expect(field.focusNode!.hasFocus, isTrue);
  });
}