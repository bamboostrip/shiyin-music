import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_config.dart';
import '../../services/app_update_service.dart';
import '../../services/music_api.dart';
import '../widgets/toast.dart';
import '../adaptive_layout.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.api});

  static final Uri _repositoryUri = Uri.parse(
    'https://github.com/bamboostrip/shiyin-music',
  );

  final MusicApi api;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  List<ChangelogVersion> _versions = const [];
  bool _changelogLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadChangelog();
  }

  Future<void> _loadChangelog() async {
    try {
      final content = await rootBundle.loadString('update.md');
      if (mounted) {
        setState(() {
          _versions = ChangelogVersion.parse(content);
          _changelogLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _changelogLoaded = true);
      }
    }
  }

  Future<void> _openRepository(BuildContext context) async {
    final opened = await launchUrl(
      AboutPage._repositoryUri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      Toast.error('无法打开 GitHub 仓库链接');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: AdaptiveContentPadding(
        child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text('关于'),
            surfaceTintColor: Colors.transparent,
            backgroundColor: colorScheme.surface,
          ),
          SliverToBoxAdapter(
            child: Column(
              children: [
                const SizedBox(height: 12),
                _AppLogo(),
                const SizedBox(height: 16),
                Text(
                  AppConfig.appName,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '版本 ${AppConfig.appVersion}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '时光不朽，音乐永恒',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '一个专注播放体验的音乐应用。适配手机、车机、平板等多端。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppUpdateService.isSupportedPlatform
                            ? FilledButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.system_update_alt_rounded),
                                label: const Text('检查更新'),
                              )
                            : OutlinedButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.system_update_alt_rounded),
                                label: const Text('暂不支持检查更新'),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
              child: _InfoSection(
                children: [
                  const _InfoRow(label: '应用名称', value: AppConfig.appName),
                  const _InfoRow(label: '当前版本', value: AppConfig.appVersion),
                  _InfoLinkRow(
                    label: 'GitHub',
                    value: 'bamboostrip/shiyin-music',
                    onTap: () => _openRepository(context),
                  ),
                ],
              ),
            ),
          ),
          if (_changelogLoaded && _versions.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.history_rounded,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '更新日志',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              sliver: SliverList.separated(
                itemCount: _versions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final version = _versions[index];
                  return _VersionCard(
                    version: version,
                    initiallyExpanded: index == 0,
                  );
                },
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ] else if (_changelogLoaded) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ],
      ),
    ),
  );
  }
}

/// 应用 Logo，使用 lib/assets/logo.png。
class _AppLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: .22),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.asset(
          'lib/assets/logo.png',
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              color: colorScheme.primaryContainer,
              child: Icon(
                Icons.music_note_rounded,
                size: 56,
                color: colorScheme.primary,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _InfoLinkRow extends StatelessWidget {
  const _InfoLinkRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.open_in_new_rounded,
              size: 18,
              color: colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(children: children),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个版本的更新日志卡片，可展开/收起。
class _VersionCard extends StatefulWidget {
  const _VersionCard({
    required this.version,
    this.initiallyExpanded = false,
  });

  final ChangelogVersion version;
  final bool initiallyExpanded;

  @override
  State<_VersionCard> createState() => _VersionCardState();
}

class _VersionCardState extends State<_VersionCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final version = widget.version;
    final isCurrent = version.version == 'v${AppConfig.appVersion}';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: isCurrent
            ? Border.all(color: colorScheme.primary.withValues(alpha: .4))
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? colorScheme.primary
                              : colorScheme.primary.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          version.version,
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: isCurrent
                                ? colorScheme.onPrimary
                                : colorScheme.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (version.date != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          version.date!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const Spacer(),
                      AnimatedRotation(
                        turns: _expanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          Icons.chevron_right_rounded,
                          color: colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 180),
                  crossFadeState: _expanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  firstChild: const SizedBox(width: double.infinity),
                  secondChild: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Divider(
                          height: 1,
                          color: colorScheme.outlineVariant
                              .withValues(alpha: .4),
                        ),
                        const SizedBox(height: 10),
                        if (version.lines.isEmpty)
                          Text(
                            '暂无更新说明',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          )
                        else
                          ...version.lines.map(
                            (line) => _ChangelogLine(text: line),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChangelogLine extends StatelessWidget {
  const _ChangelogLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: .55),
                shape: BoxShape.circle,
              ),
              child: const SizedBox(width: 5, height: 5),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _buildRichText(context, text),
          ),
        ],
      ),
    );
  }

  Widget _buildRichText(BuildContext context, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    final spans = <TextSpan>[];
    final boldPattern = RegExp(r'\*\*(.*?)\*\*');
    var lastEnd = 0;

    for (final match in boldPattern.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: TextStyle(color: colorScheme.onSurface),
        ));
      }
      spans.add(TextSpan(
        text: match.group(1),
        style: const TextStyle(fontWeight: FontWeight.w800),
      ));
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(color: colorScheme.onSurface),
      ));
    }

    if (spans.isEmpty) {
      return Text(
        text,
        style: TextStyle(color: colorScheme.onSurface),
      );
    }

    return RichText(
      text: TextSpan(
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4),
        children: spans,
      ),
    );
  }
}

/// 单个版本的更新日志数据。
class ChangelogVersion {
  const ChangelogVersion({
    required this.version,
    this.date,
    this.lines = const [],
  });

  /// 版本号，如 `v1.7.0`。
  final String version;

  /// 版本发布日期（若 markdown 中包含）。
  final String? date;

  /// 该版本的更新条目（已去掉 `- ` 前缀）。
  final List<String> lines;

  /// 解析 markdown 更新日志，按 `## vX.X.X` 分块。
  static List<ChangelogVersion> parse(String content) {
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    final versions = <ChangelogVersion>[];
    var currentVersion = <String, dynamic>{};
    var currentLines = <String>[];

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.startsWith('## ') && line.contains(RegExp(r'v\d+\.\d+'))) {
        if (currentVersion.isNotEmpty) {
          versions.add(ChangelogVersion(
            version: currentVersion['version'] as String,
            date: currentVersion['date'] as String?,
            lines: List<String>.from(currentLines),
          ));
        }
        final header = line.substring(3).trim();
        final match = RegExp(r'(v\d+\.\d+(?:\.\d+)?)(.*)').firstMatch(header);
        currentVersion = {
          'version': match?.group(1) ?? header,
          'date': (match?.group(2) ?? '').trim().replaceAll(
                RegExp(r'^[\s\-—:：]+'),
                '',
              ),
        };
        currentLines = [];
        continue;
      }

      if (currentVersion.isEmpty) continue;
      if (line.isEmpty) continue;
      if (line.startsWith('# ')) continue;

      if (line.startsWith('- ') || line.startsWith('* ')) {
        currentLines.add(line.substring(2).trim());
      } else if (RegExp(r'^\d+\.\s+').hasMatch(line)) {
        currentLines.add(line.replaceFirst(RegExp(r'^\d+\.\s+'), '').trim());
      }
    }

    if (currentVersion.isNotEmpty) {
      versions.add(ChangelogVersion(
        version: currentVersion['version'] as String,
        date: currentVersion['date'] as String?,
        lines: List<String>.from(currentLines),
      ));
    }

    return versions;
  }
}
