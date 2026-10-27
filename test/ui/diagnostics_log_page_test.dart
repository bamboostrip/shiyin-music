// 诊断日志页：筛选纯函数单测 + 页面骨架 widget 冒烟测试。
// 页面数据源是 AppLogService 单例（内存缓存 + 广播流），此处不注入假实现，
// 只验证筛选逻辑与静态骨架，避免与落盘/剪贴板等 IO 用例耦合。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/app_log_service.dart';
import 'package:shiyin_music/ui/pages/diagnostics_log_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<LogEntry> buildEntries() => [
    LogEntry(
      timestamp: DateTime(2026, 10, 27, 9),
      level: LogLevel.info,
      message: '播放正常',
      tag: 'player',
    ),
    LogEntry(
      timestamp: DateTime(2026, 10, 27, 9, 1),
      level: LogLevel.error,
      message: '播放失败: 引擎超时',
      tag: 'player',
    ),
    LogEntry(
      timestamp: DateTime(2026, 10, 27, 9, 2),
      level: LogLevel.warning,
      message: '下载缓存降级',
      tag: 'download',
    ),
  ];

  group('DiagnosticsLogPage.filterEntries', () {
    test('无筛选返回全部（且是新列表，不改动入参）', () {
      final entries = buildEntries();
      final filtered = DiagnosticsLogPage.filterEntries(entries);
      expect(filtered.length, 3);
      expect(identical(filtered, entries), isFalse);
    });

    test('按级别筛选', () {
      final entries = buildEntries();
      final errors = DiagnosticsLogPage.filterEntries(
        entries,
        level: LogLevel.error,
      );
      expect(errors.length, 1);
      expect(errors.single.message, contains('播放失败'));

      final warnings = DiagnosticsLogPage.filterEntries(
        entries,
        level: LogLevel.warning,
      );
      expect(warnings.single.tag, 'download');
    });

    test('按关键词匹配消息', () {
      final entries = buildEntries();
      final matched = DiagnosticsLogPage.filterEntries(entries, keyword: '播放');
      expect(matched.length, 2);
    });

    test('按关键词匹配 tag，且大小写不敏感', () {
      final entries = buildEntries();
      expect(
        DiagnosticsLogPage.filterEntries(entries, keyword: 'download').length,
        1,
      );
      expect(
        DiagnosticsLogPage.filterEntries(entries, keyword: 'PLAYER').length,
        2,
      );
    });

    test('级别与关键词同时生效', () {
      final entries = buildEntries();
      final matched = DiagnosticsLogPage.filterEntries(
        entries,
        keyword: '播放',
        level: LogLevel.warning,
      );
      expect(matched, isEmpty);
    });
  });

  testWidgets('页面骨架：标题、隐私提示、空态与操作按钮可见', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DiagnosticsLogPage()));
    await tester.pump();
    await tester.pump();

    expect(find.text('运行日志与诊断'), findsOneWidget);
    expect(find.textContaining('日志可能包含歌名'), findsOneWidget);
    // 测试环境 path_provider 不可用 → 路径降级文案；同时覆盖空态。
    expect(find.textContaining('日志落盘未启用'), findsOneWidget);
    expect(find.text('暂无匹配的日志记录'), findsOneWidget);
    expect(find.text('复制全部'), findsOneWidget);
    expect(find.text('复制筛选'), findsOneWidget);
    expect(find.text('导出全部'), findsOneWidget);
    expect(find.text('导出筛选'), findsOneWidget);
    expect(find.textContaining('已显示 0 / 共'), findsOneWidget);
  });
}
