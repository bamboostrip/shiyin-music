import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/desktop_system_integration.dart';

void main() {
  group('formatDesktopWindowTitle（窗口标题纯函数）', () {
    test('无播放时回落应用名', () {
      expect(formatDesktopWindowTitle(), '时音');
      expect(formatDesktopWindowTitle(songTitle: null, artist: null), '时音');
      expect(formatDesktopWindowTitle(songTitle: '  ', artist: '歌手'), '时音');
    });

    test('歌名 - 歌手 - 时音', () {
      expect(
        formatDesktopWindowTitle(songTitle: '晴天', artist: '周杰伦'),
        '晴天 - 周杰伦 - 时音',
      );
    });

    test('无歌手时省略歌手段', () {
      expect(formatDesktopWindowTitle(songTitle: '晴天', artist: ''), '晴天 - 时音');
      expect(
        formatDesktopWindowTitle(songTitle: '晴天', artist: '  '),
        '晴天 - 时音',
      );
    });

    test('歌名首尾空白被裁剪', () {
      expect(
        formatDesktopWindowTitle(songTitle: ' 晴天 ', artist: ' 周杰伦 '),
        '晴天 - 周杰伦 - 时音',
      );
    });

    test('自定义应用名（桌面歌词子窗等场景不共用回退值）', () {
      expect(
        formatDesktopWindowTitle(
          songTitle: '晴天',
          artist: '周杰伦',
          appName: '其他窗',
        ),
        '晴天 - 周杰伦 - 其他窗',
      );
    });
  });

  group('下载完成通知文案（纯函数）', () {
    test('单曲：歌名 - 歌手', () {
      expect(
        singleDownloadNotificationBody(songTitle: '晴天', artist: '周杰伦'),
        '晴天 - 周杰伦',
      );
    });

    test('单曲：缺歌手只给歌名', () {
      expect(
        singleDownloadNotificationBody(songTitle: '晴天', artist: ''),
        '晴天',
      );
    });

    test('单曲：歌名/歌手都缺时给兜底文案', () {
      expect(
        singleDownloadNotificationBody(songTitle: '', artist: ''),
        '歌曲已保存到下载目录',
      );
    });

    test('批量：全部成功', () {
      expect(
        batchDownloadNotificationBody(succeeded: 3, failed: 0),
        '已成功下载 3 首歌曲',
      );
    });

    test('批量：部分失败', () {
      expect(
        batchDownloadNotificationBody(succeeded: 2, failed: 1),
        '成功下载 2 首，失败 1 首',
      );
    });

    test('批量：全部失败', () {
      expect(
        batchDownloadNotificationBody(succeeded: 0, failed: 2),
        '下载失败 2 首歌曲',
      );
    });
  });

  group('BatchDownloadTracker（批量只通知一次）', () {
    test('全部成功：结束时回调一次，计数正确', () {
      final results = <({int succeeded, int failed})>[];
      final tracker = BatchDownloadTracker(
        onComplete: (s, f) => results.add((succeeded: s, failed: f)),
      )..begin();

      tracker.trackStarted();
      tracker.trackStarted();
      tracker.trackStarted();
      tracker.trackFinished(succeeded: true);
      tracker.trackFinished(succeeded: true);
      tracker.trackFinished(succeeded: true);

      expect(results, hasLength(1));
      expect(results.single.succeeded, 3);
      expect(results.single.failed, 0);
    });

    test('含失败单元：结束时合并计数回调一次', () {
      final results = <({int succeeded, int failed})>[];
      final tracker = BatchDownloadTracker(
        onComplete: (s, f) => results.add((succeeded: s, failed: f)),
      )..begin();

      for (var i = 0; i < 5; i++) {
        tracker.trackStarted();
      }
      tracker.trackFinished(succeeded: true);
      tracker.trackFinished(succeeded: false);
      tracker.trackFinished(succeeded: true);
      tracker.trackFinished(succeeded: false);
      tracker.trackFinished(succeeded: true);

      expect(results, hasLength(1));
      expect(results.single.succeeded, 3);
      expect(results.single.failed, 2);
    });

    test('地址解析失败（无对应 trackStarted 的守卫外的调用被忽略）', () {
      final results = <({int succeeded, int failed})>[];
      final tracker = BatchDownloadTracker(
        onComplete: (s, f) => results.add((succeeded: s, failed: f)),
      )..begin();

      // 未开始任何单元时的完成事件被丢弃（不会触发负计数/误通知）。
      tracker.trackFinished(succeeded: false);
      expect(results, isEmpty);
    });

    test('全部跳过的批次（无任何单元）不通知', () {
      final results = <({int succeeded, int failed})>[];
      BatchDownloadTracker(
        onComplete: (s, f) => results.add((succeeded: s, failed: f)),
      ).begin();
      expect(results, isEmpty);
    });

    test('新批次 begin() 复位状态', () {
      final results = <({int succeeded, int failed})>[];
      final tracker = BatchDownloadTracker(
        onComplete: (s, f) => results.add((succeeded: s, failed: f)),
      )..begin();
      tracker.trackStarted();
      tracker.trackFinished(succeeded: true);
      expect(results.single.succeeded, 1);

      tracker.begin();
      tracker.trackStarted();
      tracker.trackStarted();
      tracker.trackFinished(succeeded: true);
      tracker.trackFinished(succeeded: true);
      expect(results, hasLength(2));
      expect(results.last.succeeded, 2);
    });
  });

  group('DesktopWindowTitleBinder（标题绑定器）', () {
    late _FakeTitleSource source;
    late List<String> titles;

    setUp(() {
      source = _FakeTitleSource();
      titles = [];
    });

    DesktopWindowTitleBinder buildBinder() => DesktopWindowTitleBinder(
      titleOf: () => source.title,
      artistOf: () => source.artist,
      setTitle: (title) async => titles.add(title),
    );

    test('attach 立即同步标题；无播放回落应用名', () {
      final binder = buildBinder()..attach(source);
      expect(titles, ['时音']);
      binder.detach();
    });

    test('切歌后通知触发标题更新', () {
      final binder = buildBinder()..attach(source);
      source
        ..title = '晴天'
        ..artist = '周杰伦';
      source.notifyListeners();
      expect(titles, ['时音', '晴天 - 周杰伦 - 时音']);
      binder.detach();
    });

    test('无关通知（歌名未变）不重复调用 setTitle', () {
      source
        ..title = '晴天'
        ..artist = '周杰伦';
      final binder = buildBinder()..attach(source);
      expect(titles, ['晴天 - 周杰伦 - 时音']);
      source.notifyListeners();
      source.notifyListeners();
      expect(titles, hasLength(1));
      binder.detach();
    });

    test('detach 后不再更新', () {
      final binder = buildBinder()..attach(source);
      binder.detach();
      source.title = '晴天';
      source.notifyListeners();
      expect(titles, ['时音']);
    });

    test('重复 attach 旧监听被替换，不产生双写', () {
      final binder = buildBinder()..attach(source);
      binder.attach(source);
      source.title = '晴天';
      source.notifyListeners();
      expect(titles, ['时音', '晴天 - 时音']);
      binder.detach();
      binder.detach(); // 幂等
    });
  });

  group('DesktopDownloadNotifier / AutoStartManager 接口（fake 可注入）', () {
    test('fake notifier 捕获调用', () {
      final notifier = _FakeDownloadNotifier();
      notifier.notifyDownloadCompleted(title: '下载完成', body: '晴天 - 周杰伦');
      expect(notifier.calls, hasLength(1));
      expect(notifier.calls.single.title, '下载完成');
      expect(notifier.calls.single.body, '晴天 - 周杰伦');
    });

    test('fake auto-start 记录 register/unregister', () async {
      final manager = _FakeAutoStartManager();
      await manager.setEnabled(true);
      expect(manager.writes, [true]);
      await manager.setEnabled(false);
      expect(manager.writes, [true, false]);
      expect(await manager.isEnabled(), false);
    });
  });
}

class _FakeTitleSource extends ChangeNotifier {
  String? title;
  String? artist;
}

class _FakeDownloadCall {
  const _FakeDownloadCall(this.title, this.body);
  final String title;
  final String body;
}

class _FakeDownloadNotifier implements DesktopDownloadNotifier {
  final List<_FakeDownloadCall> calls = [];

  @override
  void notifyDownloadCompleted({required String title, required String body}) {
    calls.add(_FakeDownloadCall(title, body));
  }
}

class _FakeAutoStartManager implements AutoStartManager {
  final List<bool> writes = [];
  bool _enabled = false;

  @override
  Future<bool> isEnabled() async => _enabled;

  @override
  Future<void> setEnabled(bool enabled) async {
    writes.add(enabled);
    _enabled = enabled;
  }
}
