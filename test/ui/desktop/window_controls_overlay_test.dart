import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/desktop/desktop_window_controls.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/login_page.dart';
import 'package:shiyin_music/ui/pages/player_page.dart';

class _FakeMusicApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  /// PlayerPage 的 KEEP_SCREEN_ON 门控会读写这两个成员。
  @override
  bool keepScreenOnEnabled = true;

  @override
  bool isPlaying = false;

  @override
  Future<void> setKeepScreenOnEnabled(bool enabled) async {
    keepScreenOnEnabled = enabled;
    notifyListeners();
  }

  @override
  Song? currentSong;

  @override
  List<Song> queue = const [];

  @override
  Duration duration = Duration.zero;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isRestoring = false;
  @override
  bool get isLoggedIn => false;
  @override
  String? errorMessage;
  @override
  bool isLoading = false;
  @override
  bool isLiked(Song song) => false;
  @override
  Future<void> toggleLike(Song song) async {}
  @override
  List<PlaylistSummary> get createdPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedAlbums => const [];
  @override
  PlaylistSummary? get likedPlaylist => null;
  @override
  int get likedCount => 0;
  @override
  UserProfile? get profile => null;
  @override
  UserVipInfo? get vipInfo => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 拦截 window_manager 平台通道，记录调用到的原生方法名。
///
/// 浮层的按钮/拖拽最终都落到这个通道（close/minimize/maximize/
/// startDragging...），按钮「点得着」只能通过通道调用被触发来验证。
/// isMaximized 的返回值会被直接当 bool 使用、startDragging 在
/// Windows 上先查 isFullScreen，两者必须应答 false。
List<String> stubWindowManagerChannel(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (call) async {
      calls.add(call.method);
      if (call.method == 'isMaximized' || call.method == 'isFullScreen') {
        return false;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    ),
  );
  return calls;
}

void main() {
  testWidgets('桌面形态登录页叠加窗口控制浮层，移动端不叠加', (tester) async {
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginPage(auth: _FakeAuthController(), api: _FakeMusicApi()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 无边框窗口没有系统标题栏，登录页必须自带拖拽条 + 窗口三键，
    // 否则窗口拖不动也关不掉。
    expect(find.byType(DesktopWindowControlsOverlay), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.byTooltip('最小化'), findsOneWidget);

    // 移动端形态不叠加（有系统状态栏/导航，无需窗口控制）。
    debugDesktopFormFactorOverride = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginPage(auth: _FakeAuthController(), api: _FakeMusicApi()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopWindowControlsOverlay), findsNothing);
  });

  // 回归：浮层曾被压在 SafeArea 内容层下面。Stack 靠后的 child 优先
  // 参与命中测试，而登录表单的 SingleChildScrollView 默认 opaque 命中，
  // 连顶部空白 padding 区的指针事件也整块吞掉——浮层看得见却点不着、
  // 拖不动。仅断言浮层「存在」抓不住这类回归，必须验证命中可达。
  testWidgets('登录页浮层在内容层之上：按钮可点、拖拽条可拖', (tester) async {
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);
    final calls = stubWindowManagerChannel(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginPage(auth: _FakeAuthController(), api: _FakeMusicApi()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 三个窗口控制按钮的点击要能到达 window_manager 通道。
    // 每次 tap 后泵过 300ms 双击窗口：DragToMoveArea 的双击识别器
    // 会把 tap 按在竞技场里，窗口关闭后按钮 onTap 才放行（触摸指针
    // 下如此；桌面鼠标点击无此竞争）。
    Future<void> tapCaption(String tooltip) async {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
    }

    await tapCaption('最小化');
    await tapCaption('最大化');
    await tapCaption('关闭');
    expect(calls, containsAll(<String>['minimize', 'maximize', 'close']));

    // 顶部按钮区以外的空白拖拽条，横向拖动应触发原生窗口拖拽
    final gesture = await tester.startGesture(const Offset(50, 20));
    await gesture.moveBy(const Offset(60, 0));
    await gesture.up();
    await tester.pump();
    expect(calls, contains('startDragging'));
    // 收尾泵过 300ms 双击窗口，清掉双击识别器留下的 pending timer
    await tester.pump(const Duration(milliseconds: 350));
  });

  testWidgets('桌面形态播放页（整屏路由）叠加窗口控制浮层', (tester) async {
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);
    final calls = stubWindowManagerChannel(tester);

    // 空态分支即可验证：浮层包在整个 PlayerPage 外层，与有无歌曲无关。
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          player: _FakePlayerController(),
          auth: _FakeAuthController(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopWindowControlsOverlay), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);

    // 浮层要真的点得着：关闭按钮点击到达 window_manager 通道
    // （tap 后泵过 300ms 双击窗口，见登录页交互测试的注释）
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(calls, contains('close'));

    debugDesktopFormFactorOverride = false;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          player: _FakePlayerController(),
          auth: _FakeAuthController(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopWindowControlsOverlay), findsNothing);
  });

  // 回归：关闭键曾漏传 iconColor，回落到主题 onSurfaceVariant（浅色主题下
  // 近黑），叠在播放页黑色背景上几乎看不见，三键里只有它「消失」。
  // 断言的是「三键同色」而非某个具体色值：浮层传入什么颜色就该渲染什么。
  testWidgets('播放页浮层三键同色：关闭键不再比相邻两键更暗', (tester) async {
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);
    stubWindowManagerChannel(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          player: _FakePlayerController(),
          auth: _FakeAuthController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Color iconColorOf(String tooltip) {
      return tester
          .widget<Icon>(
            find.descendant(
              of: find.byTooltip(tooltip),
              matching: find.byType(Icon),
            ),
          )
          .color!;
    }

    final minimize = iconColorOf('最小化');
    final maximize = iconColorOf('最大化');
    final close = iconColorOf('关闭');

    expect(minimize, Colors.white);
    expect(close, minimize);
    expect(close, maximize);
  });
}
