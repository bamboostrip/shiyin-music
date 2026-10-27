// AppLogService 落盘日志：环形缓冲、防抖落盘、超限轮转（旧版用例，保持绿）
// + 结构化级别/tag、实时流、统计、全量导出、筛选导出、脱敏、清空、
// 旧格式行兼容解析（新版用例）。
// 动机见类注释——用户侧偶发问题（曲末不跳下一首等）的事后取证通道。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/app_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('shiyin_applog_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String logPath() => '${tempDir.path}${Platform.pathSeparator}app.log';

  // ===== 旧版用例（契约不变，必须保持绿）=====

  test('log + flush：内容带时间戳写入文件，缓冲清空', () async {
    final path = logPath();
    final service = AppLogService.createForTest(filePath: path);

    service.log('[shiyin][next] 完成处理开始: 歌曲1');
    await service.flush();

    final content = await File(path).readAsString();
    expect(content, contains('[shiyin][next] 完成处理开始: 歌曲1'));
    // 每行前缀 ISO 时间戳（yyyy-MM-ddTHH:mm:ss.mmm）。
    expect(
      content,
      matches(
        RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3} ',
          multiLine: true,
        ),
      ),
    );
  });

  test('环形缓冲：超过上限只保留最近 N 行', () async {
    final path = logPath();
    final service = AppLogService.createForTest(
      filePath: path,
      maxBufferLines: 3,
    );

    for (var i = 1; i <= 5; i++) {
      service.log('line-$i');
    }
    await service.flush();

    final content = await File(path).readAsString();
    expect(content, isNot(contains('line-1')));
    expect(content, isNot(contains('line-2')));
    expect(content, contains('line-3'));
    expect(content, contains('line-5'));
  });

  test('超限轮转：旧文件改名为 .old 保留一代，新文件从空开始', () async {
    final path = logPath();
    final service = AppLogService.createForTest(
      filePath: path,
      maxFileBytes: 32,
    );

    service.log('first-generation-log-line');
    await service.flush();
    // 第二次 flush 前文件已超 32 字节 → 触发轮转。
    service.log('second-generation-log-line');
    await service.flush();

    final old = File('$path.old');
    expect(await old.exists(), isTrue, reason: '上一代日志应轮转为 .old');
    expect(await old.readAsString(), contains('first-generation-log-line'));

    final current = await File(path).readAsString();
    expect(current, contains('second-generation-log-line'));
    expect(current, isNot(contains('first-generation-log-line')));
  });

  test('重复 flush 安全；flush 后新日志会再排队落盘', () async {
    final path = logPath();
    final service = AppLogService.createForTest(filePath: path);

    service.log('a');
    await service.flush();
    await service.flush(); // 空缓冲重复 flush 不抛错
    service.log('b');
    await service.flush();

    final content = await File(path).readAsString();
    expect(content, contains('a'));
    expect(content, contains('b'));
  });

  test('resolveLogFilePath 返回 logs 目录下的 app.log', () async {
    // 无平台通道时 path_provider 抛 MissingPluginException → 静默降级 null。
    final path = await AppLogService.resolveLogFilePath();
    expect(
      path,
      anyOf(isNull, endsWith('logs${Platform.pathSeparator}app.log')),
    );
  });

  test('单条超长日志截断：整段堆栈一行不撑爆内存缓冲', () async {
    final path = logPath();
    final service = AppLogService.createForTest(filePath: path);

    final giant = List.filled(20000, 'x').join();
    service.log(giant);
    await service.flush();

    final content = await File(path).readAsString();
    expect(content, contains('单条截断'));
    // 16KB 上限 + 时间戳/后缀余量：落盘行远小于原 20000 字。
    expect(content.length, lessThan(20000));
  });

  // ===== 新增：数据结构 / 级别 / tag / 解析 =====

  test('LogEntry.format 带时间戳、级别与 tag；toLogLine 落盘不带 tag', () {
    final entry = LogEntry(
      timestamp: DateTime(2026, 10, 26, 12, 34, 56, 789),
      level: LogLevel.error,
      message: '播放失败',
      tag: 'player',
    );

    final formatted = entry.format();
    expect(formatted, startsWith('2026-10-26T12:34:56.789 '));
    expect(formatted, contains('[ERROR]'));
    expect(formatted, contains('[player]'));
    expect(formatted, contains('播放失败'));

    final line = entry.toLogLine();
    expect(line, startsWith('2026-10-26T12:34:56.789 [ERROR] '));
    expect(line, contains('播放失败'));
    expect(line, isNot(contains('[player]')), reason: '落盘行保持旧格式同构，不额外插 tag');
  });

  test('record：显式级别/tag 进入内存缓存并推送到广播流', () async {
    final service = AppLogService.createForTest(filePath: logPath());
    final received = <LogEntry>[];
    final sub = service.logStream.listen(received.add);

    service.record('Hello 诊断', level: LogLevel.warning, tag: 'Test');
    service.record('An error occurred');

    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    await service.flush(); // 清掉防抖 timer，避免测试结束后仍有挂起定时器

    expect(service.recentEntries.length, 2);
    expect(service.recentEntries[0].level, LogLevel.warning);
    expect(service.recentEntries[0].tag, 'Test');
    expect(
      service.recentEntries[1].level,
      LogLevel.error,
      reason: '未显式给级别时按关键词推断',
    );
    expect(received.length, 2);
    expect(received.first.message, 'Hello 诊断');
  });

  test('级别推断与 tag 前缀解析', () async {
    final service = AppLogService.createForTest(filePath: logPath());
    service.record('下载失败：网络不可达');
    service.record('请求超时，稍后重试');
    service.record('普通播放日志');
    service.record('[时音][player] 完成处理开始');
    service.record('[SYNOTIF] 通知渠道定向');
    service.record('没有前缀的消息');
    await service.flush();

    expect(service.recentEntries[0].level, LogLevel.error);
    expect(service.recentEntries[1].level, LogLevel.warning);
    expect(service.recentEntries[2].level, LogLevel.info);
    expect(service.recentEntries[3].tag, 'player');
    expect(service.recentEntries[4].tag, 'SYNOTIF');
    expect(service.recentEntries[5].tag, isNull);
  });

  test('parseLogLine：新格式往返；旧格式回退 info；诊断头返回 null', () {
    final entry = LogEntry(
      timestamp: DateTime(2026, 10, 26, 12, 34, 56, 789),
      level: LogLevel.warning,
      message: '[时音][player] 缓冲不足',
      tag: 'player',
    );
    final parsed = AppLogService.parseLogLine(entry.toLogLine());
    expect(parsed, isNotNull);
    expect(parsed!.level, LogLevel.warning);
    expect(parsed.message, '[时音][player] 缓冲不足');
    expect(parsed.timestamp, entry.timestamp);

    final legacy = AppLogService.parseLogLine('2026-10-26T12:00:00.000 旧格式消息');
    expect(legacy, isNotNull);
    expect(legacy!.level, LogLevel.info, reason: '旧版行无级别，按 info 回退');
    expect(legacy.message, '旧格式消息');
    expect(legacy.timestamp, DateTime(2026, 10, 26, 12));

    expect(
      AppLogService.parseLogLine('================================='),
      isNull,
    );
    expect(AppLogService.parseLogLine(''), isNull);
  });

  test('内存环形缓存上限 1000 条，超出丢最旧', () async {
    final service = AppLogService.createForTest(filePath: logPath());
    for (var i = 0; i < 1005; i++) {
      service.record('entry-$i');
    }
    await service.flush();

    expect(service.recentEntries.length, 1000);
    expect(service.recentEntries.first.message, 'entry-5');
    expect(service.recentEntries.last.message, 'entry-1004');
  });

  // ===== 新增：脱敏 =====

  test('redactSensitive：token/t1/session/userid/cookie/Authorization 值脱敏', () {
    const raw =
        'GET https://api.example/x?token=ABC123&t1=zzz&userid=42'
        '&foo=bar&cookie=sid%3D1';
    final redacted = AppLogService.redactSensitive(raw);

    expect(redacted, contains('token=***'));
    expect(redacted, contains('t1=***'));
    expect(redacted, contains('userid=***'));
    expect(redacted, contains('cookie=***'));
    expect(redacted, contains('foo=bar'), reason: '非敏感参数保留');
    expect(redacted, isNot(contains('ABC123')));
    expect(redacted, isNot(contains('zzz')));

    final header = AppLogService.redactSensitive(
      'Authorization: Bearer abc.def.ghi',
    );
    expect(header.toLowerCase(), contains('authorization: ***'));
    expect(header, isNot(contains('abc.def.ghi')));

    const plain = '普通日志没有敏感信息，只是歌名：晴天';
    expect(AppLogService.redactSensitive(plain), plain);
  });

  // ===== 新增：统计 / 导出 / 复制 / 清空 =====

  test('getLogStats：文件数/体积/内存条数/时间范围', () async {
    final path = logPath();
    final service = AppLogService.createForTest(filePath: path);
    service.record('统计用例-a');
    service.record('统计用例-b');
    await service.flush();

    final stats = await service.getLogStats();
    expect(stats.fileCount, greaterThanOrEqualTo(1));
    expect(stats.totalBytes, greaterThan(0));
    expect(stats.entryCount, 2);
    expect(stats.formattedSize, isNotEmpty);
    expect(stats.earliestDate, isNotNull);
    expect(stats.latestDate, isNotNull);
  });

  test('全量导出：读取全部历史文件（含 .old 归档）且不截断', () async {
    final path = logPath();
    final service = AppLogService.createForTest(
      filePath: path,
      maxFileBytes: 32, // 强制每次 flush 前轮转，制造归档
    );

    service.record('alpha-marker-第一代');
    await service.flush();
    service.record('beta-marker-第二代');
    await service.flush();
    expect(await File('$path.old').exists(), isTrue);

    final text = await service.exportLogsText();
    expect(text, contains('时音诊断日志'));
    expect(text, contains('App Version'));
    expect(text, contains('alpha-marker-第一代'), reason: '归档内容也要包含');
    expect(text, contains('beta-marker-第二代'));
    expect(
      text.indexOf('alpha-marker-第一代'),
      lessThan(text.indexOf('beta-marker-第二代')),
      reason: '按时间从旧到新拼接',
    );
    expect(text, isNot(contains('截断')));
  });

  test('导出 maxLines：只保留最近 N 行并注明截断', () async {
    final path = logPath();
    final service = AppLogService.createForTest(filePath: path);
    for (var i = 1; i <= 5; i++) {
      service.record('export-line-$i');
    }
    await service.flush();

    final text = await service.exportLogsText(maxLines: 2);
    expect(text, contains('截断'));
    expect(text, contains('export-line-5'));
    expect(text, isNot(contains('export-line-1')));
  });

  test('exportLogsToFile：导出全量到注入目录，返回 .txt 路径', () async {
    final path = logPath();
    final service = AppLogService.createForTest(filePath: path);
    service.record('file-export-marker');
    await service.flush();

    final exportDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}export-full',
    );
    final savedPath = await service.exportLogsToFile(
      fullLogs: true,
      customDestinationDir: exportDir.path,
    );
    expect(savedPath, isNotNull);
    expect(savedPath, contains('shiyin_full_log'));
    expect(savedPath, endsWith('.txt'));

    final file = File(savedPath!);
    expect(await file.exists(), isTrue);
    final content = await file.readAsString();
    expect(content, contains('file-export-marker'));
    expect(content, contains('时音诊断日志'));
  });

  test('exportLogsToFile：筛选结果（customContent）单独导出且脱敏', () async {
    final service = AppLogService.createForTest(filePath: logPath());
    final exportDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}export-filter',
    );
    final savedPath = await service.exportLogsToFile(
      fullLogs: false,
      customContent: '筛选行-A\n[2026-10-26T12:00:00.000] [ERROR] token=SECRET',
      customDestinationDir: exportDir.path,
    );
    expect(savedPath, isNotNull);
    expect(savedPath, contains('shiyin_filtered_log'));

    final content = await File(savedPath!).readAsString();
    expect(content, contains('筛选行-A'));
    expect(content, contains('token=***'));
    expect(content, isNot(contains('SECRET')));
  });

  test('copyLogsToClipboard：全量与筛选文本都走剪贴板', () async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final service = AppLogService.createForTest(filePath: logPath());
    service.record('clipboard-marker');
    await service.flush();

    expect(await service.copyLogsToClipboard(), isTrue);
    expect(copied, contains('clipboard-marker'));
    expect(copied, contains('时音诊断日志'));

    expect(await service.copyLogsToClipboard(customContent: '只有筛选结果'), isTrue);
    expect(copied, '只有筛选结果');
  });

  test('clearLogs：删除全部文件、清空内存，并开启新会话', () async {
    final path = logPath();
    final service = AppLogService.createForTest(filePath: path);
    service.record('to-be-cleared');
    await service.flush();
    expect(await File(path).exists(), isTrue);

    await service.clearLogs();
    expect(await File(path).exists(), isFalse);
    expect(await File('$path.old').exists(), isFalse);
    expect(service.recentEntries.length, 1);
    expect(service.recentEntries.single.message, contains('日志已清空'));

    // 清空后统计会触发一次 flush，重新建立带诊断头的新文件。
    final stats = await service.getLogStats();
    expect(stats.fileCount, 1);
    expect(stats.totalBytes, greaterThan(0));
    final content = await File(path).readAsString();
    expect(content, contains('时音诊断日志'));
    expect(content, contains('日志已清空'));
  });

  test('归档滚动：多代 .old.N 文件名递延且总量有界', () async {
    final path = logPath();
    final service = AppLogService.createForTest(
      filePath: path,
      maxFileBytes: 32,
      maxArchivedFiles: 3,
    );

    for (var i = 1; i <= 4; i++) {
      service.record('generation-marker-$i');
      await service.flush();
    }

    // 4 次写入 + 每次超限轮转：当前文件 + .old + .old.1 + .old.2。
    final files = <String>[path, '$path.old', '$path.old.1', '$path.old.2'];
    var existing = 0;
    for (final file in files) {
      if (await File(file).exists()) existing++;
    }
    expect(existing, lessThanOrEqualTo(4), reason: '最多 live + 3 归档');
    expect(await File('$path.old.2').exists(), isTrue);
    expect(await File('$path.old.3').exists(), isFalse);

    final text = await service.exportLogsText();
    expect(text, contains('generation-marker-4'));
    expect(text, contains('generation-marker-1'), reason: '最老归档在清理前应仍可导出');
  });

  // 放在最后：会永久接管本测试进程的 debugPrint，避免影响前面用例。
  test('installDebugPrintHook：debugPrint 内容进入单例内存缓存', () async {
    AppLogService.installDebugPrintHook();
    debugPrint('[smoke][hook] debugPrint 捕获用例');

    expect(
      AppLogService.instance.recentEntries.any(
        (entry) => entry.message.contains('debugPrint 捕获用例'),
      ),
      isTrue,
    );
    expect(
      AppLogService.instance.recentEntries.any((entry) => entry.tag == 'hook'),
      isTrue,
      reason: 'tag 从 [smoke][hook] 前缀解析',
    );

    // 清理单例缓存，避免染料测试进程后续输出进入内存缓存。
    await AppLogService.instance.clearLogs();
  });
}
