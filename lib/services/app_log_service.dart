import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 轻量落盘日志：内存环形缓冲 + 防抖追加写。
///
/// 动机：线上「曲末不跳下一首」「通知按钮失灵」这类用户侧偶发问题，此前
/// 诊断输出只进 logcat（debugPrint），进程一退现场全无，事后无法取证。
/// main() 里调用 [install] 接管 `debugPrint` 后，全 app 现有诊断通道
/// （`[shiyin][next]` / `[SYNOTIF]` / `[时音][player]` / AudioHandler 代理
/// 错误）零改动同步落一份到文件。
///
/// - 文件位置与下载目录同源（Android 取 app 专属外部存储——文件管理器
///   可见、无需权限；桌面取文档目录，见 [resolveLogFilePath]），用户用
///   文件管理器即可把日志发出来，不需要 root 或 adb；
/// - 上限三保险：内存 [_kMaxBufferLines] 行环形缓冲；单条超
///   [_kMaxMessageChars] 截断（整段堆栈一次 debugPrint 即一行，
///   不截的话 2000 行巨栈内存无界）；文件超 [_kMaxFileBytes]
///   轮转为 `.old`（保留上一代），磁盘占用有界（≈1MB）；
/// - 任何落盘失败一律静默降级（丢日志不丢功能），绝不反噬播放主流程。
class AppLogService {
  AppLogService._({
    required String? filePath,
    required int maxBufferLines,
    required int maxFileBytes,
  }) : _logFilePath = filePath,
       _maxBufferLines = maxBufferLines,
       _maxFileBytes = maxFileBytes;

  static final AppLogService instance = AppLogService._(
    filePath: null,
    maxBufferLines: _kMaxBufferLines,
    maxFileBytes: _kMaxFileBytes,
  );

  static const int _kMaxBufferLines = 2000;
  static const int _kMaxFileBytes = 512 * 1024;

  /// 单条日志上限：main 里整段堆栈一次 debugPrint 即单行（见 fatal 分支），
  /// 不截断的话 2000 行“巨行”内存无界。16KB 足够保留有效帧，超长只丢尾部。
  static const int _kMaxMessageChars = 16 * 1024;
  static const Duration _flushInterval = Duration(milliseconds: 500);

  @visibleForTesting
  static AppLogService createForTest({
    required String filePath,
    int maxBufferLines = 64,
    int maxFileBytes = 1024,
  }) => AppLogService._(
    filePath: filePath,
    maxBufferLines: maxBufferLines,
    maxFileBytes: maxFileBytes,
  );

  final int _maxBufferLines;
  final int _maxFileBytes;

  final List<String> _pending = [];
  Timer? _flushTimer;
  bool _flushing = false;
  String? _logFilePath;

  /// 当前日志文件路径；未就绪（路径解析中/失败）为 null。
  String? get logFilePath => _logFilePath;

  /// 解析日志文件路径（含 logs 目录创建）。失败返回 null（禁用落盘）。
  static Future<String?> resolveLogFilePath() async {
    try {
      final Directory base;
      if (!kIsWeb && Platform.isAndroid) {
        // app 专属外部存储：文件管理器可见、无需存储权限（与下载目录同源）。
        base =
            await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
      } else {
        base = await getApplicationDocumentsDirectory();
      }
      final dir = Directory('${base.path}${Platform.pathSeparator}logs');
      await dir.create(recursive: true);
      return '${dir.path}${Platform.pathSeparator}app.log';
    } catch (_) {
      return null;
    }
  }

  /// 初始化单例并接管 debugPrint。接住路径解析失败（返回 null 只禁用落盘，
  /// 控制台输出不受影响），绝不阻断启动。
  static Future<void> install() async {
    installDebugPrintHook();
    instance._logFilePath = await resolveLogFilePath();
  }

  /// 接管全局 `debugPrint`：先落本服务，再走原实现（保留 logcat 输出与
  /// 节流语义）。必须在 flutter binding 就绪后调用（main 已 ensureInitialized）。
  static void installDebugPrintHook() {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        instance.log(message);
      }
      original(message, wrapWidth: wrapWidth);
    };
  }

  /// 追加一条日志（自动加毫秒级时间戳）。任意线程安全仅限主 isolate——
  /// 与 debugPrint 的调用约定一致。
  void log(String message) {
    if (message.length > _kMaxMessageChars) {
      message =
          '${message.substring(0, _kMaxMessageChars)}…（单条截断，共${message.length}字）';
    }
    final timestamp = DateTime.now().toIso8601String();
    _pending.add('${timestamp.substring(0, 23)} $message');
    while (_pending.length > _maxBufferLines) {
      _pending.removeAt(0);
    }
    _flushTimer ??= Timer(_flushInterval, _onFlushTimer);
  }

  /// 立即把内存缓冲写入磁盘（进程退出前/测试用）。重复调用安全。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_flushing) return;
    await _flushNow();
  }

  void _onFlushTimer() {
    _flushTimer = null;
    unawaited(flush());
  }

  Future<void> _flushNow() async {
    if (_pending.isEmpty || _logFilePath == null) return;
    _flushing = true;
    try {
      final file = File(_logFilePath!);
      // 轮转：超限把当前文件改名 .old 重新开始（保留上一代供排查）。
      if (await file.exists() && await file.length() > _maxFileBytes) {
        final old = File('${_logFilePath!}.old');
        if (await old.exists()) {
          await old.delete();
        }
        await file.rename(old.path);
      }
      // join 与 clear 之间无 await：事件循环单线程，不存在新日志插队。
      final text = '${_pending.join('\n')}\n';
      _pending.clear();
      await file.writeAsString(text, mode: FileMode.append, flush: false);
    } catch (_) {
      // 落盘失败静默：日志通道绝不能反噬播放主流程。
    } finally {
      _flushing = false;
      // 写入期间又有新日志且没有已排定的 timer：再排一轮。
      if (_pending.isNotEmpty && _flushTimer == null) {
        _flushTimer = Timer(_flushInterval, _onFlushTimer);
      }
    }
  }
}
