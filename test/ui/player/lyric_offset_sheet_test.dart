// 「调整歌词进度」UI：移动端详情弹层入口与底部弹层、PC 锚定弹层、
// PC 两个入口（封面开关列 `调` / 歌词列表右键）。
//
// 面板形态对齐倍速 / 定时弹层：大读数 + `− 0.5 秒` / `+ 0.5 秒` 步进键 +
// `恢复原始进度` 文字按钮 + 偏移状态说明；状态与重置可用态自监听 PlayerController。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/player_logic.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/player/desktop_lyric_list.dart';
import 'package:shiyin_music/ui/player/landscape_player.dart';
import 'package:shiyin_music/ui/player/lyric_display_mode.dart';
import 'package:shiyin_music/ui/player/lyric_offset_sheet.dart';
import 'package:shiyin_music/ui/player/player_top_bar.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Duration lyricOffset = Duration.zero;

  int adjustCalls = 0;
  int resetCalls = 0;
  final ValueNotifier<Duration> _positionListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  @override
  bool isPlaying = false;

  @override
  bool get isScrubbing => false;

  @override
  bool get isPreparing => false;

  @override
  Duration get smoothPosition => _positionListenable.value;

  @override
  Duration get lyricPosition => smoothPosition + lyricOffset;

  @override
  ValueNotifier<Duration> get positionListenable => _positionListenable;

  @override
  List<LyricLine> lyrics = const [
    LyricLine(time: Duration.zero, text: '第一句'),
    LyricLine(time: Duration(seconds: 5), text: '第二句'),
  ];

  @override
  int get activeLyricIndex => 0;

  @override
  Song? currentSong = const Song(
    id: 's1',
    hash: 'h1',
    title: '单身情歌',
    artist: '林志炫',
  );

  @override
  bool get hasLyricOffset => lyricOffset != Duration.zero;

  @override
  String get lyricOffsetLabel => PlayerLyricOffsetLogic.describe(lyricOffset);

  @override
  Future<void> adjustLyricOffset(Duration delta) async {
    adjustCalls++;
    lyricOffset += delta;
    notifyListeners();
  }

  @override
  Future<void> resetLyricOffset() async {
    resetCalls++;
    lyricOffset = Duration.zero;
    notifyListeners();
  }

  @override
  Future<void> seekToAndPlay(Duration position) async {}

  // 详情弹层（showPlayerMoreSheet）构建时要读的档位标签。
  @override
  String get playbackSpeedLabel => '1x';

  @override
  AudioQuality get audioQuality => AudioQuality.standard;

  @override
  bool get isAudioEffectsSupported => false;

  @override
  bool get isDesktopLyricsSupported => false;

  @override
  bool get desktopLyricsEnabled => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 详情弹层只把 auth 透传给「添加到歌单」的点击回调，构建期不读它。
class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 弹层里三键的图标 → 稳定命中（`0.5 秒` 文案有两个）。
const _addIcon = Icons.add_rounded;
const _minusIcon = Icons.remove_rounded;
const _resetIcon = Icons.restart_alt_rounded;

void main() {
  group('LyricOffsetControl', () {
    testWidgets('步进键与状态文案：点按即改偏移并即时刷新读数', (tester) async {
      final player = _FakePlayerController();
      await tester.pumpWidget(_host(LyricOffsetControl(player: player)));

      expect(find.text('无偏移'), findsOneWidget);
      expect(
        find.text('「+」歌词提前 · 「−」歌词延后，长按可连续调整'),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(_addIcon));
      await tester.pump();
      expect(player.lyricOffset, kLyricOffsetStep);
      expect(player.adjustCalls, 1);
      expect(find.text('+0.5 秒'), findsOneWidget);
      expect(find.text('歌词提前 0.5 秒 · 已为本首歌记忆'), findsOneWidget);

      await tester.tap(find.byIcon(_addIcon));
      await tester.pump();
      expect(player.lyricOffset, const Duration(seconds: 1));
      expect(find.text('+1 秒'), findsOneWidget);
      expect(find.text('歌词提前 1 秒 · 已为本首歌记忆'), findsOneWidget);

      await tester.tap(find.byIcon(_minusIcon));
      await tester.pump();
      expect(player.lyricOffset, kLyricOffsetStep);

      await tester.tap(find.byIcon(_resetIcon));
      await tester.pump();
      expect(player.resetCalls, 1);
      expect(player.lyricOffset, Duration.zero);
      expect(find.text('无偏移'), findsOneWidget);
    });

    testWidgets('无偏移时重置不可用（点了也不触发 reset）', (tester) async {
      final player = _FakePlayerController();
      await tester.pumpWidget(_host(LyricOffsetControl(player: player)));

      await tester.tap(find.byIcon(_resetIcon));
      await tester.pump();
      expect(player.resetCalls, 0);
      expect(player.lyricOffset, Duration.zero);
    });
  });

  group('移动端详情弹层入口', () {
    testWidgets('详情里有「歌词进度」宫格项，点开即打开调整弹层并带出当前偏移', (tester) async {
      // 形态判定跟着宿主 OS 走（测试跑在 Windows 上恒为桌面），这里显式
      // 覆盖成移动形态，走的才是手机上的底部弹层分支。
      debugDesktopFormFactorOverride = false;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      final player = _FakePlayerController()
        // 已经调过的歌：详情项副标题直接显示当前偏移（"已调整"可见）。
        ..lyricOffset = kLyricOffsetStep;
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlayerMoreSheet(
                context: context,
                player: player,
                auth: auth,
                song: player.currentSong!,
              ),
              child: const Text('more'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('more'));
      await tester.pumpAndSettle();

      // 与倍速/音质同排的宫格入口，副标题带出当前偏移。
      expect(find.text('歌词进度'), findsOneWidget);
      expect(find.text('歌词提前 0.5 秒'), findsOneWidget);

      await tester.tap(find.text('歌词进度'));
      await tester.pumpAndSettle();

      // 详情弹层关闭（详情独有的「倍速」入口消失）、调整弹层打开，且是同一份状态。
      // 注意：底层页面仍在（「more」还在树里），只断言详情内容已走、弹层已来。
      expect(find.text('倍速'), findsNothing, reason: '详情弹层应已关闭');
      expect(find.text('调整歌词进度'), findsOneWidget);
      expect(find.text('歌词提前 0.5 秒 · 已为本首歌记忆'), findsOneWidget);

      await tester.tap(find.byIcon(_addIcon));
      await tester.pumpAndSettle();
      expect(player.lyricOffset, const Duration(seconds: 1));
      expect(find.text('歌词提前 1 秒 · 已为本首歌记忆'), findsOneWidget);
    });
  });

  group('showLyricOffsetSheet（移动端弹层）', () {
    testWidgets('标题、歌曲信息与步进键齐备，调整后状态同步', (tester) async {
      final player = _FakePlayerController();
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showLyricOffsetSheet(
                context,
                player: player,
                song: player.currentSong,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('调整歌词进度'), findsOneWidget);
      expect(find.text('林志炫 · 单身情歌'), findsOneWidget);
      expect(find.byIcon(_minusIcon), findsOneWidget);
      expect(find.byIcon(_resetIcon), findsOneWidget);
      expect(find.byIcon(_addIcon), findsOneWidget);
      expect(find.text('0.5 秒'), findsNWidgets(2));
      expect(find.text('恢复原始进度'), findsOneWidget);

      await tester.tap(find.byIcon(_addIcon));
      await tester.pumpAndSettle();
      expect(player.lyricOffset, kLyricOffsetStep);
      expect(find.text('歌词提前 0.5 秒 · 已为本首歌记忆'), findsOneWidget);
    });
  });

  group('showLyricOffsetMenu（PC 锚定弹层）', () {
    testWidgets('锚定面板标题「歌词进度」+ 步进键，调整即时生效', (tester) async {
      final player = _FakePlayerController();
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showLyricOffsetMenu(
                context,
                player: player,
                anchor: const Offset(240, 180),
              ),
              child: const Text('menu'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('menu'));
      await tester.pumpAndSettle();

      expect(find.text('歌词进度'), findsOneWidget);
      expect(find.byIcon(_addIcon), findsOneWidget);

      await tester.tap(find.byIcon(_minusIcon));
      await tester.pumpAndSettle();
      expect(player.lyricOffset, -kLyricOffsetStep);
      expect(find.text('歌词延后 0.5 秒 · 已为本首歌记忆'), findsOneWidget);
    });
  });

  group('PC 入口', () {
    testWidgets('封面开关列的 [调] 始终可见，点击回调带上按钮锚点', (tester) async {
      Offset? anchor;
      await tester.pumpWidget(
        _host(
          Center(
            child: LandscapeLyricToggleColumn(
              showTranslation: false,
              showRomanization: false,
              hasTranslation: false,
              hasRomanization: false,
              onToggleTranslation: (_) {},
              onToggleRomanization: (_) {},
              onOpenLyricOffset: (position) => anchor = position,
            ),
          ),
        ),
      );

      // 这首歌既没翻译也没音译，[调] 仍然必须渲染（它是功能入口不是状态开关）。
      expect(find.text('调'), findsOneWidget);
      expect(find.text('译'), findsNothing);

      await tester.tap(find.text('调'));
      await tester.pump();
      expect(anchor, isNotNull);
      expect(anchor!.dx.isFinite && anchor!.dy.isFinite, isTrue);
    });

    testWidgets('歌词列表右键在指针处打开进度面板', (tester) async {
      final player = _FakePlayerController();
      Offset? tappedAt;

      await tester.pumpWidget(
        _host(
          DesktopLyricList(
            player: player,
            songHash: 'h1',
            lyrics: player.lyrics,
            activeIndex: 0,
            displayMode: LyricDisplayMode.lyricsOnly,
            lyricScale: 1.0,
            onSecondaryTapLine: (position) => tappedAt = position,
          ),
        ),
      );
      await tester.pump();

      final target = tester.getCenter(find.text('第二句'));
      await tester.tap(find.text('第二句'), buttons: kSecondaryMouseButton);
      await tester.pump();

      expect(tappedAt, isNotNull);
      expect((tappedAt! - target).distance, lessThan(24));
    });
  });
}
