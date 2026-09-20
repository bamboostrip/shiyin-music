import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../services/desktop_lyrics_service.dart';
import '../desktop/lyrics_karaoke_line.dart';
import '../form_factor.dart';
import '../widgets/toast.dart';
import 'desktop_lyrics_color_picker.dart';

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
    // 托盘「解锁桌面歌词」/子窗工具栏锁定按钮修改锁定状态后，设置页需跟随
    // 刷新（PlayerController 是 ChangeNotifier，updateDesktopLyricsSettings
    // 会 notifyListeners）。
    widget.player.addListener(_syncFromPlayer);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.player.setDesktopLyricsPreviewVisible(true);
      }
    });
  }

  @override
  void dispose() {
    widget.player.removeListener(_syncFromPlayer);
    widget.player.setDesktopLyricsPreviewVisible(false);
    super.dispose();
  }

  void _syncFromPlayer() {
    final next = widget.player.desktopLyricsSettings;
    if (next == _settings) return;
    setState(() => _settings = next);
  }

  void _update(DesktopLyricsSettings Function(DesktopLyricsSettings s) fn) {
    setState(() => _settings = fn(_settings));
    widget.player.updateDesktopLyricsSettings(_settings);
  }

  /// 设置页展示用的对齐值。「左右分离」只对双行显示有意义；存量/默认值
  /// split 在单行下与居中渲染完全一致，显示为居中，避免分段按钮空选中。
  String get _displayAlignment =>
      (_settings.singleLine &&
          _settings.alignment == DesktopLyricsAlignment.split)
      ? DesktopLyricsAlignment.center
      : _settings.alignment;

  void _resetToDefaults() {
    // 只恢复外观（配色/字号/行数/对齐/透明度）；锁定与触摸穿透保持不变。
    // 桌面默认双行两端对齐 + 透明悬浮，移动端（Android 原生悬浮窗）默认双行 + 50% 背景。
    _update(
      (s) => s.withPlatformDefaultAppearance(isDesktop: isDesktopFormFactor),
    );
    // PC 播放栏常驻窗口底部，SnackBar 会压在播放栏上；改用悬浮 Toast。
    Toast.show('已恢复默认外观（锁定状态不变）', type: ToastType.success);
  }

  /// 打开取色弹窗；确定后回写颜色，取消不动设置。
  Future<void> _pickColor({
    required String title,
    required Color initial,
    required List<Color> presets,
    required ValueChanged<Color> onChanged,
  }) async {
    final color = await showLyricsColorPicker(
      context,
      title: title,
      initial: initial,
      presets: presets,
    );
    if (color != null) onChanged(color);
  }

  Widget _buildAppearanceSection(BuildContext context, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '外观'),
        const SizedBox(height: 8),
        _SettingsCard(
          children: [
            _SegmentTile<bool>(
              icon: Icons.table_rows_rounded,
              iconColor: colorScheme.primary,
              title: '显示行数',
              selected: _settings.singleLine,
              segments: const [
                ButtonSegment(value: true, label: Text('单行显示')),
                ButtonSegment(value: false, label: Text('双行显示')),
              ],
              onChanged: (v) => _update((s) {
                // 「左右分离」没有单行语义；切回单行时回落为渲染等价的居中。
                final alignment =
                    (v && s.alignment == DesktopLyricsAlignment.split)
                    ? DesktopLyricsAlignment.center
                    : s.alignment;
                return s.copyWith(singleLine: v, alignment: alignment);
              }),
            ),
            _SettingsDivider(),
            // 对齐方式是 PC 桌面悬浮窗专属：移动端原生悬浮窗恒为左对齐
            // （KaraokeTextView 定宽左排 + 跑马灯），实现对齐需要重写绘制
            // 与滚动逻辑，风险高，移动端直接隐藏该行。
            if (isDesktopFormFactor) ...[
              _SegmentTile<String>(
                icon: Icons.format_align_center_rounded,
                iconColor: colorScheme.primary,
                title: '对齐方式',
                selected: _displayAlignment,
                segments: [
                  const ButtonSegment(
                    value: DesktopLyricsAlignment.center,
                    label: Text('居中'),
                  ),
                  const ButtonSegment(
                    value: DesktopLyricsAlignment.left,
                    label: Text('左对齐'),
                  ),
                  const ButtonSegment(
                    value: DesktopLyricsAlignment.right,
                    label: Text('右对齐'),
                  ),
                  // 仅双行显示时可选：上行居左、下行居右。
                  if (!_settings.singleLine)
                    const ButtonSegment(
                      value: DesktopLyricsAlignment.split,
                      label: Text('左右分离'),
                    ),
                ],
                onChanged: (v) => _update((s) => s.copyWith(alignment: v)),
              ),
              _SettingsDivider(),
            ],
            _SliderTile(
              key: const Key('slider_font_size'),
              icon: Icons.format_size_rounded,
              iconColor: colorScheme.primary,
              title: '字体大小',
              value: _settings.fontSize,
              min: DesktopLyricsSettings.fontSizeMin,
              max: DesktopLyricsSettings.fontSizeMax,
              label: '${_settings.fontSize.round()}sp',
              onChanged: (v) => _update((s) => s.copyWith(fontSize: v)),
            ),
            _SettingsDivider(),
            _SliderTile(
              key: const Key('slider_text_opacity'),
              icon: Icons.format_paint_rounded,
              iconColor: colorScheme.primary,
              title: '文字透明度',
              value: _settings.textOpacity,
              min: 0.2,
              max: 1.0,
              label: '${(_settings.textOpacity * 100).round()}%',
              onChanged: (v) => _update((s) => s.copyWith(textOpacity: v)),
            ),
            _SettingsDivider(),
            _SliderTile(
              key: const Key('slider_bg_opacity'),
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
            // 背景颜色：紧凑色块，点击打开取色弹窗（替代原整行预设色板）。
            _ColorFieldRow(
              icon: Icons.wallpaper_rounded,
              iconColor: colorScheme.primary,
              title: '背景颜色',
              currentColor: Color(_settings.backgroundColor),
              onTap: () => _pickColor(
                title: '背景颜色',
                initial: Color(_settings.backgroundColor),
                presets: const [
                  Color(0xFF1A1A2E), // Default Dark Blue
                  Color(0xFF000000), // Black
                  Color(0xFF222222), // Dark Grey
                  Color(0xFF3B1E1E), // Dark Red/Brown
                  Color(0xFF1B3B1E), // Dark Green
                  Color(0xFF2A1E3B), // Dark Purple
                  Color(0xFF1E353B), // Dark Teal
                ],
                onChanged: (c) =>
                    _update((s) => s.copyWith(backgroundColor: c.toARGB32())),
              ),
            ),
            _SettingsDivider(),
            // 歌词配色：成组方案一键切换（与悬浮窗快捷菜单同一组预设）。
            _SchemeChipsRow(
              settings: _settings,
              onChanged: (scheme) => _update(
                (s) => s.copyWith(
                  unplayedTextColor: scheme.unplayedTextColor,
                  textColor: scheme.unplayedTextColor,
                  playedTextColor: scheme.playedTextColor,
                ),
              ),
            ),
            _SettingsDivider(),
            // 歌词/高亮细调：紧凑色块打开取色弹窗，自由取色。
            _TextSwatchSubRow(
              fields: [
                _ColorField(
                  label: '歌词颜色',
                  color: Color(_settings.unplayedTextColor),
                  onTap: () => _pickColor(
                    title: '歌词颜色',
                    initial: Color(_settings.unplayedTextColor),
                    presets: const [
                      Colors.white,
                      Color(0xFFFFD700), // Gold
                      Color(0xFFFF69B4), // Pink
                      Color(0xFF00BFFF), // Sky blue
                      Color(0xFF00FF7F), // Spring green
                      Color(0xFFFF6347), // Tomato
                      Color(0xFF000000), // Black
                    ],
                    onChanged: (c) => _update(
                      (s) => s.copyWith(
                        unplayedTextColor: c.toARGB32(),
                        textColor: c.toARGB32(),
                      ),
                    ),
                  ),
                ),
                _ColorField(
                  label: '高亮颜色',
                  color: Color(_settings.playedTextColor),
                  onTap: () => _pickColor(
                    title: '高亮颜色',
                    initial: Color(_settings.playedTextColor),
                    presets: const [
                      Color(0xFFFFD700), // Gold
                      Color(0xFFFFEE58), // Yellow
                      Color(0xFFFF6347), // Coral
                      Color(0xFF00BFFF), // Sky Blue
                      Color(0xFF00FF7F), // Spring Green
                      Color(0xFFFFFFFF), // White
                    ],
                    onChanged: (c) => _update(
                      (s) => s.copyWith(playedTextColor: c.toARGB32()),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBehaviorSection(BuildContext context, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '行为'),
        const SizedBox(height: 8),
        _SettingsCard(
          children: [
            _SwitchTile(
              icon: Icons.lock_rounded,
              iconColor: colorScheme.primary,
              title: isDesktopFormFactor ? '锁定桌面歌词' : '锁定位置',
              subtitle: isDesktopFormFactor
                  ? '锁定后桌面歌词鼠标穿透，可在托盘或此处解锁'
                  : '锁定后无法拖动移动歌词悬浮窗，点击悬浮窗锁图标可解锁',
              value: _settings.locked,
              // PC：桌面歌词未显示时锁定无意义，置灰。
              // 移动端保持原行为：开关始终可点（不改移动端）。
              onChanged: !isDesktopFormFactor ||
                      widget.player.desktopLyricsEnabled
                  ? (v) => _update((s) => s.copyWith(locked: v))
                  : null,
            ),
            // PC：锁定语义 = QQ 音乐式全穿透，"触摸穿透"已被锁定吸收，
            // 不再提供独立开关（旧持久化字段仍兼容解析）。
            // 移动端（Android 悬浮窗）locked 与 passthrough 是两个独立
            // 原生行为，开关原样保留，不动移动端。
            if (!isDesktopFormFactor) ...[
              _SettingsDivider(),
              _SwitchTile(
                icon: Icons.touch_app_rounded,
                iconColor: colorScheme.primary,
                title: '触摸穿透',
                subtitle: '启用后点击事件会穿透到下层应用',
                value: _settings.passthrough,
                onChanged: (v) => _update((s) => s.copyWith(passthrough: v)),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildTipCard(BuildContext context, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isDesktopFormFactor
                  ? '桌面歌词窗口支持自由拖拽缩放与锁定穿透，悬浮工具栏可快捷调节播放并进入设置。'
                      '双行显示时高亮会在上下两行交替：正在唱的那句始终留在原地，'
                      '另一行换成下一句；对齐可选两行同侧（居中/左/右）或左右分离（上行居左、下行居右）。'
                      '调乱了可点右上角「恢复默认」一键还原外观。'
                  : '歌词悬浮窗支持拖动与右下角手柄缩放。单行只显示当前句，'
                      '双行会同时显示下一句；锁定后无法拖动，点击悬浮窗锁图标可解锁。'
                      '调乱了可点右上角「恢复默认」一键还原外观。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('桌面歌词设置'),
        actions: [
          TextButton.icon(
            onPressed: _resetToDefaults,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('恢复默认'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 720;
          final Widget content;
          if (isWide) {
            content = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 12, 24),
                    children: [
                      _buildAppearanceSection(context, colorScheme),
                      const SizedBox(height: 16),
                      _buildBehaviorSection(context, colorScheme),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 4,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(4, 12, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionHeader(title: '效果预览'),
                        const SizedBox(height: 8),
                        _LyricsPreviewCard(settings: _settings),
                        const SizedBox(height: 12),
                        _buildTipCard(context, colorScheme),
                      ],
                    ),
                  ),
                ),
              ],
            );
          } else {
            content = ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              children: [
                const _SectionHeader(title: '效果预览'),
                const SizedBox(height: 8),
                _LyricsPreviewCard(settings: _settings),
                const SizedBox(height: 16),
                _buildAppearanceSection(context, colorScheme),
                const SizedBox(height: 16),
                _buildBehaviorSection(context, colorScheme),
              ],
            );
          }
          // 大窗口下限宽并居中，避免控件被整窗拉伸得过大、过散。
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isWide ? 960 : 640),
              child: content,
            ),
          );
        },
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
      indent: 48,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .4),
    );
  }
}

/// 单行紧凑设置行：图标 + 标题靠左，控件与取值靠右，一项一整行。
class _SliderTile extends StatelessWidget {
  const _SliderTile({
    super.key,
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 12),
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 13,
                  ),
                ),
                child: Slider(
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  onChanged: onChanged,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  label,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
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

/// 单色块字段行：图标 + 标题靠左，当前颜色色块靠右，点击打开取色弹窗。
class _ColorFieldRow extends StatelessWidget {
  const _ColorFieldRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.currentColor,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final Color currentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 12),
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          _ColorSwatchButton(fieldKey: 'color_field_$title', color: currentColor, onTap: onTap),
        ],
      ),
    );
  }
}

/// 歌词颜色/高亮颜色细调子行：标签 + 紧凑色块靠右排布，点击打开取色弹窗。
class _TextSwatchSubRow extends StatelessWidget {
  const _TextSwatchSubRow({required this.fields});

  final List<_ColorField> fields;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Spacer(),
          for (final field in fields) ...[
            Text(
              field.label,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            _ColorSwatchButton(
              fieldKey: 'color_field_${field.label}',
              color: field.color,
              onTap: field.onTap,
            ),
            if (field != fields.last) const SizedBox(width: 20),
          ],
        ],
      ),
    );
  }
}

class _ColorField {
  const _ColorField({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;
}

/// 取色入口色块：圆角方块填充当前颜色，点击打开取色弹窗。
class _ColorSwatchButton extends StatelessWidget {
  const _ColorSwatchButton({
    required this.fieldKey,
    required this.color,
    required this.onTap,
  });

  final String fieldKey;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key(fieldKey),
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌词配色方案行：成组方案双色圆点（与悬浮窗快捷菜单同一组预设），
/// 点击同步切换歌词色与高亮色；命中当前设置的白圈高亮。
class _SchemeChipsRow extends StatelessWidget {
  const _SchemeChipsRow({required this.settings, required this.onChanged});

  final DesktopLyricsSettings settings;
  final ValueChanged<DesktopLyricsColorScheme> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.palette_rounded,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Text(
            '歌词配色',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final scheme in DesktopLyricsColorScheme.presets) ...[
                _SchemeChip(
                  scheme: scheme,
                  selected:
                      settings.unplayedTextColor == scheme.unplayedTextColor &&
                      settings.playedTextColor == scheme.playedTextColor,
                  onTap: () => onChanged(scheme),
                ),
                if (scheme != DesktopLyricsColorScheme.presets.last)
                  const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SchemeChip extends StatelessWidget {
  const _SchemeChip({
    required this.scheme,
    required this.selected,
    required this.onTap,
  });

  final DesktopLyricsColorScheme scheme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 左右对半双色：左=歌词（未播放）色，右=高亮（已播放）色。
    return Tooltip(
      message: scheme.name,
      child: InkWell(
        key: ValueKey('scheme_${scheme.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Color(scheme.unplayedTextColor),
                Color(scheme.playedTextColor),
              ],
              stops: const [0.5, 0.5],
            ),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant,
              width: selected ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _SegmentTile<T> extends StatelessWidget {
  const _SegmentTile({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.selected,
    required this.segments,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final T selected;
  final List<ButtonSegment<T>> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final titleRow = Row(
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: 12),
        Text(
          title,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
    final segmentButton = SegmentedButton<T>(
      showSelectedIcon: false,
      segments: segments,
      selected: {selected},
      onSelectionChanged: (newSet) {
        if (newSet.isNotEmpty) {
          onChanged(newSet.first);
        }
      },
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: WidgetStatePropertyAll(Size(0, 32)),
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10),
        ),
        textStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窗口较窄时单行放不下四个分段（对齐方式），回退为上下两行。
          if (constraints.maxWidth >= 460) {
            return Row(
              children: [
                titleRow,
                const Spacer(),
                segmentButton,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleRow,
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: segmentButton),
            ],
          );
        },
      ),
    );
  }
}

class _LyricsPreviewCard extends StatelessWidget {
  const _LyricsPreviewCard({required this.settings});

  final DesktopLyricsSettings settings;

  @override
  Widget build(BuildContext context) {
    final playedColor = Color(settings.playedTextColor);
    final unplayedColor = Color(settings.unplayedTextColor);
    // 移动端原生悬浮窗恒为左对齐（设置页已隐藏对齐选项），预览必须与
    // 真实悬浮窗一致；PC 则按设置值渲染。
    final effectiveAlignment = isDesktopFormFactor
        ? settings.alignment
        : DesktopLyricsAlignment.left;
    final isSplit = DesktopLyricsAlignment.isSplit(effectiveAlignment);
    final textAlign = switch (effectiveAlignment) {
      DesktopLyricsAlignment.left => TextAlign.left,
      DesktopLyricsAlignment.right => TextAlign.right,
      _ => TextAlign.center,
    };
    final lineAlignment = switch (effectiveAlignment) {
      DesktopLyricsAlignment.left => Alignment.centerLeft,
      DesktopLyricsAlignment.right => Alignment.centerRight,
      _ => Alignment.center,
    };

    return Container(
      height: 110,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF161622),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context)
              .colorScheme
              .outlineVariant
              .withValues(alpha: 0.3),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Container(
        color: Color(settings.backgroundColor)
            .withValues(alpha: settings.opacity),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth;
            final Widget body;
            if (settings.singleLine) {
              body = Align(
                alignment: lineAlignment,
                child: LyricsKaraokeLine(
                  text: '时音 听我想听',
                  fontSize: settings.fontSize,
                  playedColor: playedColor,
                  unplayedColor: unplayedColor,
                  progress: 0.45,
                  availableWidth: availableWidth,
                  alignment: textAlign,
                  textOpacity: settings.textOpacity,
                  fontWeight: FontWeight.bold,
                ),
              );
            } else {
              final dualLineWidth = availableWidth - 40.0;
              final effectiveDualWidth =
                  dualLineWidth > 0 ? dualLineWidth : availableWidth;
              final dualFontSize = settings.fontSize * 0.82;

              // 与悬浮窗双行渲染同一套规则：正在唱的那行带逐字进度，
              // 另一行是未播放色的下一句；横向锚点按 alignment 分流。
              Widget previewLine({
                required String text,
                required bool active,
                required Alignment align,
                required TextAlign align2,
              }) {
                return Align(
                  alignment: align,
                  child: LyricsKaraokeLine(
                    text: text,
                    fontSize: dualFontSize,
                    playedColor: playedColor,
                    unplayedColor: active
                        ? unplayedColor
                        : unplayedColor.withValues(alpha: 0.65),
                    progress: active ? 0.45 : 0.0,
                    availableWidth: effectiveDualWidth,
                    alignment: align2,
                    textOpacity: active
                        ? settings.textOpacity
                        : settings.textOpacity * 0.65,
                    fontWeight: FontWeight.bold,
                  ),
                );
              }

              body = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  previewLine(
                    text: '时音 听我想听',
                    active: true,
                    align: isSplit ? Alignment.centerLeft : lineAlignment,
                    align2: isSplit ? TextAlign.left : textAlign,
                  ),
                  const SizedBox(height: 6),
                  previewLine(
                    text: '让音乐更自由',
                    active: false,
                    align: isSplit ? Alignment.centerRight : lineAlignment,
                    align2: isSplit ? TextAlign.right : textAlign,
                  ),
                ],
              );
            }

            return FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: availableWidth,
                child: body,
              ),
            );
          },
        ),
      ),
    );
  }
}
