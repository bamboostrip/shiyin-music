// AppLogService 落盘日志：环形缓冲、防抖落盘、超限轮转。
// 动机见类注释——用户侧偶发问题（曲末不跳下一首等）的事后取证通道。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/app_log_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('shiyin_applog_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('log + flush：内容带时间戳写入文件，缓冲清空', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}app.log';
    final service = AppLogService.createForTest(filePath: path);

    service.log('[shiyin][next] 完成处理开始: 歌曲1');
    await service.flush();

    final content = await File(path).readAsString();
    expect(content, contains('[shiyin][next] 完成处理开始: 歌曲1'));
    // 每行前缀 ISO 时间戳（yyyy-MM-ddTHH:mm:ss.mmm）。
    expect(
      content,
      matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3} ', multiLine: true)),
    );
  });

  test('环形缓冲：超过上限只保留最近 N 行', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}app.log';
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
    final path = '${tempDir.path}${Platform.pathSeparator}app.log';
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
    final path = '${tempDir.path}${Platform.pathSeparator}app.log';
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
    TestWidgetsFlutterBinding.ensureInitialized();
    // 无平台通道时 path_provider 抛 MissingPluginException → 静默降级 null。
    final path = await AppLogService.resolveLogFilePath();
    expect(
      path,
      anyOf(isNull, endsWith('logs${Platform.pathSeparator}app.log')),
    );
  });

  test('单条超长日志截断：整段堆栈一行不撑爆内存缓冲', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}app.log';
    final service = AppLogService.createForTest(filePath: path);

    final giant = List.filled(20000, 'x').join();
    service.log(giant);
    await service.flush();

    final content = await File(path).readAsString();
    expect(content, contains('单条截断'));
    // 16KB 上限 + 时间戳/后缀余量：落盘行远小于原 20000 字。
    expect(content.length, lessThan(20000));
  });
}
