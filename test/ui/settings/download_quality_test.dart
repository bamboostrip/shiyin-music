import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/settings/download_quality_settings.dart';
import 'package:shiyin_music/ui/settings/download_settings_section.dart';

/// 只覆写本组件实际调用的成员：真实 DownloadController 会碰 prefs、目录
/// 对账与网络，widget 测试不需要也不该依赖这些。
class _FakeDownloads extends ChangeNotifier implements DownloadController {
  _FakeDownloads({AudioQuality? initialOverride})
    : _override = initialOverride;

  AudioQuality? _override;

  /// `setDownloadQuality` 收到的入参记录（断言 UI → controller 接线）。
  final List<AudioQuality?> writes = [];

  @override
  AudioQuality? get downloadQualityOverride => _override;

  @override
  Future<void> setDownloadQuality(AudioQuality? quality) async {
    writes.add(quality);
    _override = quality;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 「当前档位」取自 player.audioQuality，这里只需可变 + 能通知。
class _FakePlayer extends ChangeNotifier implements PlayerController {
  _FakePlayer(this._audioQuality);

  AudioQuality _audioQuality;

  @override
  AudioQuality get audioQuality => _audioQuality;

  @override
  Future<void> setAudioQuality(
    AudioQuality quality, {
    bool reloadCurrent = false,
  }) async {
    _audioQuality = quality;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 「下载」分节里的「下载位置」瓦片会读 prefs；给空初值避免测试里走
    // 未注册的平台通道（path_provider 失败本身已在瓦片内被吞掉）。
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(body: SizedBox(width: 420, child: child)),
    );
  }

  Widget buildTile(_FakeDownloads downloads, _FakePlayer player) {
    return wrap(DownloadQualitySettings(downloads: downloads, player: player));
  }

  testWidgets('默认跟随播放音质，副标题带当前档位', (tester) async {
    final downloads = _FakeDownloads();
    await tester.pumpWidget(
      buildTile(downloads, _FakePlayer(AudioQuality.high)),
    );

    expect(find.text('下载音质'), findsOneWidget);
    // 跟随态直接报当前档位，用户不用再去播放分节对照「默认音质」。
    expect(find.text('跟随播放音质（当前 320K）'), findsOneWidget);
    // 只是展示，没有点选就不该写任何设置。
    expect(downloads.writes, isEmpty);
  });

  testWidgets('播放音质改变后「跟随」副标题即时刷新', (tester) async {
    final downloads = _FakeDownloads();
    final player = _FakePlayer(AudioQuality.high);
    await tester.pumpWidget(buildTile(downloads, player));

    await player.setAudioQuality(AudioQuality.lossless);
    await tester.pump();

    expect(find.text('跟随播放音质（当前 FLAC）'), findsOneWidget);
    expect(find.text('跟随播放音质（当前 320K）'), findsNothing);
  });

  testWidgets('点击下载音质弹出四档选项', (tester) async {
    await tester.pumpWidget(
      buildTile(_FakeDownloads(), _FakePlayer(AudioQuality.high)),
    );

    await tester.tap(find.text('下载音质'));
    await tester.pumpAndSettle();

    expect(find.text('跟随播放音质'), findsOneWidget);
    expect(find.text('标准音质 · 128K'), findsOneWidget);
    expect(find.text('高品音质 · 320K'), findsOneWidget);
    expect(find.text('无损音质 · FLAC'), findsOneWidget);
    // 跟随项的说明要带上当前播放档位，用户才知道「跟随」在跟随什么。
    expect(find.textContaining('播放音质变了下载也跟着变'), findsOneWidget);
    expect(find.textContaining('该曲无无损源时自动降级'), findsOneWidget);
  });

  testWidgets('选择无损后副标题变为 FLAC，并写入 controller', (tester) async {
    final downloads = _FakeDownloads();
    await tester.pumpWidget(
      buildTile(downloads, _FakePlayer(AudioQuality.high)),
    );

    await tester.tap(find.text('下载音质'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('无损音质 · FLAC'));
    await tester.pumpAndSettle();

    expect(downloads.writes, [AudioQuality.lossless]);
    expect(find.text('无损音质（FLAC）'), findsOneWidget);
    expect(find.text('跟随播放音质（当前 320K）'), findsNothing);
  });

  testWidgets('已选固定档位时点「跟随播放音质」写回 null，而不是被当成取消', (tester) async {
    // 回归点：radio 值若直接用可空 AudioQuality，null 既表示「跟随」又表示
    // 「取消」，用户点「跟随」会被当成取消、永远回不到跟随。
    final downloads = _FakeDownloads(initialOverride: AudioQuality.lossless);
    await tester.pumpWidget(
      buildTile(downloads, _FakePlayer(AudioQuality.high)),
    );
    expect(find.text('无损音质（FLAC）'), findsOneWidget);

    await tester.tap(find.text('下载音质'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随播放音质'));
    await tester.pumpAndSettle();

    expect(downloads.writes, [null]);
    expect(find.text('跟随播放音质（当前 320K）'), findsOneWidget);
  });

  testWidgets('注入 downloads 后「下载」分节内出现下载音质行', (tester) async {
    await tester.pumpWidget(
      wrap(
        DownloadSettingsSection(
          downloads: _FakeDownloads(initialOverride: AudioQuality.standard),
          player: _FakePlayer(AudioQuality.high),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('下载位置'), findsOneWidget);
    expect(find.text('下载音质'), findsOneWidget);
    expect(find.text('标准音质（128K）'), findsOneWidget);
  });

  testWidgets('downloads 为 null 时不渲染下载音质行', (tester) async {
    // SettingsPage 测试（settings_desktop_gate_test）不注入 downloads：
    // 分节只留「下载位置」，不出现点了没用的「下载音质」。
    await tester.pumpWidget(
      wrap(
        DownloadSettingsSection(
          downloads: null,
          player: _FakePlayer(AudioQuality.high),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('下载位置'), findsOneWidget);
    expect(find.text('下载音质'), findsNothing);
  });
}
