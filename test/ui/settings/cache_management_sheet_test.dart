import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/ui/settings/cache_management_sheet.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

const _defaultDir = r'C:\Users\Test\Downloads\shiyin_downloads';
const _customDir = r'D:\MyMusic\shiyin_downloads';

/// 只覆写目录信息块 / 缓存弹层实际调用的成员，避免真实 DownloadService
/// （prefs、path_provider、网络）与目录树遍历。
class _FakeDownloads extends ChangeNotifier implements DownloadController {
  _FakeDownloads({
    this.dirPath = _defaultDir,
    this.customDir,
    this.throwOnPath = false,
  });

  final String dirPath;
  final String? customDir;
  final bool throwOnPath;

  @override
  Future<String> getDownloadDirPath() async {
    if (throwOnPath) throw StateError('download dir unavailable');
    return dirPath;
  }

  @override
  Future<String?> getCustomDownloadDir() async => customDir;

  @override
  Future<int> getDownloadDirSize() async => 5 * 1024 * 1024;

  @override
  Future<int> getPlayCacheDirSize() async => 1024 * 1024;

  @override
  int get playCacheLimit => 300 * 1024 * 1024;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(body: SizedBox(width: 420, child: child)),
    );
  }

  group('缓存弹层「下载存储目录」信息块', () {
    testWidgets('有自定义目录时显示路径 + (自定义) 标记', (tester) async {
      await tester.pumpWidget(
        wrap(
          DownloadDirInfo(
            downloads: _FakeDownloads(
              dirPath: _customDir,
              customDir: r'D:\MyMusic',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('下载存储目录'), findsOneWidget);
      expect(find.text(_customDir), findsOneWidget);
      expect(find.text('(自定义)'), findsOneWidget);
      expect(find.byTooltip('复制路径'), findsOneWidget);
    });

    testWidgets('未自定义（跟随系统默认）时只显示路径，不显示自定义标记', (tester) async {
      await tester.pumpWidget(
        wrap(DownloadDirInfo(downloads: _FakeDownloads())),
      );
      await tester.pumpAndSettle();

      expect(find.text('下载存储目录'), findsOneWidget);
      expect(find.text(_defaultDir), findsOneWidget);
      expect(find.text('(自定义)'), findsNothing);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    });

    testWidgets('路径获取失败时静默显示「暂不可用」，不崩溃且不可复制', (tester) async {
      await tester.pumpWidget(
        wrap(DownloadDirInfo(downloads: _FakeDownloads(throwOnPath: true))),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('暂不可用'), findsOneWidget);
      expect(find.text('下载存储目录'), findsOneWidget);
      expect(find.byTooltip('复制路径'), findsNothing);
    });

    testWidgets('点击复制按钮把路径写入剪贴板', (tester) async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        wrap(DownloadDirInfo(downloads: _FakeDownloads())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('复制路径'));
      await tester.pump();

      final clipboardCalls = calls.where(
        (c) => c.method == 'Clipboard.setData',
      );
      expect(clipboardCalls, hasLength(1));
      expect((clipboardCalls.first.arguments as Map)['text'], _defaultDir);
    });

    testWidgets('剪贴板写入失败时提示「复制失败」且不抛异常', (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'clipboard-unavailable');
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      // 走真实 Toast 通道：需要把 navigatorKey 挂到 MaterialApp 才能拿到 Overlay。
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: Toast.navigatorKey,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                child: DownloadDirInfo(downloads: _FakeDownloads()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('复制路径'));
      // 先让失败的平台通道调用落到 catch，再等 Toast 淡入。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(tester.takeException(), isNull);
      expect(find.text('复制失败，请稍后重试'), findsOneWidget);
      // 失败时不能误报成功文案。
      expect(find.text('下载目录路径已复制'), findsNothing);

      // 错误 Toast 3 秒后自动消失：pump 完计时器与退场动画，
      // 避免测试结束时留下 pending timer。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('复制失败，请稍后重试'), findsNothing);
    });
  });

  group('CacheManagementSheet 内嵌目录信息块', () {
    testWidgets('下载文件条目下方展示下载目录路径（不提供更改/恢复默认双入口）', (tester) async {
      await tester.pumpWidget(
        wrap(
          CacheManagementSheet(
            downloads: _FakeDownloads(customDir: r'D:\MyMusic'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('下载文件'), findsOneWidget);
      expect(find.text('下载存储目录'), findsOneWidget);
      expect(find.text(_defaultDir), findsOneWidget);
      expect(find.text('(自定义)'), findsOneWidget);
      // fork 桌面设置已有下载位置入口：缓存弹层不重复放「更改目录 / 恢复默认」。
      expect(find.text('更改目录'), findsNothing);
      expect(find.text('恢复默认'), findsNothing);
    });

    testWidgets('无下载控制器时整个目录信息块不渲染', (tester) async {
      await tester.pumpWidget(wrap(const CacheManagementSheet()));

      expect(find.text('下载存储目录'), findsNothing);
      expect(find.text('暂不可用'), findsNothing);
    });

    testWidgets('桌面 Dialog 形态：低窗口高度下内容可滚动、不溢出', (tester) async {
      tester.view.physicalSize = const Size(800, 520);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Dialog(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                    child: CacheManagementSheet(
                      downloads: _FakeDownloads(customDir: r'D:\MyMusic'),
                      isDialog: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 桌面窗口最小 360×520：新增目录块后内容可能超过可用高度，
      // Dialog 形态必须可滚动而不是 RenderFlex 溢出。
      expect(tester.takeException(), isNull);
      await tester.drag(find.text('下载存储目录'), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('播放缓存上限'), findsOneWidget);
    });
  });
}
