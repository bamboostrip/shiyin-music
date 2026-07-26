import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../services/desktop_lyrics_service.dart';

class DesktopLyricsSettingsPage extends StatefulWidget {
  const DesktopLyricsSettingsPage({super.key, required this.player});

  final PlayerController player;

  @override
  State<DesktopLyricsSettingsPage> createState() =>
      _DesktopLyricsSettingsPageState();
}

class _DesktopLyricsSettingsPageState
    extends State<DesktopLyricsSettingsPage> {
  late DesktopLyricsSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.player.desktopLyricsSettings;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.player.setDesktopLyricsPreviewVisible(true);
      }
    });
  }

  @override
  void dispose() {
    widget.player.setDesktopLyricsPreviewVisible(false);
    super.dispose();
  }

  void _update(DesktopLyricsSettings Function(DesktopLyricsSettings s) fn) {
    setState(() => _settings = fn(_settings));
    widget.player.updateDesktopLyricsSettings(_settings);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('桌面歌词设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // Background opacity
          _SectionHeader(title: '外观'),
          const SizedBox(height: 8),
          _SettingsCard(
            children: [
              _SliderTile(
                icon: Icons.opacity_rounded,
                iconColor: colorScheme.primary,
                title: '背景透明度',
                value: _settings.opacity,
                min: 0.0,
                max: 1.0,
                label: '${(_settings.opacity * 100).round()}%',
                onChanged: (v) => _update((s) => s.copyWith(opacity: v)),
              ),
              _SettingsDivider(),
              _SliderTile(
                icon: Icons.format_size_rounded,
                iconColor: colorScheme.primary,
                title: '字体大小',
                value: _settings.fontSize,
                min: 12,
                max: 48,
                label: '${_settings.fontSize.round()}sp',
                onChanged: (v) => _update((s) => s.copyWith(fontSize: v)),
              ),
              _SettingsDivider(),
              _ColorPickerTile(
                title: '歌词颜色',
                currentColor: Color(_settings.textColor),
                presets: const [
                  Colors.white,
                  Color(0xFFFFD700), // Gold
                  Color(0xFFFF69B4), // Pink
                  Color(0xFF00BFFF), // Sky blue
                  Color(0xFF00FF7F), // Spring green
                  Color(0xFFFF6347), // Tomato
                  Color(0xFF000000), // Black
                ],
                onChanged: (c) => _update((s) => s.copyWith(textColor: c.toARGB32())),
              ),
              _SettingsDivider(),
              _ColorPickerTile(
                title: '背景颜色',
                currentColor: Color(_settings.backgroundColor),
                presets: const [
                  Color(0xFF1A1A2E), // Default Dark Blue
                  Color(0xFF000000), // Black
                  Color(0xFF222222), // Dark Grey
                  Color(0xFF3B1E1E), // Dark Red/Brown
                  Color(0xFF1B3B1E), // Dark Green
                  Color(0xFF2A1E3B), // Dark Purple
                  Color(0xFF1E353B), // Dark Teal
                ],
                onChanged: (c) => _update((s) => s.copyWith(backgroundColor: c.toARGB32())),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Behavior
          _SectionHeader(title: '行为'),
          const SizedBox(height: 8),
          _SettingsCard(
            children: [
              _SwitchTile(
                icon: Icons.lock_rounded,
                iconColor: colorScheme.primary,
                title: '锁定位置',
                subtitle: '锁定后无法拖动移动歌词悬浮窗',
                value: _settings.locked,
                onChanged: (v) => _update((s) => s.copyWith(
                  locked: v,
                  passthrough: v ? true : s.passthrough, // Lock auto-enables passthrough
                )),
              ),
              _SettingsDivider(),
              _SwitchTile(
                icon: Icons.touch_app_rounded,
                iconColor: colorScheme.primary,
                title: '触摸穿透',
                subtitle: _settings.locked
                    ? '锁定位置时自动开启'
                    : '启用后点击事件会穿透到下层应用',
                value: _settings.locked ? true : _settings.passthrough,
                onChanged: _settings.locked
                    ? null // Disabled when locked (auto-enabled)
                    : (v) => _update((s) => s.copyWith(passthrough: v)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// --- Shared widgets ---

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(children: children),
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 54,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .4),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final double value;
  final double min;
  final double max;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: iconColor),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Icon(icon, size: 22, color: iconColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ColorPickerTile extends StatelessWidget {
  const _ColorPickerTile({
    required this.title,
    required this.currentColor,
    required this.presets,
    required this.onChanged,
  });

  final String title;
  final Color currentColor;
  final List<Color> presets;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.palette_rounded, size: 22),
              const SizedBox(width: 14),
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final color in presets)
                GestureDetector(
                  onTap: () => onChanged(color),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: currentColor.toARGB32() == color.toARGB32()
                            ? Theme.of(context).colorScheme.primary
                            : (color.toARGB32() == Colors.black.toARGB32()
                                ? Colors.white30
                                : Colors.transparent),
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.toARGB32() == Colors.black.toARGB32()
                              ? Colors.white12
                              : color.withValues(alpha: .4),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: currentColor.toARGB32() == color.toARGB32()
                        ? Icon(Icons.check_rounded,
                            color: color.toARGB32() == Colors.black.toARGB32()
                                ? Colors.white70
                                : Colors.black54,
                            size: 20)
                        : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
