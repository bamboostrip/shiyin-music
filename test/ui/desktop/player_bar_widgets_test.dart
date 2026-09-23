import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart' hide formatDuration;
import 'package:shiyin_music/ui/desktop/desktop_player_bar.dart';
import 'package:shiyin_music/ui/desktop/player_bar_widgets.dart';
import 'package:shiyin_music/ui/pages/song_detail_page.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';
import 'package:shiyin_music/ui/widgets/marquee_text.dart';

void main() {
  group('playbackModeIcon', () {
    test('三种模式各对应一个图标', () {
      expect(playbackModeIcon(PlaybackMode.playlistLoop), Icons.repeat_rounded);
      expect(playbackModeIcon(PlaybackMode.shuffle), Icons.shuffle_rounded);
      expect(
        playbackModeIcon(PlaybackMode.singleLoop),
        Icons.repeat_one_rounded,
      );
    });
  });

  group('playbackModeTooltip', () {
    test('包含当前模式名与切换提示', () {
      expect(playbackModeTooltip(PlaybackMode.playlistLoop), '列表循环（点击切换）');
      expect(playbackModeTooltip(PlaybackMode.shuffle), '随机播放（点击切换）');
      expect(playbackModeTooltip(PlaybackMode.singleLoop), '单曲循环（点击切换）');
    });
  });

  group('volumeIconFor', () {
    test('0 → 静音图标', () {
      expect(volumeIconFor(0), Icons.volume_off_rounded);
    });
    test('0..0.5 → 小音量图标', () {
      expect(volumeIconFor(0.05), Icons.volume_down_rounded);
      expect(volumeIconFor(0.49), Icons.volume_down_rounded);
    });
    test('≥0.5 → 大音量图标', () {
      expect(volumeIconFor(0.5), Icons.volume_up_rounded);
      expect(volumeIconFor(1.0), Icons.volume_up_rounded);
    });
  });

  group('toggleMute（静音记忆）', () {
    test('有音量时静音：音量归零并记住当前值', () {
      final (volume, memory) = toggleMute(0.8, null);
      expect(volume, 0.0);
      expect(memory, 0.8);
    });
    test('静音态取消：恢复记忆音量，记忆值保持', () {
      final (volume, memory) = toggleMute(0.0, 0.65);
      expect(volume, 0.65);
      expect(memory, 0.65);
    });
    test('静音态取消但无记忆：回退默认恢复值', () {
      final (volume, memory) = toggleMute(0.0, null);
      expect(volume, kDefaultRestoreVolume);
      expect(memory, isNull);
    });
    test('记忆音量越界时钳制', () {
      final (volume, _) = toggleMute(0.0, 1.5);
      expect(volume, 1.0);
    });
    test('当前音量越界时记忆值钳制', () {
      final (volume, memory) = toggleMute(1.2, null);
      expect(volume, 0.0);
      expect(memory, 1.0);
    });
  });

  group('applyVolumeWheel（滚轮步进）', () {
    test('默认步进为 ±5%', () {
      expect(kVolumeWheelStep, 0.05);
      expect(applyVolumeWheel(0.4, true), closeTo(0.45, 1e-9));
      expect(applyVolumeWheel(0.4, false), closeTo(0.35, 1e-9));
    });
    test('钳制 0..1', () {
      expect(applyVolumeWheel(0.98, true), 1.0);
      expect(applyVolumeWheel(0.03, false), 0.0);
      expect(applyVolumeWheel(1.0, true), 1.0);
      expect(applyVolumeWheel(0.0, false), 0.0);
    });
  });

  group('positionForHover（悬停位置 → 时间）', () {
    const twoMinutes = Duration(minutes: 2);
    test('两端与中点', () {
      expect(positionForHover(0, 280, twoMinutes), Duration.zero);
      expect(
        positionForHover(140, 280, twoMinutes),
        const Duration(minutes: 1),
      );
      expect(positionForHover(280, 280, twoMinutes), twoMinutes);
    });
    test('越界坐标按端点钳制', () {
      expect(positionForHover(-10, 280, twoMinutes), Duration.zero);
      expect(positionForHover(999, 280, twoMinutes), twoMinutes);
    });
    test('宽度或时长非法时返回 0', () {
      expect(positionForHover(10, 0, twoMinutes), Duration.zero);
      expect(positionForHover(10, 280, Duration.zero), Duration.zero);
    });
    test('返回值经过 formatDuration 可直接展示', () {
      final t = positionForHover(70, 280, twoMinutes);
      expect(formatDuration(t), '00:30');
    });
  });

  group('ExpandDetailIcon', () {
    testWidgets('renders CustomPaint with corner bracket painter', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: ExpandDetailIcon(size: 20, color: Colors.white)),
        ),
      );
      expect(find.byType(ExpandDetailIcon), findsOneWidget);
      final customPaintFinder = find.descendant(
        of: find.byType(ExpandDetailIcon),
        matching: find.byType(CustomPaint),
      );
      expect(customPaintFinder, findsOneWidget);
      final customPaint = tester.widget<CustomPaint>(customPaintFinder);
      expect(customPaint.size, const Size(20, 20));
      expect(customPaint.painter, isNotNull);
    });

    testWidgets('respects default size and custom properties', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: ExpandDetailIcon())),
      );
      final defaultIcon = tester.widget<ExpandDetailIcon>(
        find.byType(ExpandDetailIcon),
      );
      expect(defaultIcon.size, 18);
      expect(defaultIcon.color, Colors.white);
      expect(defaultIcon.strokeWidth, 2.0);
    });
  });

  group('CommentBubbleIcon', () {
    testWidgets('renders CustomPaint with bubble painter', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: CommentBubbleIcon(size: 18, color: Colors.white),
          ),
        ),
      );
      expect(find.byType(CommentBubbleIcon), findsOneWidget);
      final customPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(CommentBubbleIcon),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(customPaint.size, const Size(18, 18));
      expect(customPaint.painter, isNotNull);
      // 默认无角标：描边完整闭合
      final icon = tester.widget<CommentBubbleIcon>(
        find.byType(CommentBubbleIcon),
      );
      expect(icon.showBadgeGap, isFalse);
    });

    testWidgets('showBadgeGap 为 true 时右上角留角标缺口', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: CommentBubbleIcon(
              size: 18,
              color: Colors.white,
              showBadgeGap: true,
            ),
          ),
        ),
      );
      final icon = tester.widget<CommentBubbleIcon>(
        find.byType(CommentBubbleIcon),
      );
      expect(icon.showBadgeGap, isTrue);
    });
  });

  group('SongInfo (封面与歌曲详情展开)', () {
    const testSong = Song(
      id: '1',
      title: '测试曲目',
      artist: '测试歌手',
      hash: 'hash123',
    );

    testWidgets('悬停封面展示 ExpandDetailIcon 与"展开歌曲详情页" Tooltip，点击触发 onTap 回调', (
      tester,
    ) async {
      bool tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                children: [
                  SongInfo(
                    song: testSong,
                    colorScheme: const ColorScheme.light(),
                    onTap: () => tapped = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 未悬停时不显示 ExpandDetailIcon
      expect(find.byType(ExpandDetailIcon), findsNothing);

      // 存在对应 tooltip 文案
      expect(find.byTooltip('展开歌曲详情页'), findsOneWidget);

      // 鼠标移入封面
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(Artwork)));
      await tester.pump();

      // 悬停后展示 ExpandDetailIcon
      expect(find.byType(ExpandDetailIcon), findsOneWidget);

      // 点击触发 onTap（点击展开图标）
      await tester.tap(find.byType(ExpandDetailIcon));
      await tester.pump();
      expect(tapped, isTrue);

      // 鼠标移出后 ExpandDetailIcon 消失
      await gesture.moveTo(const Offset(999, 999));
      await tester.pump();
      expect(find.byType(ExpandDetailIcon), findsNothing);
    });

    testWidgets('无歌曲时悬停不展示 ExpandDetailIcon，点击不触发 onTap', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                children: [
                  SongInfo(
                    song: null,
                    colorScheme: const ColorScheme.light(),
                    onTap: () => tapped = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 鼠标移入封面
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(Artwork)));
      await tester.pump();

      expect(find.byType(ExpandDetailIcon), findsNothing);
      expect(find.byTooltip('展开歌曲详情页'), findsNothing);

      await tester.tap(find.byType(Artwork));
      await tester.pump();
      expect(tapped, isFalse);
    });

    testWidgets('传入 onOpenSongDetail 时点歌名进详情页，不再走 onTap（播放页）', (tester) async {
      var tappedPlayerPage = false;
      Song? detailSong;
      SongDetailTab? detailTab;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                children: [
                  SongInfo(
                    song: testSong,
                    colorScheme: const ColorScheme.light(),
                    onTap: () => tappedPlayerPage = true,
                    onOpenSongDetail: (song, tab) {
                      detailSong = song;
                      detailTab = tab;
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(MarqueeText));
      await tester.pump();
      expect(detailSong?.title, '测试曲目');
      expect(detailTab, SongDetailTab.detail);
      expect(tappedPlayerPage, isFalse);
    });

    testWidgets('未传 onOpenSongDetail 时点歌名沿旧行为进播放页', (tester) async {
      var tappedPlayerPage = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                children: [
                  SongInfo(
                    song: testSong,
                    colorScheme: const ColorScheme.light(),
                    onTap: () => tappedPlayerPage = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(MarqueeText));
      await tester.pump();
      expect(tappedPlayerPage, isTrue);
    });
  });
}
