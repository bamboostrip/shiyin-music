// test/ui/widgets/queue_sheet_locate_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/widgets/queue_sheet.dart';

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
  List<Song> queue = const [];
  @override
  bool isPlaying = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(int n, {String? hash}) => Song(
      id: '$n',
      title: '测试歌曲$n',
      artist: '测试歌手',
      hash: hash ?? 'hash-$n',
      duration: const Duration(minutes: 3, seconds: 45),
    );

Future<void> _openSheet(WidgetTester tester, _FakePlayerController player) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (buttonContext) => IconButton(
              tooltip: '打开队列',
              onPressed: () => showQueueSheet(buttonContext, player),
              icon: const Icon(Icons.queue_music_rounded),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byTooltip('打开队列'));
  await tester.pumpAndSettle();
}

/// 队列面板 ListView 的滚动位置（弹层内唯一 ListView，controller 由定位器持有）。
ScrollPosition _sheetPosition(WidgetTester tester) {
  final listView = tester.widget<ListView>(find.byType(ListView));
  return listView.controller!.position;
}

void main() {
  testWidgets('长队列打开自动滚到正在播放行并居中', (tester) async {
    final songs = List<Song>.generate(30, (i) => _song(i + 1));
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = songs[19]
      ..isPlaying = true;
    await _openSheet(tester, player);

    final position = _sheetPosition(tester);
    // 居中目标：行顶 19*58 + 28 - 视口一半（允许半行内的布局误差）。
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 29));
  });

  testWidgets('头部定位按钮存在；当前歌不在队列时禁用', (tester) async {
    final songs = [_song(1), _song(2)];
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = _song(99) // 不在队列
      ..isPlaying = true;
    await _openSheet(tester, player);

    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('定位到正在播放'),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);

    // 当前歌在队列时按钮可用。
    player.currentSong = songs[0];
    player.notifyListeners();
    await tester.pump();
    final enabled = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('定位到正在播放'),
        matching: find.byType(IconButton),
      ),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('滚走后点定位按钮平滑回到当前行居中', (tester) async {
    final songs = List<Song>.generate(30, (i) => _song(i + 1));
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = songs[19]
      ..isPlaying = true;
    await _openSheet(tester, player);

    // 滚到顶（远离当前行）。
    _sheetPosition(tester).jumpTo(0);
    await tester.pump();

    await tester.tap(find.byTooltip('定位到正在播放'));
    await tester.pumpAndSettle();

    final position = _sheetPosition(tester);
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 29));
  });

  testWidgets('重复添加同一首歌：定位不崩溃且按钮可回到首个匹配行', (tester) async {
    final dup = _song(7, hash: 'hash-dup');
    final songs = [_song(1), dup, _song(7, hash: 'hash-dup'), _song(3)];
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = dup
      ..isPlaying = true;
    await _openSheet(tester, player); // 若 GlobalKey 重复挂载会在此抛异常

    expect(find.text('测试歌曲7'), findsNWidgets(2));
    // 两行都高亮（既有行为），定位按钮可用（key 只挂首个匹配行）。
    await tester.tap(find.byTooltip('定位到正在播放'));
    await tester.pumpAndSettle();
    expect(_sheetPosition(tester).pixels, 0.0); // 首个匹配行就在顶部附近
  });

  testWidgets('短队列回归：标题/计数渲染，当前第 2 首时不滚动', (tester) async {
    final songs = [_song(1), _song(2), _song(3)];
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = songs[1]
      ..isPlaying = true;
    await _openSheet(tester, player);

    expect(find.text('播放队列'), findsOneWidget);
    expect(find.text('3 首'), findsOneWidget);
    expect(find.text('测试歌曲2'), findsOneWidget);
    expect(find.byIcon(Icons.equalizer_rounded), findsOneWidget);
    expect(_sheetPosition(tester).pixels, 0.0);
  });
}
