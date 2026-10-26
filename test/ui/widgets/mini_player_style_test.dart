// 迷你播放条与首页悬浮底栏同一套胶囊视觉（issue #6-2 / 精致化）：
// 圆角 32（= 胶囊端，与底栏同源 AppRadius.pill）、左右外距 24
// （AppSpacing.xl，与底栏一致）、内容横向内缩 16 躲开端部圆弧、进度条
// 横向内缩 24 避免底边圆弧斜切；精致化后条体 58+2 描边=60 高、封面 40、
// 标题 14/w700、副标题 12/w500、图标 26/24。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/design_tokens.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';
import 'package:shiyin_music/ui/widgets/marquee_text.dart';
import 'package:shiyin_music/ui/widgets/mini_player.dart';

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
  List<Song> queue = [];

  @override
  bool isPlaying = false;

  @override
  bool isPreparing = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = const Duration(minutes: 4);

  @override
  String? errorMessage;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  @override
  Future<void> togglePlay() async {
    isPlaying = !isPlaying;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _song = Song(
  id: 'song_1',
  title: '测试歌曲',
  artist: '测试歌手',
  hash: 'hash_1',
);

void main() {
  testWidgets('迷你播放条使用与底栏同源的胶囊圆角/边距', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final player = _FakePlayerController()..currentSong = _song;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MiniPlayer(player: player, auth: _FakeAuthController()),
          ),
        ),
      ),
    );
    await tester.pump();

    final pillRadius = BorderRadius.circular(AppRadius.pill);
    final containers = tester.widgetList<Container>(
      find.descendant(
        of: find.byType(MiniPlayer),
        matching: find.byType(Container),
      ),
    );
    final card = containers.firstWhere(
      (container) =>
          container.decoration is BoxDecoration &&
          (container.decoration! as BoxDecoration).borderRadius == pillRadius,
    );

    final clips = tester.widgetList<ClipRRect>(
      find.descendant(
        of: find.byType(MiniPlayer),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(
      clips.any((clip) => clip.borderRadius == pillRadius),
      isTrue,
      reason: '卡片与内部水波纹裁切必须是同一圆角，否则点击波纹会错位',
    );

    final cardSize = tester.getSize(find.byWidget(card));
    // 主体 58 + 上下各 1px 描边（Container 会把 border 宽度计入内 padding）。
    expect(cardSize.height, 60);
    expect(cardSize.width, closeTo(400 - AppSpacing.xl * 2, 0.5));

    // 精致化尺寸：封面 40/8 圆角、标题 14/w700、副标题 12/w500、图标 26。
    final artwork = tester.widget<Artwork>(find.byType(Artwork).first);
    expect(artwork.size, 40);
    expect(artwork.borderRadius, 8);
    final title = tester.widget<MarqueeText>(find.byType(MarqueeText).first);
    expect(title.style?.fontSize, 14);
    expect(title.style?.fontWeight, FontWeight.w700);
    final artist = tester.widget<Text>(find.text('测试歌手'));
    expect(artist.style?.fontSize, 12);
    expect(artist.style?.fontWeight, FontWeight.w500);
    expect(
      tester
          .widgetList<Icon>(find.byIcon(Icons.play_arrow_rounded))
          .single
          .size,
      26,
    );

    // 进度条两端内缩 AppSpacing.xl（外加 1px 描边），避开底边圆弧裁切。
    final cardRect = tester.getRect(find.byWidget(card));
    final progressRect = tester.getRect(find.byType(LinearProgressIndicator));
    expect(
      progressRect.left,
      closeTo(cardRect.left + 1 + AppSpacing.xl, 0.5),
    );
    expect(
      progressRect.right,
      closeTo(cardRect.right - 1 - AppSpacing.xl, 0.5),
    );

    // 窄屏（320dp）不出现溢出：内容内缩后文本区靠 Marquee 自适应。
    tester.view.physicalSize = const Size(320, 800);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放错误占用副标题槽位：胶囊不增高、窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final player = _FakePlayerController()
      ..currentSong = _song
      ..errorMessage = '该歌曲需要 VIP 才能播放';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MiniPlayer(player: player, auth: _FakeAuthController()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('该歌曲需要 VIP 才能播放'), findsOneWidget);
    // 副标题槽位被错误文案占用（不再在进度条下方堆第三行）。
    expect(find.text('测试歌手'), findsNothing);

    final pillRadius = BorderRadius.circular(AppRadius.pill);
    final card = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(MiniPlayer),
            matching: find.byType(Container),
          ),
        )
        .firstWhere(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).borderRadius ==
                  pillRadius,
        );
    expect(tester.getSize(find.byWidget(card)).height, 60);
    expect(tester.takeException(), isNull);
  });
}
