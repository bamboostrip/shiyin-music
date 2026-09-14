import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/song.dart';
import 'package:shiyin_music/services/identify_service.dart';
// api.dart 只 import 不 re-export IdentifyCandidate,需直接引入声明文件
// (与 identify_service.dart 同款做法,测试构造 fake 候选用)。
import 'package:shiyin_music/src/rust/services/identify.dart' show IdentifyCandidate;
import 'package:shiyin_music/ui/pages/identify_page.dart';

IdentifyCandidate _candidate() => IdentifyCandidate(
      name: '晴天',
      singer: '周杰伦',
      hash: 'abc123',
      albumAudioId: '1',
      albumId: '',
      albumName: '',
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

class _FakePlayer implements PlayerController {
  final List<Song> played = [];
  @override
  Future<void> playSong(Song song,
      {List<Song>? queue,
      bool isRetry = false,
      Duration? initialPosition,
      bool preserveClimax = false}) async {
    played.add(song);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('打开即开始采集,识别结果可点击并触发播放', (tester) async {
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
    // 注意:聆听动画是 repeat() 控制器,匹配阶段有转圈——都不能 pumpAndSettle,
    // 一律用带时长的 pump 推进。
    await tester.pump(); // 首帧:进入 listening 并 start()
    expect(backend.startCalls, 1);
    await tester.pump(const Duration(seconds: 13)); // 越过 12s 自动提交
    await tester.pump(const Duration(milliseconds: 300)); // 结果帧渲染

    // 结果列表出现歌名
    expect(find.text('晴天'), findsOneWidget);
    // 点击结果 → playSong 被调用
    await tester.tap(find.text('晴天'));
    await tester.pump(const Duration(milliseconds: 300)); // 返回过渡走完
    expect(player.played.single.hash, 'abc123');
    // 再推一秒让页面完全出树(pop 过渡结束 → 移除路由 → dispose):关页即停
    // 采集——桌面快照只取不停流,此断言即回归守卫。
    await tester.pump(const Duration(seconds: 1));
    // 后端启动过一次,关页后 cancel 恰好一次
    expect(backend.startCalls, 1);
    expect(backend.cancelCalls, 1);
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
    await tester.pump(const Duration(seconds: 13));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('未识别到歌曲'), findsOneWidget);
  });
}
