import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/song.dart';
import 'package:shiyin_music/services/identify_service.dart';
// api.dart 只 import 不 re-export IdentifyCandidate,需直接引入声明文件
// (与 identify_service.dart 同款做法,测试构造 fake 候选用)。
import 'package:shiyin_music/src/rust/services/identify.dart' show IdentifyCandidate;
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/identify_page.dart';

IdentifyCandidate _candidate({String name = '晴天', String singer = '周杰伦'}) =>
    IdentifyCandidate(
      name: name,
      singer: singer,
      hash: 'abc123',
      albumAudioId: '1',
      albumId: '',
      albumName: '叶惠美',
      cover: '',
      hash320: '',
      hashFlac: '',
      durationMs: 269000,
      dist: 0.1,
    );

class _FakeCaptureBackend implements IdentifyCaptureBackend {
  int startCalls = 0;
  int cancelCalls = 0;
  String? lastSource;
  @override
  Future<void> start({String source = 'mic'}) async {
    startCalls++;
    lastSource = source;
  }

  @override
  Future<Uint8List?> stopAndCollect({int durationMs = 10000}) async =>
      Uint8List.fromList(List.filled(16000, 1));

  @override
  Future<void> cancel() async => cancelCalls++;
}

/// start 迟迟不完成的采集后端:复现"页面在 start 在途时被关闭"的时序。
class _SlowStartBackend implements IdentifyCaptureBackend {
  int startCalls = 0;
  int cancelCalls = 0;
  final Completer<void> _startCompleter = Completer<void>();

  void completeStart() => _startCompleter.complete();

  @override
  Future<void> start({String source = 'mic'}) {
    startCalls++;
    return _startCompleter.future;
  }

  @override
  Future<Uint8List?> stopAndCollect({int durationMs = 10000}) async => null;

  @override
  Future<void> cancel() async => cancelCalls++;
}

class _FakePlayer extends ChangeNotifier implements PlayerController {
  final List<Song> played = [];

  @override
  Song? get currentSong => null;

  @override
  bool get isPlaying => false;

  @override
  DownloadController? get downloadController => null;

  @override
  AudioQuality get audioQuality => AudioQuality.standard;

  @override
  Future<void> playSong(Song song,
      {List<Song>? queue,
      bool isRetry = false,
      Duration? initialPosition,
      bool preserveClimax = false}) async {
    played.add(song);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  testWidgets('移动端形态：满 3 秒展示立即识别，识别结果展示并可点击播放', (tester) async {
    debugDesktopFormFactorOverride = false;
    final backend = _FakeCaptureBackend();
    final player = _FakePlayer();
    final result = IdentifyService.candidateToSong(_candidate());

    await tester.pumpWidget(MaterialApp(
      home: IdentifyPage(
        player: player,
        captureBackend: backend,
        onIdentify: (pcm) async => [result],
      ),
    ));
    await tester.pump(); // 首帧:进入 listening 并 start()
    expect(backend.startCalls, 1);

    // 前 2 秒显示"正在聆听"
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('正在聆听'), findsOneWidget);

    // 满 3 秒后变为"立即识别"
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('立即识别'), findsOneWidget);

    // 手动点击立即识别
    await tester.tap(find.text('立即识别'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 结果帧渲染

    // 结果列表出现歌名与最佳匹配标签
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('最佳匹配 90%'), findsOneWidget);

    // 移动端单机卡片行 → playSong 被调用
    await tester.tap(find.text('晴天'));
    await tester.pump();
    expect(player.played.single.hash, 'abc123');

    // 页面仍留在结果页，点返回按钮正常退出并触发 cancel
    await tester.tap(find.byTooltip('返回'));
    await tester.pump(const Duration(seconds: 1));
    expect(backend.cancelCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('dispose 排队在途 start 之后才 cancel，不留无主采集流', (tester) async {
    debugDesktopFormFactorOverride = false;
    final backend = _SlowStartBackend();
    final player = _FakePlayer();

    await tester.pumpWidget(MaterialApp(
      home: IdentifyPage(player: player, captureBackend: backend),
    ));
    await tester.pump(); // 首帧:start 已发起但未完成
    expect(backend.startCalls, 1);

    // 页面在 start 未完成时被移除
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump();
    // start 完成前不得 cancel（cancel 先落地会被后到的 start 反杀成无主流）
    expect(backend.cancelCalls, 0);

    // start 完成 → 排队中的 cancel 紧随执行
    backend.completeStart();
    await tester.pump();
    expect(backend.cancelCalls, 1);
  });

  testWidgets('移动端形态：更多按钮可弹出操作菜单（含下一首播放）', (tester) async {
    debugDesktopFormFactorOverride = false;
    final backend = _FakeCaptureBackend();
    final player = _FakePlayer();
    final result = IdentifyService.candidateToSong(_candidate());

    await tester.pumpWidget(MaterialApp(
      home: IdentifyPage(
        player: player,
        captureBackend: backend,
        onIdentify: (pcm) async => [result],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11)); // 超过 10s 自动提交
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('晴天'), findsOneWidget);

    // 移动端更多按钮 (Icons.more_horiz_rounded)
    final moreButton = find.byIcon(Icons.more_horiz_rounded);
    expect(moreButton, findsOneWidget);
    await tester.tap(moreButton);
    await tester.pumpAndSettle();

    // 验证弹出的菜单项包含"下一首播放"
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('PC 桌面端形态：识别结果展示专业表格，支持双击播放与右键菜单', (tester) async {
    debugDesktopFormFactorOverride = true;
    final backend = _FakeCaptureBackend();
    final player = _FakePlayer();
    final result = IdentifyService.candidateToSong(_candidate());

    await tester.pumpWidget(MaterialApp(
      home: IdentifyPage(
        player: player,
        captureBackend: backend,
        onIdentify: (pcm) async => [result],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 300));

    // 结果列表中存在歌名
    expect(find.text('晴天'), findsOneWidget);

    // 桌面端双击歌曲文本触发播放
    await tester.tap(find.text('晴天'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('晴天'), warnIfMissed: false);
    await tester.pump();
    expect(player.played.single.hash, 'abc123');

    // 桌面端右键（Secondary Click）呼出操作菜单
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(tester.getCenter(find.text('晴天')));
    await gesture.up();
    await tester.pumpAndSettle();

    // 验证菜单项包含"下一首播放"与"查看歌手"
    expect(find.text('下一首播放'), findsOneWidget);
    expect(find.text('查看歌手'), findsOneWidget);
  });

  testWidgets('识别不到结果显示空态文案', (tester) async {
    final backend = _FakeCaptureBackend();
    await tester.pumpWidget(MaterialApp(
      home: IdentifyPage(
        player: _FakePlayer(),
        captureBackend: backend,
        onIdentify: (pcm) async => [],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('未识别到歌曲'), findsOneWidget);
  });

  testWidgets('桌面端支持切换采集源至电脑声音(系统内录)', (tester) async {
    debugDesktopFormFactorOverride = true;
    final backend = _FakeCaptureBackend();
    await tester.pumpWidget(MaterialApp(
      home: IdentifyPage(
        player: _FakePlayer(),
        captureBackend: backend,
        onIdentify: (pcm) async => [],
      ),
    ));
    await tester.pump();
    expect(backend.lastSource, 'mic');

    // 找到电脑声音切换按钮并点击
    final systemButton = find.text('电脑声音 (系统内录)');
    expect(systemButton, findsOneWidget);
    await tester.tap(systemButton);
    await tester.pump();

    // 应该以 system 重新启动后端
    expect(backend.lastSource, 'system');
    expect(find.text('正在捕获电脑当前播放的声音…'), findsOneWidget);
  });

  testWidgets('移动端窄屏（360px 与 320px）下结果页排版自适应无溢出', (tester) async {
    debugDesktopFormFactorOverride = false;
    final backend = _FakeCaptureBackend();
    final player = _FakePlayer();
    final result = IdentifyService.candidateToSong(_candidate());

    for (final width in [360.0, 320.0]) {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1.0;

      await tester.pumpWidget(MaterialApp(
        home: IdentifyPage(
          key: ValueKey(width),
          player: player,
          captureBackend: backend,
          onIdentify: (pcm) async => [result],
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('立即识别'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('重新识别'), findsOneWidget);
      // 无任何 RenderFlex 溢出异常
      expect(tester.takeException(), isNull);
    }

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
