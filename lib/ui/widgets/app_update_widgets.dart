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
    Toast.error('检测更新失败：$error');
  }
}

Future<void> showAppUpdateDialog({
  required BuildContext context,
  required AppUpdateService service,
  required AppVersionInfo version,
  required bool force,
}) {
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
