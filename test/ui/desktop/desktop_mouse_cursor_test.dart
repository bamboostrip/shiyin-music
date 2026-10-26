import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/app_theme.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/search_page.dart';
import 'package:shiyin_music/ui/widgets/album_grid.dart';
import 'package:shiyin_music/ui/widgets/locate_current_song_button.dart';
import 'package:shiyin_music/ui/desktop/player_bar_widgets.dart';
import 'package:shiyin_music/ui/player/landscape_player.dart';
import 'package:shiyin_music/ui/settings/settings_widgets.dart';

class _FakeMusicApi implements MusicApi {
  @override
  Future<List<SearchHotCategory>> searchHotKeywords() async => const [];

  @override
  Future<List<Song>> searchSongs(String keyword, {int page = 1, int pageSize = 30}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  double volume = 0.5;

  @override
  Future<void> setVolume(double value) async {
    volume = value;
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

void main() {
  group('桌面端鼠标光标 (Mouse Cursor) 主题测试', () {
    setUp(() {
      debugDesktopFormFactorOverride = true;
    });

    tearDown(() {
      debugDesktopFormFactorOverride = null;
    });

    testWidgets('桌面端 IconButton 启用态为 hand pointer (click)，禁用态为 basic', (tester) async {
      final theme = AppTheme.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Column(
              children: [
                IconButton(
                  key: const ValueKey('enabled_icon_btn'),
                  onPressed: () {},
                  icon: const Icon(Icons.play_arrow),
                ),
                const IconButton(
                  key: ValueKey('disabled_icon_btn'),
                  onPressed: null,
                  icon: Icon(Icons.play_arrow),
                ),
              ],
            ),
          ),
        ),
      );

      final enabledBtn = tester.widget<IconButton>(find.byKey(const ValueKey('enabled_icon_btn')));
      final disabledBtn = tester.widget<IconButton>(find.byKey(const ValueKey('disabled_icon_btn')));

      final enabledCursor = enabledBtn.style?.mouseCursor?.resolve({}) ??
          theme.iconButtonTheme.style?.mouseCursor?.resolve({});
      final disabledCursor = disabledBtn.style?.mouseCursor?.resolve({WidgetState.disabled}) ??
          theme.iconButtonTheme.style?.mouseCursor?.resolve({WidgetState.disabled});

      expect(enabledCursor, SystemMouseCursors.click);
      expect(disabledCursor, SystemMouseCursors.basic);
    });

    testWidgets('桌面端 FilledButton 启用态为 hand pointer (click)，禁用态为 basic', (tester) async {
      final theme = AppTheme.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Column(
              children: [
                FilledButton(
                  key: const ValueKey('enabled_filled_btn'),
                  onPressed: () {},
                  child: const Text('播放全部'),
                ),
                const FilledButton(
                  key: ValueKey('disabled_filled_btn'),
                  onPressed: null,
                  child: Text('播放全部'),
                ),
              ],
            ),
          ),
        ),
      );

      final enabledBtn = tester.widget<FilledButton>(find.byKey(const ValueKey('enabled_filled_btn')));
      final disabledBtn = tester.widget<FilledButton>(find.byKey(const ValueKey('disabled_filled_btn')));

      final enabledCursor = enabledBtn.style?.mouseCursor?.resolve({}) ??
          theme.filledButtonTheme.style?.mouseCursor?.resolve({});
      final disabledCursor = disabledBtn.style?.mouseCursor?.resolve({WidgetState.disabled}) ??
          theme.filledButtonTheme.style?.mouseCursor?.resolve({WidgetState.disabled});

      expect(enabledCursor, SystemMouseCursors.click);
      expect(disabledCursor, SystemMouseCursors.basic);
    });

    testWidgets('桌面端 AlbumGridCard 歌单/专辑卡片 InkWell 使用 SystemMouseCursors.click', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 160,
              height: 240,
              child: AlbumGridCard(
                album: const ArtistAlbum(
                  id: '1',
                  name: '热门专辑',
                  coverUrl: '',
                ),
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      final inkWellFinder = find.descendant(
        of: find.byType(AlbumGridCard),
        matching: find.byType(InkWell),
      );
      expect(inkWellFinder, findsOneWidget);
      final inkWell = tester.widget<InkWell>(inkWellFinder.first);
      expect(inkWell.mouseCursor, SystemMouseCursors.click);
    });

    testWidgets('LocateCurrentSongButton 使用 SystemMouseCursors.click', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocateCurrentSongButton(
              onPressed: () {},
            ),
          ),
        ),
      );

      final inkWell = tester.widget<InkWell>(find.byType(InkWell));
      expect(inkWell.mouseCursor, SystemMouseCursors.click);
    });

    test('Windows 平台主题字体与回退链包含 Microsoft YaHei 和 SimHei，且 FilledButton 使用 Bold (w700)', () {
      final theme = AppTheme.light();
      final fallback = theme.textTheme.bodyMedium?.fontFamilyFallback;
      expect(fallback, contains('Microsoft YaHei UI'));
      expect(fallback, contains('Microsoft YaHei'));
      expect(fallback, contains('SimHei'));

      // 在桌面模式下，FilledButton 按钮文字为 w700，避免 DirectWrite 寻找 w800/w900 字体时回退到日文字体 Yu Gothic
      final buttonTextStyle = theme.filledButtonTheme.style?.textStyle?.resolve({});
      expect(buttonTextStyle?.fontWeight, FontWeight.w700);
    });

    testWidgets('SearchPage 桌面端平台选择器与类型选择器使用 SystemMouseCursors.click', (tester) async {
      final api = _FakeMusicApi();
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SearchPage(
              api: api,
              auth: auth,
              player: player,
              initialQuery: '周杰伦',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 平台切换（酷狗、网易云）
      final kugouChip = find.text('酷狗');
      expect(kugouChip, findsOneWidget);
      final kugouMouseRegion = tester.widget<MouseRegion>(
        find.ancestor(of: kugouChip, matching: find.byType(MouseRegion)).first,
      );
      expect(kugouMouseRegion.cursor, SystemMouseCursors.click);

      final neteaseChip = find.text('网易云');
      expect(neteaseChip, findsOneWidget);
      final neteaseMouseRegion = tester.widget<MouseRegion>(
        find.ancestor(of: neteaseChip, matching: find.byType(MouseRegion)).first,
      );
      expect(neteaseMouseRegion.cursor, SystemMouseCursors.click);

      // 类型切换（歌曲、歌手、专辑）
      final songTypeChip = find.text('歌曲');
      expect(songTypeChip, findsOneWidget);
      final songTypeMouseRegion = tester.widget<MouseRegion>(
        find.ancestor(of: songTypeChip, matching: find.byType(MouseRegion)).first,
      );
      expect(songTypeMouseRegion.cursor, SystemMouseCursors.click);

      final artistTypeChip = find.text('歌手');
      expect(artistTypeChip, findsOneWidget);
      final artistTypeMouseRegion = tester.widget<MouseRegion>(
        find.ancestor(of: artistTypeChip, matching: find.byType(MouseRegion)).first,
      );
      expect(artistTypeMouseRegion.cursor, SystemMouseCursors.click);
    });

    testWidgets('桌面端 SettingsTile 与 SettingsSwitchTile 使用手型指针 (SystemMouseCursors.click)', (tester) async {
      var switchToggled = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                SettingsTile(
                  icon: Icons.sync,
                  title: '同步个人信息',
                  onTap: () {},
                ),
                const SettingsTile(
                  icon: Icons.sync,
                  title: '禁用项',
                  onTap: null,
                ),
                SettingsSwitchTile(
                  icon: Icons.card_giftcard,
                  title: '自动领取VIP',
                  value: false,
                  onChanged: (v) => switchToggled = v,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final inkWells = tester.widgetList<InkWell>(find.byType(InkWell)).toList();
      expect(inkWells.length, 3);
      // 启用态 SettingsTile 为 click 手型
      expect(inkWells[0].mouseCursor, SystemMouseCursors.click);
      // 禁用态（onTap == null）SettingsTile 为 basic 箭头
      expect(inkWells[1].mouseCursor, SystemMouseCursors.basic);
      // SettingsSwitchTile 整行启用态为 click 手型
      expect(inkWells[2].mouseCursor, SystemMouseCursors.click);

      // 点击整行触发 Switch 切换
      await tester.tap(find.text('自动领取VIP'));
      expect(switchToggled, isTrue);
    });

    testWidgets('SectionHeader 在桌面端优化为 FontWeight.w600，移动端为 w900', (tester) async {
      // 桌面端状态
      debugDesktopFormFactorOverride = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionHeader(title: '账号'),
          ),
        ),
      );
      final desktopText = tester.widget<Text>(find.text('账号'));
      expect(desktopText.style?.fontWeight, FontWeight.w600);

      // 移动端状态
      debugDesktopFormFactorOverride = false;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionHeader(title: '账号'),
          ),
        ),
      );
      final mobileText = tester.widget<Text>(find.text('账号'));
      expect(mobileText.style?.fontWeight, FontWeight.w900);
    });

    testWidgets('LandscapeHeaderButton 在桌面端背景为透明（无阴影/底色），移动/车机端保留半透明底色', (tester) async {
      // 桌面端
      debugDesktopFormFactorOverride = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LandscapeHeaderButton(
              tooltip: '返回',
              size: 44,
              iconSize: 34,
              onPressed: () {},
              icon: Icons.keyboard_arrow_left_rounded,
            ),
          ),
        ),
      );
      final desktopMaterial = tester.widget<Material>(
        find.descendant(
          of: find.byType(LandscapeHeaderButton),
          matching: find.byType(Material),
        ).first,
      );
      expect(desktopMaterial.color, Colors.transparent);

      // 移动/车机端
      debugDesktopFormFactorOverride = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LandscapeHeaderButton(
              tooltip: '返回',
              size: 44,
              iconSize: 34,
              onPressed: () {},
              icon: Icons.keyboard_arrow_left_rounded,
            ),
          ),
        ),
      );
      final mobileMaterial = tester.widget<Material>(
        find.descendant(
          of: find.byType(LandscapeHeaderButton),
          matching: find.byType(Material),
        ).first,
      );
      expect(mobileMaterial.color, Colors.white.withValues(alpha: .12));
    });

    testWidgets('VolumePopoverButton 打开/关闭时外层尺寸保持严格一致（避免相邻播控按钮产生位移抖动）', (tester) async {
      debugDesktopFormFactorOverride = true;
      final player = _FakePlayerController();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: VolumePopoverButton(
                key: const ValueKey('volume_btn'),
                player: player,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final initialSize = tester.getSize(find.byKey(const ValueKey('volume_btn')));

      // 点击打开音量弹出卡片
      await tester.tap(find.byKey(const ValueKey('volume_btn')));
      await tester.pumpAndSettle();

      final openedSize = tester.getSize(find.byKey(const ValueKey('volume_btn')));
      expect(openedSize, equals(initialSize), reason: '音量按钮开启态与关闭态尺寸必须完全一致，防止父级居中布局发生抖动位移');
    });

    test('桌面端全局主题配置 switchTheme、radioTheme、listTileTheme 鼠标指针为 SystemMouseCursors.click', () {
      final theme = AppTheme.light();
      final switchCursor = theme.switchTheme.mouseCursor?.resolve({});
      final radioCursor = theme.radioTheme.mouseCursor?.resolve({});
      final listTileCursor = theme.listTileTheme.mouseCursor?.resolve({});

      expect(switchCursor, SystemMouseCursors.click);
      expect(radioCursor, SystemMouseCursors.click);
      expect(listTileCursor, SystemMouseCursors.click);
    });
  });
}