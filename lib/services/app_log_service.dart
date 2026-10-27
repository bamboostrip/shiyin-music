import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';

/// 日志级别。落盘行用英文大写标签，页面按级别筛选/着色。
enum LogLevel { debug, info, warning, error }

/// 级别展示标签（落盘、导出与页面共用）。
extension LogLevelLabel on LogLevel {
  /// 大写英文标签：DEBUG/INFO/WARNING/ERROR。
  String get label => switch (this) {
    LogLevel.debug => 'DEBUG',
    LogLevel.info => 'INFO',
    LogLevel.warning => 'WARNING',
    LogLevel.error => 'ERROR',
  };
}

/// 单条日志（内存环形缓存与实时流的最小单元）。
class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.tag,
  });

  final DateTime timestamp;
  final LogLevel level;
  final String message;

  /// 从 `[频道][子频道]` 前缀解析出的 tag（如 `player`/`SYNOTIF`），可空。
  final String? tag;

  /// 落盘单行文本：`<ISO 时间戳> [LEVEL] <原始消息>`。
  ///
  /// 保持「时间戳在最前、与旧版格式同构」，因此旧归档与新行可在同一文件
  /// 混排（旧行解析时按 info 回退，见 [AppLogService.parseLogLine]）。
  String toLogLine() =>
      '${formatTimestamp(timestamp)} [${level.label}] $message';

  /// 页面展示/筛选导出用文本，额外带 tag 便于定位通道。
  String format({bool includeTag = true}) {
    final tagPart = includeTag && tag != null && tag!.isNotEmpty
        ? ' [$tag]'
        : '';
    return '${formatTimestamp(timestamp)} [${level.label}]$tagPart $message';
  }

  /// 毫秒级 ISO 时间戳（`yyyy-MM-ddTHH:mm:ss.mmm`），与旧版落盘格式一致。
  static String formatTimestamp(DateTime dt) =>
      dt.toIso8601String().substring(0, 23);
}

/// 本地日志统计（文件数/总占用/内存条数/文件修改时间范围）。
class LogStats {
  const LogStats({
    required this.fileCount,
    required this.totalBytes,
    required this.entryCount,
    this.earliestDate,
    this.latestDate,
  });

  final int fileCount;
  final int totalBytes;

  /// 内存环形缓存中的条数（不是磁盘行数，磁盘行数未做逐行统计）。
  final int entryCount;
  final DateTime? earliestDate;
  final DateTime? latestDate;

  /// 人类可读体积：`B`/`KB`/`MB`。
  String get formattedSize {
    if (totalBytes < 1024) return '$totalBytes B';
    if (totalBytes < 1024 * 1024) {
      return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(totalBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

/// 全局运行日志与诊断服务：内存环形缓存 + 实时流 + 有界落盘 + 导出。
///
/// 动机：线上「曲末不跳下一首」「通知按钮失灵」这类用户侧偶发问题，此前
/// 诊断输出只进 logcat（debugPrint），进程一退现场全无，事后无法取证；即便
/// 落了盘，用户也拿不到（Android 11+ 的 `Android/data/<pkg>` 文件管理器基本
/// 不可见）。本服务在保留原「落盘 + debugPrint 接管」能力的基础上补齐
/// 结构化日志（级别/tag）、统计与用户侧导出通道。
///
/// - 文件位置与下载目录同源（Android 取 app 专属外部存储，桌面取文档目录，
///   见 [resolveLogFilePath]）；导出目录见 [resolveExportDirectory]
///   （Android 用 app 专属外部目录，桌面用系统下载目录，**绝不写公共
///   Download、不新增存储权限**）；
/// - 上限四保险：内存 [_kMaxRecentEntries] 条环形缓存；待写缓冲
///   [_kMaxBufferLines] 行；单条超 [_kMaxMessageChars] 截断（整段堆栈一次
///   debugPrint 即一行，不截的话巨行内存无界）；文件超 [_kMaxFileBytes]
///   轮转为 `.old`/`.old.N` 归档（最多 [_kMaxArchivedFiles] 个），磁盘占用
///   有界（≈4MB）；
/// - 任何落盘/导出失败一律静默降级（丢日志不丢功能），绝不反噬播放主流程。
class AppLogService {
  AppLogService._({
    required String? filePath,
    required int maxBufferLines,
    required int maxFileBytes,
    required int maxArchivedFiles,
  }) : _logFilePath = filePath,
       _maxBufferLines = maxBufferLines,
       _maxFileBytes = maxFileBytes,
       _maxArchivedFiles = maxArchivedFiles;

  static final AppLogService instance = AppLogService._(
    filePath: null,
    maxBufferLines: _kMaxBufferLines,
    maxFileBytes: _kMaxFileBytes,
    maxArchivedFiles: _kMaxArchivedFiles,
  );

  static const int _kMaxBufferLines = 2000;

  /// 单个日志文件上限 1MB：live + 3 个归档 = 4MB，符合「磁盘有界 ≤4MB」。
  static const int _kMaxFileBytes = 1024 * 1024;

  /// 归档代数：`.old`（上一代）+ `.old.1` … 最多 3 个。
  static const int _kMaxArchivedFiles = 3;

  /// 内存环形缓存条数（页面实时流的数据源）。
  static const int _kMaxRecentEntries = 1000;

  /// 单条日志上限：main 里整段堆栈一次 debugPrint 即单行（见 fatal 分支），
  /// 不截断的话 2000 行“巨行”内存无界。16KB 足够保留有效帧，超长只丢尾部。
  static const int _kMaxMessageChars = 16 * 1024;
  static const Duration _flushInterval = Duration(milliseconds: 500);

  /// 测试构造：注入文件路径与上限，避免触碰真实用户目录。
  @visibleForTesting
  static AppLogService createForTest({
    required String filePath,
    int maxBufferLines = 64,
    int maxFileBytes = 1024,
    int maxArchivedFiles = 3,
  }) => AppLogService._(
    filePath: filePath,
    maxBufferLines: maxBufferLines,
    maxFileBytes: maxFileBytes,
    maxArchivedFiles: maxArchivedFiles,
  );

  final int _maxBufferLines;
  final int _maxFileBytes;
  final int _maxArchivedFiles;

  /// 待写缓冲（行文本）：上限 [_maxBufferLines] 行，超限丢最旧。
  final List<String> _pending = [];

  /// 内存环形缓存：页面订阅数据源，上限 [_kMaxRecentEntries] 条。
  final List<LogEntry> _recentEntries = [];
  final StreamController<LogEntry> _streamController =
      StreamController<LogEntry>.broadcast();

  Timer? _flushTimer;
  bool _flushing = false;
  String? _logFilePath;
  bool _debugPrintHooked = false;
  bool _hooksInstalled = false;
  static bool _installed = false;

  /// 内部防重入标记：FlutterError 原实现会经 debugPrint 再打一遍，避免重复记录。
  bool _suppressDebugPrintCapture = false;

  /// 当前日志文件路径；未就绪（路径解析中/失败）为 null。
  String? get logFilePath => _logFilePath;

  /// 日志目录路径（页面展示/复制用）；未就绪为 null。
  String? get logDirectoryPath =>
      _logFilePath == null ? null : File(_logFilePath!).parent.path;

  /// 实时日志流（广播，页面/listener 可订阅）。
  Stream<LogEntry> get logStream => _streamController.stream;

  /// 内存环形缓存快照（最近 [_kMaxRecentEntries] 条）。
  List<LogEntry> get recentEntries => List.unmodifiable(_recentEntries);

  /// 解析日志文件路径（含 logs 目录创建）。失败返回 null（禁用落盘）。
  static Future<String?> resolveLogFilePath() async {
    try {
      final Directory base;
      if (!kIsWeb && Platform.isAndroid) {
        // app 专属外部存储：无需存储权限（与下载目录同源）。
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

  /// 初始化单例、接管全局输出与框架错误，并记录会话起始行。
  ///
  /// 路径解析失败（返回 null）只禁用落盘，控制台输出不受影响，绝不阻断启动；
  /// 重复调用安全（[install] 幂等，hook 只装一次）。
  static Future<void> install() async {
    if (_installed) return;
    _installed = true;
    instance._installHooks();
    instance._logFilePath = await resolveLogFilePath();
    instance.record(
      '=== ${AppConfig.appName} 日志会话开始 v${AppConfig.appVersion} ===',
    );
  }

  /// 是否已安装全局 hook（测试/诊断用）。
  @visibleForTesting
  static bool get hooksInstalled => instance._hooksInstalled;

  void _installHooks() {
    if (_hooksInstalled) return;
    _hooksInstalled = true;
    installDebugPrintHook();
    // 框架错误（build/layout 异常等）：记录结构化条目后照常走原实现，
    // 不改变既有控制台/崩溃上报行为。原实现内部会经 debugPrint 再打一遍，
    // 记录期间置 _suppressDebugPrintCapture 避免重复入库。
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final stack = details.stack;
      record(
        '[FlutterError] ${details.exceptionAsString()}'
        '${stack == null ? '' : '\n$stack'}',
        level: LogLevel.error,
        tag: 'FlutterError',
      );
      _suppressDebugPrintCapture = true;
      try {
        originalOnError?.call(details);
      } finally {
        _suppressDebugPrintCapture = false;
      }
    };
  }

  /// 接管全局 `debugPrint`：先落本服务，再走原实现（保留 logcat 输出与
  /// 节流语义）。必须在 flutter binding 就绪后调用（main 已 ensureInitialized）。
  static void installDebugPrintHook() {
    if (instance._debugPrintHooked) return;
    instance._debugPrintHooked = true;
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null &&
          message.isNotEmpty &&
          !instance._suppressDebugPrintCapture) {
        instance.log(message);
      }
      original(message, wrapWidth: wrapWidth);
    };
  }

  /// 追加一条日志（兼容旧入口，级别由关键词推断、tag 由前缀解析）。
  void log(String message) => record(message);

  /// 记录一条日志。
  ///
  /// [level] 为 null 时按关键词推断（error/exception/fatal/失败/异常/错误 →
  /// error；warning/timeout/超时/警告/降级 → warning；其余 info）；
  /// [tag] 为 null 时从 `[频道]`/`[频道][子频道]` 前缀解析。显式传入优先。
  void record(String message, {LogLevel? level, String? tag}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level ?? _inferLevel(message),
      message: _truncate(message),
      tag: tag ?? _extractTag(message),
    );

    _recentEntries.add(entry);
    if (_recentEntries.length > _kMaxRecentEntries) {
      _recentEntries.removeRange(0, _recentEntries.length - _kMaxRecentEntries);
    }
    if (!_streamController.isClosed) {
      _streamController.add(entry);
    }

    _pending.add(entry.toLogLine());
    if (_pending.length > _maxBufferLines) {
      _pending.removeAt(0);
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_logFilePath == null) return;
    if (_flushTimer?.isActive ?? false) return;
    _flushTimer = Timer(_flushInterval, _onFlushTimer);
  }

  void _onFlushTimer() {
    _flushTimer = null;
    unawaited(flush());
  }

  /// 立即把内存缓冲写入磁盘（进程退出前/测试用）。重复调用安全。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_flushing) return;
    await _flushNow();
  }

  Future<void> _flushNow() async {
    if (_pending.isEmpty || _logFilePath == null) return;
    _flushing = true;
    try {
      final file = File(_logFilePath!);
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await _rotateIfNeeded(file);

      // 复制后立刻清空：join 与 clear 之间无 await，不存在新日志插队。
      final linesToWrite = List<String>.of(_pending);
      _pending.clear();

      final buffer = StringBuffer();
      final isFreshFile = !await file.exists() || await file.length() == 0;
      if (isFreshFile) {
        // 新文件先写诊断头（版本/平台/时间），便于用户直接外发。
        buffer.write(_buildDiagnosticsHeader());
      }
      for (final line in linesToWrite) {
        buffer.writeln(line);
      }
      await file.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // 落盘失败静默：日志通道绝不能反噬播放主流程。
    } finally {
      _flushing = false;
      // 写入期间又有新日志且没有已排定的 timer：再排一轮。
      if (_pending.isNotEmpty) {
        _scheduleFlush();
      }
    }
  }

  /// 超过单文件上限时滚动归档：`app.log` → `.old`，旧归档依次后移
  /// （`.old` → `.old.1` → …），最多保留 [_maxArchivedFiles] 个。
  Future<void> _rotateIfNeeded(File file) async {
    if (!await file.exists()) return;
    if (await file.length() <= _maxFileBytes) return;

    final base = file.path;
    if (_maxArchivedFiles <= 1) {
      // 只保留一代：与旧实现一致（覆盖 .old）。
      final old = File('$base.old');
      if (await old.exists()) await old.delete();
      await file.rename(old.path);
      return;
    }

    final oldest = File('$base.old.${_maxArchivedFiles - 1}');
    if (await oldest.exists()) await oldest.delete();
    for (var i = _maxArchivedFiles - 2; i >= 1; i--) {
      final from = File('$base.old.$i');
      if (await from.exists()) await from.rename('$base.old.${i + 1}');
    }
    final firstArchive = File('$base.old');
    if (await firstArchive.exists()) await firstArchive.rename('$base.old.1');
    await file.rename('$base.old');
  }

  /// 运行期诊断头：版本/渲染引擎/ABI/平台/起始时间。
  ///
  /// 注意：**不写**本地绝对路径（桌面含用户名）、不写接口地址（fork 无远端
  /// 后端，写了只会误导读日志的人）。
  String _buildDiagnosticsHeader({bool forExport = false}) {
    final buffer = StringBuffer()
      ..writeln('==================================================')
      ..writeln('${AppConfig.appName}诊断日志')
      ..writeln(
        'App Version : ${AppConfig.appVersion} (${AppConfig.appVersionCode})',
      )
      ..writeln('Renderer    : ${AppConfig.rendererLabel} / ${AppConfig.abi}')
      ..writeln('OS Platform : ${_platformLabel()}');
    if (forExport) {
      buffer.writeln(
        'Exported At : ${LogEntry.formatTimestamp(DateTime.now())}',
      );
    }
    buffer
      ..writeln('Log Started : ${LogEntry.formatTimestamp(DateTime.now())}')
      ..writeln('==================================================');
    return buffer.toString();
  }

  String _platformLabel() {
    if (kIsWeb) return 'web';
    try {
      final os = Platform.operatingSystem;
      final version = Platform.operatingSystemVersion;
      return version.isEmpty ? os : '$os $version';
    } catch (_) {
      return 'unknown';
    }
  }

  /// 全部日志文件（按时间从旧到新）：`.old.N-1` … `.old.1`、`.old`、`app.log`。
  List<String> _allLogFilePaths() {
    final base = _logFilePath;
    if (base == null) return const [];
    final paths = <String>[];
    for (var i = _maxArchivedFiles - 1; i >= 1; i--) {
      paths.add('$base.old.$i');
    }
    paths.add('$base.old');
    paths.add(base);
    return paths;
  }

  /// 本地日志统计（文件数/总占用/内存条数/文件修改时间范围）。
  Future<LogStats> getLogStats() async {
    await flush();
    var fileCount = 0;
    var totalBytes = 0;
    DateTime? earliest;
    DateTime? latest;
    for (final path in _allLogFilePaths()) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final stat = await file.stat();
        fileCount++;
        totalBytes += stat.size;
        final modified = stat.modified;
        if (earliest == null || modified.isBefore(earliest)) {
          earliest = modified;
        }
        if (latest == null || modified.isAfter(latest)) {
          latest = modified;
        }
      } catch (_) {}
    }
    return LogStats(
      fileCount: fileCount,
      totalBytes: totalBytes,
      entryCount: _recentEntries.length,
      earliestDate: earliest,
      latestDate: latest,
    );
  }

  /// 生成可外发的完整日志文本。
  ///
  /// [maxLines] 为 null 时导出全部历史文件（含归档），**不设行数截断**；
  /// 指定 [maxLines] 时只保留最近 N 行并在头部注明。导出前统一做脱敏。
  Future<String> exportLogsText({int? maxLines}) async {
    await flush();
    final buffer = StringBuffer()
      ..write(_buildDiagnosticsHeader(forExport: true));

    final lines = <String>[];
    for (final path in _allLogFilePaths()) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        lines.addAll(await file.readAsLines());
      } catch (_) {}
    }
    if (lines.isEmpty) {
      // 文件不可读时回退内存缓存（如落盘未启用）。
      for (final entry in _recentEntries) {
        lines.add(entry.toLogLine());
      }
    }

    buffer.writeln();
    if (maxLines != null && lines.length > maxLines) {
      buffer.writeln('... [较早日志已按行数上限截断，仅保留最近 $maxLines 行] ...');
      for (final line in lines.sublist(lines.length - maxLines)) {
        buffer.writeln(line);
      }
    } else {
      for (final line in lines) {
        buffer.writeln(line);
      }
    }
    return redactSensitive(buffer.toString());
  }

  /// 导出目录解析。
  ///
  /// 优先级：调用方指定目录 → Android app 专属外部目录 `shiyin_logs` →
  /// 桌面（Windows/Linux）系统下载目录 `shiyin_logs` → 应用文档目录 `logs`。
  /// Android 公共 Download 在 API29+ 分区存储下裸写必 EACCES（与下载目录
  /// 同口径，见 download_service.dart 注释），故这里从不写公共目录，也不
  /// 申请任何存储权限。
  static Future<Directory?> resolveExportDirectory({
    String? customDestinationDir,
  }) async {
    try {
      final custom = customDestinationDir?.trim();
      if (custom != null && custom.isNotEmpty) {
        return _ensureDir(Directory(custom));
      }
      if (!kIsWeb && Platform.isAndroid) {
        final external = await getExternalStorageDirectory();
        if (external != null) {
          return _ensureDir(
            Directory('${external.path}${Platform.pathSeparator}shiyin_logs'),
          );
        }
      } else if (!kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) {
          return _ensureDir(
            Directory('${downloads.path}${Platform.pathSeparator}shiyin_logs'),
          );
        }
      }
      final base = await getApplicationDocumentsDirectory();
      return _ensureDir(Directory('${base.path}${Platform.pathSeparator}logs'));
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> _ensureDir(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 导出日志到用户可见的文本文件，返回完整路径；失败返回 null。
  ///
  /// [fullLogs] 为 true 时导出全量（含归档、无行数截断）；为 false 时保留
  /// 最近 2000 行。[customContent] 非空时直接导出该文本（例如页面当前筛选
  /// 结果），[exportLogsToFile] 同样对其做脱敏。
  Future<String?> exportLogsToFile({
    bool fullLogs = true,
    String? customContent,
    String? customDestinationDir,
  }) async {
    try {
      final text = customContent != null
          ? redactSensitive(customContent)
          : await exportLogsText(maxLines: fullLogs ? null : 2000);
      final dir = await resolveExportDirectory(
        customDestinationDir: customDestinationDir,
      );
      if (dir == null) return null;

      final prefix = customContent != null
          ? 'shiyin_filtered_log'
          : (fullLogs ? 'shiyin_full_log' : 'shiyin_recent_log');
      final name = '${prefix}_${_fileTimestamp(DateTime.now())}.txt';
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsString(text, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 复制日志到系统剪贴板：默认最近 2000 行；[customContent] 非空时复制该
  /// 文本（例如页面筛选结果）。复制前统一脱敏。
  Future<bool> copyLogsToClipboard({
    int? maxLines = 2000,
    String? customContent,
  }) async {
    try {
      final text = customContent != null
          ? redactSensitive(customContent)
          : await exportLogsText(maxLines: maxLines);
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清空本地全部日志文件与内存缓存，随后开启一个新会话。
  Future<void> clearLogs() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    _recentEntries.clear();

    for (final path in _allLogFilePaths()) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    record('=== 本地日志已清空，新会话开始 ===');
  }

  static String _fileTimestamp(DateTime now) {
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${pad(now.month)}${pad(now.day)}'
        '_${pad(now.hour)}${pad(now.minute)}${pad(now.second)}';
  }

  String _truncate(String message) {
    if (message.length <= _kMaxMessageChars) return message;
    return '${message.substring(0, _kMaxMessageChars)}'
        '…（单条截断，共${message.length}字）';
  }

  static const List<String> _errorKeywords = [
    'error',
    'exception',
    'failed',
    'fatal',
    '失败',
    '异常',
    '错误',
    '崩溃',
  ];

  static const List<String> _warningKeywords = [
    'warning',
    'timeout',
    '超时',
    '警告',
    '降级',
  ];

  static LogLevel _inferLevel(String message) {
    final lower = message.toLowerCase();
    for (final keyword in _errorKeywords) {
      if (lower.contains(keyword)) return LogLevel.error;
    }
    for (final keyword in _warningKeywords) {
      if (lower.contains(keyword)) return LogLevel.warning;
    }
    return LogLevel.info;
  }

  static final RegExp _tagPrefixPattern = RegExp(
    r'^\[([^\[\]]{1,24})\](?:\[([^\[\]]{1,24})\])?',
  );

  /// 从 `[频道][子频道]` 前缀解析 tag：优先取更具体的第二段。
  static String? _extractTag(String message) {
    final match = _tagPrefixPattern.firstMatch(message);
    if (match == null) return null;
    final second = match.group(2);
    if (second != null && second.isNotEmpty) return second;
    return match.group(1);
  }

  static final RegExp _newLinePattern = RegExp(
    r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}) '
    r'\[(DEBUG|INFO|WARNING|ERROR)\] (.*)$',
  );

  static final RegExp _legacyLinePattern = RegExp(
    r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}) (.*)$',
  );

  static LogLevel _levelFromLabel(String label) {
    return switch (label) {
      'DEBUG' => LogLevel.debug,
      'WARNING' => LogLevel.warning,
      'ERROR' => LogLevel.error,
      _ => LogLevel.info,
    };
  }

  /// 解析一行落盘日志；无法识别（诊断头/空行）返回 null。
  ///
  /// 旧版落盘格式为 `<ISO 时间戳> <消息>`（无级别），按 info 回退，保证
  /// 升级前存在 `app.log` / `.old` 里的历史行仍可读。
  @visibleForTesting
  static LogEntry? parseLogLine(String line) {
    final modern = _newLinePattern.firstMatch(line);
    if (modern != null) {
      return LogEntry(
        timestamp: DateTime.parse(modern.group(1)!),
        level: _levelFromLabel(modern.group(2)!),
        message: modern.group(3)!,
      );
    }
    final legacy = _legacyLinePattern.firstMatch(line);
    if (legacy != null) {
      return LogEntry(
        timestamp: DateTime.parse(legacy.group(1)!),
        level: LogLevel.info,
        message: legacy.group(2)!,
      );
    }
    return null;
  }

  /// 敏感值脱敏：导出/复制前调用，避免 token/t1/session/cookie 等外泄。
  ///
  /// 覆盖 `key=value`、`key: value`、JSON `"key": "value"` 与
  /// `Authorization: Bearer xxx`；只替换值，保留键名便于排障。
  static final RegExp _sensitivePattern = RegExp(
    r'''(\b(?:token|t1|session(?:id)?|authorization|userid|user_id|cookie|password|passwd|signature)\b["']?\s*[=:]\s*["']?)((?:(?:bearer|basic)\s+)?[^&\s,;"']+)''',
    caseSensitive: false,
  );

  static String redactSensitive(String text) =>
      text.replaceAllMapped(_sensitivePattern, (match) => '${match[1]}***');
}
