import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/local_songs_page.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

/// 只覆写本地歌曲行会碰到的成员；其余走 noSuchMethod。
/// 不构造真实 PlayerController（会拉起 audio_service / Rust / 网络请求）。
class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

  @override
  DownloadController? downloadController;

  /// 「下一首播放」实际排进队列的歌曲。
  final List<Song> addedToQueue = [];

  /// 点行播放实际收到的 (歌曲, 队列)。
  final List<(Song, List<Song>?)> played = [];

  @override
  Future<bool> addToQueue(Song song) async {
    addedToQueue.add(song);
    return true;
  }

  /// playSong 的具名参数较多且随播放流程演进，这里不写死签名：
  /// 统一经 noSuchMethod 截获，只取歌曲与 queue。
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #playSong) {
      played.add((
        invocation.positionalArguments.first as Song,
        invocation.namedArguments[#queue] as List<Song>?,
      ));
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _FakeAuth extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 本地歌曲：hash 即文件路径，不是在线曲库条目。
const _song = Song(
  id: r'/storage/emulated/0/Music/晴天.flac',
  title: '晴天',
  artist: '周杰伦',
  hash: r'/storage/emulated/0/Music/晴天.flac',
  source: SongSource.local,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget host(_FakePlayerController player) {
    return MaterialApp(
      navigatorKey: Toast.navigatorKey,
      home: Scaffold(
        body: LocalSongRow(
          song: _song,
          queue: const [_song],
          player: player,
          auth: _FakeAuth(),
        ),
      ),
    );
  }

  /// 菜单项在弹窗关闭后延迟 120ms 才执行动作（见 _SongActionTile）。
  Future<void> settleAction(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  group('本地歌曲行长按菜单（issue #34）', () {
    testWidgets('移动端长按弹出菜单，只有「下一首播放」', (tester) async {
      debugDesktopFormFactorOverride = false;
      final player = _FakePlayerController();
      await tester.pumpWidget(host(player));

      await tester.longPress(find.text('晴天'));
      await tester.pumpAndSettle();

      expect(find.text('下一首播放'), findsOneWidget);
      // 本地文件加不进云端歌单、也没有歌手页可跳：菜单不给这些入口。
      expect(find.text('添加到歌单'), findsNothing);
      expect(find.text('查看歌手'), findsNothing);
    });

    testWidgets('点「下一首播放」把本地歌曲排进队列并提示', (tester) async {
      debugDesktopFormFactorOverride = false;
      final player = _FakePlayerController();
      await tester.pumpWidget(host(player));

      await tester.longPress(find.text('晴天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一首播放'));
      await settleAction(tester);

      expect(player.addedToQueue, [_song]);
      expect(find.text('已设为下一首播放'), findsOneWidget);

      // 等全局 Toast 的 2s 消失计时器走完，否则测试结束时留有 pending timer。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('普通点击仍是整份列表播放，不弹菜单', (tester) async {
      debugDesktopFormFactorOverride = false;
      final player = _FakePlayerController();
      await tester.pumpWidget(host(player));

      await tester.tap(find.text('晴天'));
      await tester.pumpAndSettle();

      expect(player.played, hasLength(1));
      expect(player.played.single.$1, _song);
      expect(player.played.single.$2, const [_song]);
      expect(find.text('下一首播放'), findsNothing);
      expect(player.addedToQueue, isEmpty);
    });

    testWidgets('桌面形态右键同样弹出菜单', (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();
      await tester.pumpWidget(host(player));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('晴天')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('下一首播放'), findsOneWidget);
    });
  });
}
