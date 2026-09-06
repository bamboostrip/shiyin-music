import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/downloaded_songs_page.dart';
import 'package:shiyin_music/ui/widgets/desktop_song_table_row.dart';

class _FakeMusicApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

  @override
  DownloadController? get downloadController => null;

  Song? lastPlayedSong;

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
  }) async {
    lastPlayedSong = song;
    currentSong = song;
    isPlaying = true;
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

class _FakeDownloadController extends ChangeNotifier
    implements DownloadController {
  _FakeDownloadController(this._entries);

  final List<DownloadEntry> _entries;

  final List<String> deletedHashes = [];

  @override
  List<DownloadEntry> get downloadEntries => _entries;

  @override
  Future<void> deleteDownload(Song song) async {
    deletedHashes.add(song.hash);
    _entries.removeWhere((e) => e.song.hash == song.hash);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _downloadedSong = Song(
  id: '1',
  title: '海阔天空',
  artist: 'Beyond',
  albumName: '乐与怒',
  duration: Duration(seconds: 325),
  hash: 'hash_downloaded',
);

DownloadEntry _entry({
  Song song = _downloadedSong,
  DownloadStatus status = DownloadStatus.downloaded,
  String? filePath,
}) {
  return DownloadEntry(
    song: song,
    quality: AudioQuality.standard,
    status: status,
    filePath: filePath,
  );
}

void main() {
  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget buildPage(
    _FakeDownloadController downloads, {
    _FakePlayerController? player,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          child: DownloadedSongsPage(
            api: _FakeMusicApi(),
            auth: _FakeAuthController(),
            player: player ?? _FakePlayerController(),
            downloads: downloads,
          ),
        ),
      ),
    );
  }

  group('已下载页 PC 桌面端表格 (isDesktopFormFactor == true)', () {
    setUp(() {
      debugDesktopFormFactorOverride = true;
    });

    testWidgets('渲染表头与固定 44px 高度的已完成下载数据行', (tester) async {
      final downloads = _FakeDownloadController([
        _entry(song: _downloadedSong, filePath: r'C:\music\a.mp3'),
        _entry(
          song: const Song(
            id: '2',
            title: '光辉岁月',
            artist: 'Beyond',
            albumName: '命运派对',
            duration: Duration(seconds: 302),
            hash: 'hash_guanghui',
          ),
        ),
      ]);

      await tester.pumpWidget(buildPage(downloads));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopSongTableHeader), findsOneWidget);
      expect(find.text('歌曲标题'), findsOneWidget);
      expect(find.byType(DesktopSongTableRow), findsNWidgets(2));
      expect(find.text('海阔天空'), findsOneWidget);
      expect(find.text('光辉岁月'), findsOneWidget);

      final rowSize = tester.getSize(find.byType(DesktopSongTableRow).first);
      expect(rowSize.height, DesktopSongTableRow.rowHeight);

      // 统计行与清空操作保留
      expect(find.text('已下载 2 首'), findsOneWidget);
      expect(find.text('清空全部'), findsOneWidget);
      // 移动端行内圆形播放/更多按钮不在桌面表格中出现
      expect(find.byIcon(Icons.play_circle_fill_rounded), findsNothing);
      expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    });

    testWidgets('双击行播放该歌曲', (tester) async {
      final player = _FakePlayerController();
      final downloads = _FakeDownloadController([_entry()]);

      await tester.pumpWidget(buildPage(downloads, player: player));
      await tester.pumpAndSettle();

      final rowTopLeft = tester.getTopLeft(find.byType(DesktopSongTableRow));
      final pressPoint = rowTopLeft + const Offset(100, 22);
      await tester.tapAt(pressPoint);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(pressPoint);
      // 播放后行内 NowPlayingBadge 有持续动画，不能 pumpAndSettle
      await tester.pump(const Duration(milliseconds: 400));

      expect(player.lastPlayedSong?.hash, _downloadedSong.hash);
    });

    testWidgets('右键行弹出下载管理菜单，删除下载生效', (tester) async {
      final downloads = _FakeDownloadController([
        _entry(song: _downloadedSong, filePath: r'C:\music\a.mp3'),
      ]);

      await tester.pumpWidget(buildPage(downloads));
      await tester.pumpAndSettle();

      final rowTopLeft = tester.getTopLeft(find.byType(DesktopSongTableRow));
      await tester.tapAt(
        rowTopLeft + const Offset(100, 22),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('删除下载'), findsOneWidget);
      expect(find.text('打开文件夹'), findsOneWidget);
      expect(find.text('查看文件路径'), findsOneWidget);

      await tester.tap(find.text('删除下载'));
      await tester.pumpAndSettle();

      expect(downloads.deletedHashes, [_downloadedSong.hash]);
    });
  });

  group('已下载页移动端/车机端 (isDesktopFormFactor == false)', () {
    setUp(() {
      debugDesktopFormFactorOverride = false;
    });

    testWidgets('保持 ListTile 行内操作，不渲染桌面表格', (tester) async {
      final downloads = _FakeDownloadController([
        _entry(song: _downloadedSong, filePath: r'C:\music\a.mp3'),
      ]);

      await tester.pumpWidget(buildPage(downloads));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopSongTableRow), findsNothing);
      expect(find.byType(DesktopSongTableHeader), findsNothing);
      expect(find.byIcon(Icons.play_circle_fill_rounded), findsOneWidget);
      expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
    });
  });
}
