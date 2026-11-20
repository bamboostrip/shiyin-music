import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/settings/storage_settings_section.dart';

class _FakeDownloads extends ChangeNotifier implements DownloadController {
  bool saveLyrics = false;
  int setCalls = 0;

  @override
  bool get saveLyricsFile => saveLyrics;

  @override
  Future<void> setSaveLyricsFile(bool enabled) async {
    setCalls++;
    saveLyrics = enabled;
    notifyListeners();
  }

  @override
  AudioQuality? get downloadQualityOverride => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayer extends ChangeNotifier implements PlayerController {
  @override
  AudioQuality get audioQuality => AudioQuality.standard;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);
  });

  Future<_FakeDownloads> pumpSection(WidgetTester tester) async {
    final downloads = _FakeDownloads();
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              StorageSettingsSection(
                downloads: downloads,
                player: _FakePlayer(),
                onOpenManager: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return downloads;
  }

  // issue #29：这项之前只藏在「缓存管理」弹层里，PC 用户按更新日志的
  // 「设置 → 存储与下载」找不到入口，以为桌面端没上这个功能。
  testWidgets('「存储与下载」分节直接暴露「同时保存 LRC 歌词」开关', (tester) async {
    final downloads = await pumpSection(tester);

    expect(find.text('同时保存 LRC 歌词'), findsOneWidget);
    expect(find.text('缓存管理'), findsOneWidget);

    // 开关状态跟随 DownloadController，点击即写回。
    await tester.tap(find.text('同时保存 LRC 歌词'));
    await tester.pump();
    expect(downloads.setCalls, 1);
    expect(downloads.saveLyrics, isTrue);

    final tile = tester.widget<Switch>(find.byType(Switch));
    expect(tile.value, isTrue);
  });
}
