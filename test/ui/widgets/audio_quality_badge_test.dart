import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/widgets/audio_quality_badge.dart';
import 'package:shiyin_music/ui/widgets/desktop_song_table_row.dart';

/// 最小 PlayerController 桩：表格行只消费 currentSong/isPlaying 与少量回调，
/// 其余成员交给 noSuchMethod 兜底，避免为了一个徽标用例拖起真实播放器。
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
  Future<void> togglePlay() async {
    isPlaying = !isPlaying;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  final Set<String> likedHashes = {};

  @override
  bool isLiked(Song song) => likedHashes.contains(song.hash);

  @override
  Future<void> toggleLike(Song song) async {
    if (likedHashes.contains(song.hash)) {
      likedHashes.remove(song.hash);
    } else {
      likedHashes.add(song.hash);
    }
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 800, child: child),
        ),
      ),
    );
  }

  /// 表格行唯一必需的业务数据；刻意不带 SQ/Hi-Res/VIP 字样，
  /// 避免与标题猜出来的属性微标混淆，断言里只应出现我们传入的档位徽标。
  const testSong = Song(
    id: '9001',
    title: '晴天',
    rawTitle: '周杰伦 - 晴天',
    artist: '周杰伦',
    hash: 'hash_audio_quality_badge',
    albumName: '叶惠美',
    duration: Duration(minutes: 4, seconds: 29),
  );

  DesktopSongTableRow buildRow({
    Widget? trailingBadge,
    VoidCallback? onTap,
    VoidCallback? onDoubleTap,
  }) {
    return DesktopSongTableRow(
      song: testSong,
      index: 1,
      player: _FakePlayerController(),
      auth: _FakeAuthController(),
      canDelete: false,
      selecting: false,
      selected: false,
      isFocused: false,
      onTap: onTap ?? () {},
      onDoubleTap: onDoubleTap ?? () {},
      onPlay: () {},
      onAddToPlaylist: () {},
      onDelete: () {},
      onViewArtist: () {},
      onMore: () {},
      trailingBadge: trailingBadge,
    );
  }

  group('AudioQualityBadge 档位文案与配色', () {
    testWidgets('三档分别渲染 128K / 320K / FLAC', (tester) async {
      for (final quality in AudioQuality.values) {
        await tester.pumpWidget(wrap(AudioQualityBadge(quality: quality)));
        expect(find.text(quality.badge), findsOneWidget);
      }
    });

    testWidgets('三档文字颜色互不相同（灰/蓝/橙各自成档）', (tester) async {
      final colors = <Color?>[];
      for (final quality in AudioQuality.values) {
        await tester.pumpWidget(wrap(AudioQualityBadge(quality: quality)));
        colors.add(
          tester.widget<Text>(find.text(quality.badge)).style?.color,
        );
      }
      expect(colors.whereType<Color>(), hasLength(3));
      expect(colors.toSet(), hasLength(3));
    });

    testWidgets('徽标排除语义，避免给整行读屏添噪', (tester) async {
      await tester.pumpWidget(
        wrap(const AudioQualityBadge(quality: AudioQuality.lossless)),
      );
      expect(
        find.descendant(
          of: find.byType(AudioQualityBadge),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
    });
  });

  group('AudioQualityBadge 不拦截点击', () {
    testWidgets('点击徽标位置时父级手势回调被触发', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          Center(
            child: GestureDetector(
              // 用父级铺满的命中行为模拟真实列表行：徽标本身必须让点击穿透。
              behavior: HitTestBehavior.opaque,
              onTap: () => tapped = true,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: AudioQualityBadge(quality: AudioQuality.high),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(AudioQualityBadge));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });

  group('DesktopSongTableRow.trailingBadge', () {
    testWidgets('不传 trailingBadge 时不渲染档位徽标', (tester) async {
      await tester.pumpWidget(wrap(buildRow()));
      expect(find.byType(AudioQualityBadge), findsNothing);
      // 默认 null 不占位：不传时行内不应冒出差一个 SizedBox 的空白。
      expect(
        tester.getSize(find.byType(DesktopSongTableRow)).height,
        DesktopSongTableRow.rowHeight,
      );
    });

    testWidgets('传入 trailingBadge 后渲染对应档位徽标', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildRow(
            trailingBadge: const AudioQualityBadge(
              quality: AudioQuality.lossless,
            ),
          ),
        ),
      );

      expect(find.byType(AudioQualityBadge), findsOneWidget);
      expect(find.text('FLAC'), findsOneWidget);
    });

    testWidgets('点击徽标位置仍触发行级 onTap（徽标不吞手势）', (tester) async {
      var tapCount = 0;
      await tester.pumpWidget(
        wrap(
          buildRow(
            trailingBadge: const AudioQualityBadge(
              quality: AudioQuality.standard,
            ),
            onTap: () => tapCount++,
          ),
        ),
      );

      // 行内会把 trailingBadge 包进 IgnorePointer（刻意让手势穿透），
      // tester.tap(finder) 会因"命中结果不含该 widget"报警告，故按坐标点击。
      await tester.tapAt(tester.getCenter(find.byType(AudioQualityBadge)));
      // 行内同时挂单击/双击识别器，单击要等双击超时后才落地。
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(tapCount, 1);
    });
  });
}
