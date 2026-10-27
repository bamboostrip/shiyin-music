import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/widgets/app_song_row.dart';
import 'package:shiyin_music/ui/widgets/now_playing_badge.dart';

/// 只覆写行内角标实际调用的成员：下载判定 + ChangeNotifier 通知。
/// 避免构造真实 DownloadService（会触发 prefs / 网络 / path_provider）。
class _FakeDownloads extends ChangeNotifier implements DownloadController {
  _FakeDownloads({this.downloaded = false});

  bool downloaded;

  @override
  bool isDownloaded(Song song) => downloaded;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

  @override
  DownloadController? downloadController;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _song = Song(
  id: '1',
  title: '海阔天空',
  artist: 'Beyond',
  albumName: '乐与怒',
  duration: Duration(seconds: 325),
  hash: 'hash_app_song_row',
);

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(body: SizedBox(width: 420, child: child)),
    );
  }

  Widget buildRow({
    required _FakePlayerController player,
    bool showDownloadedBadge = true,
    VoidCallback? onTap,
  }) {
    return AppSongRow(
      song: _song,
      player: player,
      onTap: onTap ?? () {},
      showDownloadedBadge: showDownloadedBadge,
    );
  }

  group('AppSongRow 行内「已下载」角标', () {
    testWidgets('已下载歌曲在封面左下角显示绿色 check 角标与「已下载」Tooltip', (tester) async {
      final downloads = _FakeDownloads(downloaded: true);
      final player = _FakePlayerController()..downloadController = downloads;

      await tester.pumpWidget(wrap(buildRow(player: player)));

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.byTooltip('已下载'), findsOneWidget);
      // 角标不抢歌名/歌手等行内信息。
      expect(find.text('海阔天空'), findsOneWidget);
    });

    testWidgets('未下载歌曲不显示角标', (tester) async {
      final downloads = _FakeDownloads();
      final player = _FakePlayerController()..downloadController = downloads;

      await tester.pumpWidget(wrap(buildRow(player: player)));

      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(find.byTooltip('已下载'), findsNothing);
    });

    testWidgets('downloadController 为 null（单测/初始化早期）时静默隐藏且不抛错', (tester) async {
      final player = _FakePlayerController();

      await tester.pumpWidget(wrap(buildRow(player: player)));

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
    });

    testWidgets('downloads.notifyListeners 后角标随之出现/消失', (
      tester,
    ) async {
      final downloads = _FakeDownloads();
      final player = _FakePlayerController()..downloadController = downloads;

      await tester.pumpWidget(wrap(buildRow(player: player)));
      expect(find.byIcon(Icons.check_rounded), findsNothing);

      // 下载完成：控制器通知后角标出现。
      downloads.downloaded = true;
      downloads.notifyListeners();
      await tester.pump();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      // 删除下载：通知后角标消失。
      downloads.downloaded = false;
      downloads.notifyListeners();
      await tester.pump();
      expect(find.byIcon(Icons.check_rounded), findsNothing);
    });

    testWidgets('showDownloadedBadge=false 时即使已下载也不显示（已下载/本地音乐页）', (
      tester,
    ) async {
      final downloads = _FakeDownloads(downloaded: true);
      final player = _FakePlayerController()..downloadController = downloads;

      await tester.pumpWidget(
        wrap(buildRow(player: player, showDownloadedBadge: false)),
      );

      expect(find.byIcon(Icons.check_rounded), findsNothing);
      // 行本身正常渲染。
      expect(find.text('海阔天空'), findsOneWidget);
    });

    testWidgets('角标与右下角播中律动标分居两侧、不重叠', (tester) async {
      final downloads = _FakeDownloads(downloaded: true);
      final player = _FakePlayerController()
        ..downloadController = downloads
        ..currentSong = _song
        ..isPlaying = true;

      await tester.pumpWidget(wrap(buildRow(player: player)));
      // NowPlayingBadge 有持续动画，不能 pumpAndSettle。
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.byType(NowPlayingBadge), findsOneWidget);

      final badgeRect = tester.getRect(find.byIcon(Icons.check_rounded));
      final playingRect = tester.getRect(find.byType(NowPlayingBadge));
      expect(badgeRect.overlaps(playingRect), isFalse);
      // 已下载角标在左、播中标在右。
      expect(badgeRect.center.dx, lessThan(playingRect.center.dx));
    });

    testWidgets('点击角标不触发行播放，只提示本地优先', (tester) async {
      final downloads = _FakeDownloads(downloaded: true);
      final player = _FakePlayerController()..downloadController = downloads;
      var rowTapCount = 0;

      await tester.pumpWidget(
        wrap(buildRow(player: player, onTap: () => rowTapCount++)),
      );

      await tester.tap(find.byIcon(Icons.check_rounded));
      await tester.pump();

      expect(rowTapCount, 0, reason: '角标自身的点击不应冒泡成整行播放');
      expect(tester.takeException(), isNull);
    });
  });
}
