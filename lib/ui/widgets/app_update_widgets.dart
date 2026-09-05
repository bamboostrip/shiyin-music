import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/app_version.dart';
import '../../services/app_update_service.dart';
import 'toast.dart';

class AppUpdateBanner extends StatelessWidget {
  const AppUpdateBanner({
    super.key,
    required this.version,
    required this.onTap,
    required this.onClose,
  });

  final AppVersionInfo version;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.primary.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.primary.withValues(alpha: .2)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
          child: Row(
            children: [
              Icon(
                Icons.system_update_alt_rounded,
                color: colorScheme.primary,
                size: 20,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '检测到新版本：${version.versionName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
                icon: Icon(
                  Icons.close_rounded,
                  color: colorScheme.primary,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> checkAppUpdateManually({
  required BuildContext context,
}) async {
  if (!AppUpdateService.isSupportedPlatform) {
    return;
  }

  Toast.info('正在检测更新...');

  try {
    final service = AppUpdateService();
    final version = await service.checkForUpdate(manual: true);
    if (!context.mounted) {
      return;
    }

    if (version == null) {
      Toast.success('当前已是最新版本');
      return;
    }

    await showAppUpdateDialog(
      context: context,
      service: service,
      version: version,
      force: version.forceUpdate,
    );
  } catch (error) {
    if (!context.mounted) {
      return;
    }
    Toast.error('检测更新失败：${error is StateError ? error.message : error}');
  }
}

Future<void> showAppUpdateDialog({
  required BuildContext context,
  required AppUpdateService service,
  required AppVersionInfo version,
  required bool force,
}) {
  // Windows 走分形态流程弹窗（便携版跳浏览器 / 安装版应用内下载安装）。
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    return showDialog<void>(
      context: context,
      barrierDismissible: !force,
      builder: (dialogContext) => _WindowsUpdateDialog(
        service: service,
        version: version,
        force: force,
      ),
    );
  }

  return showDialog<void>(
    context: context,
    barrierDismissible: !force,
    builder: (dialogContext) {
      Future<void> startUpdate() async {
        try {
          await service.downloadAndInstall(version);
          if (!dialogContext.mounted) {
            return;
          }
          Toast.info('正在跳转至浏览器下载更新包');
          if (!force) {
            Navigator.of(dialogContext).pop();
          }
        } catch (error) {
          if (!dialogContext.mounted) {
            return;
          }
          Toast.error('开始更新失败：$error');
        }
      }

      return PopScope(
        canPop: !force,
        child: AlertDialog(
          icon: const Icon(Icons.system_update_alt_rounded),
          title: Text(force ? '发现重要更新' : '发现新版本 ${version.versionName}'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 360),
            child: SingleChildScrollView(
              child: _MarkdownContent(
                data: version.updateContent.trim().isEmpty
                    ? '暂无更新说明'
                    : version.updateContent,
              ),
            ),
          ),
          actions: [
            if (!force)
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('以后再说'),
              ),
            FilledButton.icon(
              onPressed: startUpdate,
              icon: const Icon(Icons.download_rounded),
              label: const Text('立即更新'),
            ),
          ],
        ),
      );
    },
  );
}

/// Windows 更新流程弹窗：按分发形态分轨。
///
/// - 便携版：主按钮「去下载」跳浏览器打开 zip 直链（用户自行解压覆盖）；
/// - 安装版：主按钮「下载更新」进入应用内下载 setup.exe（进度 + 取消），
///   完成后「退出并安装」拉起向导退出本应用；同时始终保留「浏览器下载」
///   次级入口（网络不佳或应用内下载失败时改走浏览器）。
class _WindowsUpdateDialog extends StatefulWidget {
  const _WindowsUpdateDialog({
    required this.service,
    required this.version,
    required this.force,
  });

  final AppUpdateService service;
  final AppVersionInfo version;
  final bool force;

  @override
  State<_WindowsUpdateDialog> createState() => _WindowsUpdateDialogState();
}

enum _UpdatePhase { idle, downloading, ready }

class _WindowsUpdateDialogState extends State<_WindowsUpdateDialog> {
  _UpdatePhase _phase = _UpdatePhase.idle;
  CancelToken? _cancelToken;
  int _received = 0;
  int _total = 0;
  String? _setupPath;

  bool get _installed => AppUpdateService.isWindowsInstalledBuild;

  /// 下载地址是否为附件直链（非直链时按钮退化为打开发布页）。
  bool get _hasDirectAsset {
    final url = widget.version.downloadUrl.toLowerCase();
    return url.endsWith('.zip') || url.endsWith('.exe');
  }

  Future<void> _openInBrowser() async {
    try {
      await widget.service.downloadAndInstall(widget.version);
      if (!mounted) {
        return;
      }
      Toast.info(
        _hasDirectAsset && !_installed
            ? '已在浏览器开始下载，解压覆盖旧目录即可完成更新'
            : '已打开下载页面，请在浏览器中完成下载',
      );
      if (!widget.force) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      Toast.error('打开下载链接失败：${_cleanError(error)}');
    }
  }

  Future<void> _startDownload() async {
    setState(() {
      _phase = _UpdatePhase.downloading;
      _received = 0;
      _total = 0;
    });
    _cancelToken = CancelToken();
    try {
      final path = await widget.service.downloadWindowsSetup(
        widget.version,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          if (!mounted) {
            return;
          }
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _UpdatePhase.ready;
        _setupPath = path;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _phase = _UpdatePhase.idle);
      Toast.error('下载失败：${_cleanError(error)}');
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel('用户取消下载');
  }

  Future<void> _quitAndInstall() async {
    final path = _setupPath;
    if (path == null) {
      return;
    }
    try {
      // 成功路径不再返回：拉起向导后 exit(0) 退出本应用。
      await widget.service.launchWindowsInstallerAndExit(path);
    } catch (error) {
      if (!mounted) {
        return;
      }
      Toast.error('启动安装程序失败：${_cleanError(error)}');
    }
  }

  /// 提取可读错误文案（StateError 去 "Bad state:" 前缀，DioException 映射常见网络错误）。
  String _cleanError(Object error) {
    if (error is StateError) {
      return error.message;
    }
    if (error is DioException) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => '网络超时，请稍后重试',
        DioExceptionType.connectionError => '网络连接失败',
        DioExceptionType.badResponse =>
          '服务器响应异常（${error.response?.statusCode ?? ''}）',
        DioExceptionType.cancel => '已取消',
        _ => '网络错误（${error.type.name}）',
      };
    }
    return '$error';
  }

  String get _fileName =>
      'ShiyinMusic-Setup-v${widget.version.versionName}.exe';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !widget.force,
      child: AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded),
        title: Text(
          widget.force ? '发现重要更新' : '发现新版本 ${widget.version.versionName}',
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 380),
          child: switch (_phase) {
            _UpdatePhase.downloading => _buildDownloading(colorScheme),
            _UpdatePhase.ready => _buildReady(colorScheme),
            _UpdatePhase.idle => SingleChildScrollView(
              child: _MarkdownContent(
                data: widget.version.updateContent.trim().isEmpty
                    ? '暂无更新说明'
                    : widget.version.updateContent,
              ),
            ),
          },
        ),
        actions: switch (_phase) {
          _UpdatePhase.downloading => [
            TextButton.icon(
              onPressed: _cancelDownload,
              icon: const Icon(Icons.close_rounded),
              label: const Text('取消'),
            ),
          ],
          _UpdatePhase.ready => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('稍后再装'),
            ),
            FilledButton.icon(
              onPressed: _quitAndInstall,
              icon: const Icon(Icons.install_desktop_rounded),
              label: const Text('退出并安装'),
            ),
          ],
          _UpdatePhase.idle => _buildIdleActions(),
        },
      ),
    );
  }

  List<Widget> _buildIdleActions() {
    final directAsset = _hasDirectAsset;
    // 安装版保留浏览器下载次级入口；便携版主路径就是浏览器，
    // 无直链时主按钮已退化为"打开发布页"，均不再重复放。
    final showBrowserEntry = _installed && directAsset;
    return [
      if (!widget.force)
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('以后再说'),
        ),
      if (showBrowserEntry)
        TextButton.icon(
          onPressed: _openInBrowser,
          icon: const Icon(Icons.open_in_browser_rounded),
          label: const Text('浏览器下载'),
        ),
      FilledButton.icon(
        onPressed: () {
          if (!directAsset) {
            // 无附件直链：按钮退化为打开发布页（同浏览器路径）。
            _openInBrowser();
            return;
          }
          if (_installed) {
            _startDownload();
          } else {
            _openInBrowser();
          }
        },
        icon: Icon(
          directAsset && _installed
              ? Icons.download_rounded
              : Icons.open_in_new_rounded,
        ),
        label: Text(
          !directAsset
              ? '打开发布页'
              : _installed
              ? '下载更新'
              : '去下载（浏览器）',
        ),
      ),
    ];
  }

  Widget _buildDownloading(ColorScheme colorScheme) {
    final hasTotal = _total > 0;
    final percent = hasTotal ? _received / _total : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '正在下载 $_fileName',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          '下载到系统"下载"文件夹，完成后可退出并安装',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        LinearProgressIndicator(value: percent, minHeight: 8),
        const SizedBox(height: 10),
        Text(
          hasTotal
              ? '${(percent! * 100).toStringAsFixed(0)}% · ${_mb(_received)} / ${_mb(_total)} MB'
              : '正在连接…',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildReady(ColorScheme colorScheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.check_circle_rounded,
              color: colorScheme.primary,
              size: 28,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '安装包已就绪',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '$_fileName 已保存到"下载"文件夹。点击"退出并安装"将关闭本应用并打开安装向导，按提示完成安装即可。',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}

class _MarkdownContent extends StatelessWidget {
  const _MarkdownContent({required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    final lines = data.replaceAll('\r\n', '\n').split('\n');
    final children = <Widget>[];
    var inCodeBlock = false;
    final codeLines = <String>[];

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.trimLeft().startsWith('```')) {
        if (inCodeBlock) {
          children.add(_CodeBlock(text: codeLines.join('\n')));
          codeLines.clear();
        }
        inCodeBlock = !inCodeBlock;
        continue;
      }

      if (inCodeBlock) {
        codeLines.add(line);
        continue;
      }

      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        children.add(const SizedBox(height: 8));
      } else if (trimmed.startsWith('#')) {
        children.add(_Heading(line: trimmed));
      } else if (RegExp(r'^[-*+]\s+').hasMatch(trimmed)) {
        children.add(_BulletLine(text: trimmed.substring(2).trim()));
      } else if (RegExp(r'^\d+\.\s+').hasMatch(trimmed)) {
        final text = trimmed.replaceFirst(RegExp(r'^\d+\.\s+'), '');
        children.add(_BulletLine(text: text, ordered: true));
      } else {
        children.add(_Paragraph(text: trimmed));
      }
    }

    if (codeLines.isNotEmpty) {
      children.add(_CodeBlock(text: codeLines.join('\n')));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) {
    final level = RegExp(r'^#+').firstMatch(line)?.group(0)?.length ?? 1;
    final text = line.replaceFirst(RegExp(r'^#+\s*'), '');
    final fontSize = switch (level) {
      1 => 18.0,
      2 => 16.0,
      _ => 14.5,
    };

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 5),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: RichText(
        text: _inlineSpan(
          context,
          text,
          Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _BulletLine extends StatelessWidget {
  const _BulletLine({required this.text, this.ordered = false});

  final String text;
  final bool ordered;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Text(
              ordered ? '1.' : '•',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Expanded(
            child: RichText(
              text: _inlineSpan(
                context,
                text,
                Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

TextSpan _inlineSpan(BuildContext context, String text, TextStyle? baseStyle) {
  final colorScheme = Theme.of(context).colorScheme;
  final spans = <TextSpan>[];
  final pattern = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`)');
  var cursor = 0;

  for (final match in pattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }

    final token = match.group(0) ?? '';
    if (token.startsWith('**')) {
      spans.add(
        TextSpan(
          text: token.substring(2, token.length - 2),
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: token.substring(1, token.length - 1),
          style: TextStyle(
            color: colorScheme.primary,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    cursor = match.end;
  }

  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }

  return TextSpan(
    style: baseStyle?.copyWith(color: colorScheme.onSurface, height: 1.45),
    children: spans,
  );
}
