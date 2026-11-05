import 'package:flutter/material.dart';

import '../../controllers/theme_controller.dart';
import '../adaptive_layout.dart';
import '../background_crop.dart';
import '../form_factor.dart';
import '../settings/car_display_settings_section.dart';
import '../settings/settings_widgets.dart';
import '../widgets/background_crop_view.dart';
import '../widgets/theme_mode_selector.dart';
import '../widgets/toast.dart';
import 'background_crop_page.dart';

/// 「外观与个性化」二级页：外观模式 + 皮肤配色 + 自定义背景图 +
/// 字体大小/横屏/车机模式 + 车机显示。
///
/// 这些选项原先散落在主设置页的「个性化」分节与「车机显示」分节里，
/// 主页面只保留一个入口，避免一屏堆 5–9 个同类选项。
class PersonalizationSettingsPage extends StatefulWidget {
  const PersonalizationSettingsPage({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<PersonalizationSettingsPage> createState() =>
      _PersonalizationSettingsPageState();
}

class _PersonalizationSettingsPageState
    extends State<PersonalizationSettingsPage> {
  /// 选图/安装进行中：选图是异步的（相册、复制、解码探测），连点会并发装
  /// 出两张图，每次落盘都是新文件名，先完成的那张就成了文档目录里的孤儿。
  bool _pickingBackgroundImage = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('外观与个性化')),
      body: AnimatedBuilder(
        animation: widget.themeController,
        builder: (context, _) {
          final tc = widget.themeController;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              // ===== 外观模式 =====
              SectionHeader(title: '外观模式'),
              const SizedBox(height: 8),
              SettingsCard(
                children: [
                  ThemeModeSelector(
                    currentMode: tc.themeMode,
                    onChanged: (mode) => tc.setThemeMode(mode),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // ===== 配色方案 =====
              SectionHeader(title: '配色方案'),
              const SizedBox(height: 8),
              SettingsCard(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: ThemeController.presetColors.map((preset) {
                        final selected = tc.seedColor == preset.color;
                        return _ColorDot(
                          color: preset.color,
                          label: preset.name,
                          selected: selected,
                          onTap: () => tc.setSeedColor(preset.color),
                        );
                      }).toList(),
                    ),
                  ),
                  if (tc.hasCustomSeedColor) ...[
                    const SettingsDivider(),
                    SettingsTile(
                      icon: Icons.refresh_rounded,
                      iconColor: colorScheme.primary,
                      title: '恢复默认配色',
                      onTap: () =>
                          tc.setSeedColor(ThemeController.defaultSeedColor),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 24),
              // ===== 自定义背景图 =====
              SectionHeader(title: '全局背景图'),
              const SizedBox(height: 8),
              SettingsCard(
                children: [
                  SettingsSwitchTile(
                    icon: Icons.image_rounded,
                    iconColor: colorScheme.primary,
                    title: '启用自定义背景',
                    subtitle: '在所有页面上方显示自定义背景图',
                    value: tc.backgroundEnabled,
                    onChanged:
                        tc.backgroundImagePath == null ||
                            _pickingBackgroundImage
                        ? null
                        : (value) => tc.setBackgroundEnabled(value),
                  ),
                  const SettingsDivider(),
                  SettingsTile(
                    icon: Icons.photo_library_rounded,
                    iconColor: colorScheme.primary,
                    title: '选择背景图',
                    subtitle: _pickingBackgroundImage
                        ? '正在处理图片…'
                        : tc.backgroundImagePath == null
                        ? '点击从相册选择图片'
                        : '已选择背景图',
                    onTap: _pickingBackgroundImage ? null : () => _pickImage(),
                  ),
                  if (tc.backgroundImagePath != null) ...[
                    const SettingsDivider(),
                    SettingsTile(
                      icon: Icons.crop_free_rounded,
                      iconColor: colorScheme.primary,
                      title: '调整背景位置',
                      subtitle: '拖动或缩放，决定画面显示哪一部分',
                      onTap: _pickingBackgroundImage
                          ? null
                          : () => _adjustBackgroundCrop(context),
                    ),
                    const SettingsDivider(),
                    SettingsTile(
                      icon: Icons.visibility_rounded,
                      iconColor: colorScheme.primary,
                      title: '背景预览',
                      subtitle: '点击查看当前背景效果',
                      onTap: () =>
                          _showPreview(context, tc.backgroundImagePath!),
                    ),
                    const SettingsDivider(),
                    _BackgroundOpacitySlider(
                      value: tc.backgroundOpacity,
                      onChanged: (v) => tc.setBackgroundOpacity(v),
                    ),
                    const SettingsDivider(),
                    SettingsTile(
                      icon: Icons.delete_outline_rounded,
                      iconColor: colorScheme.error,
                      title: '移除背景图',
                      titleColor: colorScheme.error,
                      onTap: _pickingBackgroundImage
                          ? null
                          : () => _confirmRemove(context),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 24),
              // ===== 字体与布局 =====
              SectionHeader(title: '字体与布局'),
              const SizedBox(height: 8),
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.text_fields_rounded,
                    iconColor: const Color(0xFF3F51B5),
                    title: '字体大小',
                    subtitle: fontScaleLabel(tc.fontScale),
                    onTap: () => _selectFontScale(context),
                  ),
                  if (!isDesktopFormFactor) ...[
                    const SettingsDivider(),
                    SettingsSwitchTile(
                      icon: Icons.screen_rotation_rounded,
                      iconColor: const Color(0xFF00897B),
                      title: '横屏模式',
                      subtitle: '允许手机横屏时自动旋转（平板默认开启）',
                      value: tc.landscapeEnabled,
                      onChanged: (value) {
                        tc.setLandscapeEnabled(
                          value,
                          AdaptiveLayout.isTablet(context),
                        );
                      },
                    ),
                    const SettingsDivider(),
                    SettingsSwitchTile(
                      icon: Icons.directions_car_rounded,
                      iconColor: const Color(0xFFFF6F00),
                      title: '车机模式',
                      subtitle: '横屏时使用左侧播放面板布局并放大文字',
                      value: tc.carModeEnabled,
                      onChanged: (value) async {
                        await tc.setCarModeEnabled(value);
                        // 通知渠道在启动时按车机模式定向，切换后需完全重启
                        // 进程才生效；原生车机设备始终走静默渠道，无需提示。
                        if (!tc.isAutomotiveDevice) {
                          Toast.show(
                            '车机模式已切换，建议重启应用以同步通知栏显示方式',
                            duration: const Duration(seconds: 4),
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
              // 车机显示分节：仅车机模式开启（移动形态）时有意义。
              if (!isDesktopFormFactor && tc.carModeEnabled) ...[
                const SizedBox(height: 24),
                CarDisplaySettingsSection(theme: tc),
              ],
              // ===== 背景预览区域 =====
              if (tc.backgroundImagePath != null) ...[
                const SizedBox(height: 24),
                SectionHeader(title: '当前背景预览'),
                const SizedBox(height: 8),
                _BackgroundPreviewCard(
                  imagePath: tc.backgroundImagePath!,
                  opacity: tc.backgroundOpacity,
                  crop: tc.backgroundCrop,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 选择字体大小：桌面端居中 Dialog，移动端 BottomSheet。
  Future<void> _selectFontScale(BuildContext context) async {
    final tc = widget.themeController;
    Widget buildOptions(BuildContext ctx) {
      final colorScheme = Theme.of(ctx).colorScheme;
      final isDark = Theme.of(ctx).brightness == Brightness.dark;
      return Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: .10)
                : Colors.white.withValues(alpha: .92),
            width: 1.1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? .18 : .06),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final scale in ThemeController.fontScaleOptions) ...[
                InkWell(
                  mouseCursor: isDesktopFormFactor
                      ? SystemMouseCursors.click
                      : null,
                  onTap: () => Navigator.of(ctx).pop(scale),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          scale == tc.fontScale
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: scale == tc.fontScale
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant.withValues(
                                  alpha: .6,
                                ),
                          size: 22,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                fontScaleLabel(scale),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              Text(
                                scale == 1.0
                                    ? '默认大小'
                                    : scale == 1.1
                                    ? '整体放大 10%'
                                    : '整体放大 20%',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (scale != ThemeController.fontScaleOptions.last)
                  Divider(
                    height: 1,
                    indent: 52,
                    color: colorScheme.outlineVariant.withValues(alpha: .24),
                  ),
              ],
            ],
          ),
        ),
      );
    }

    final double? selected;
    if (isDesktopFormFactor) {
      selected = await showDialog<double>(
        context: context,
        builder: (dialogContext) {
          return Dialog(
            backgroundColor: Theme.of(dialogContext).colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '字体大小',
                          style: Theme.of(dialogContext).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(dialogContext).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    buildOptions(dialogContext),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } else {
      selected = await showModalBottomSheet<double>(
        context: context,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (sheetContext) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '字体大小',
                    style: Theme.of(sheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 12),
                  buildOptions(sheetContext),
                ],
              ),
            ),
          );
        },
      );
    }

    if (selected != null) {
      await tc.setFontScale(selected);
    }
  }

  Future<void> _pickImage() async {
    if (_pickingBackgroundImage) return;
    // 用 setState 进入/退出「处理中」：选图→裁剪→安装这段时间里要禁用
    // 开关/移除/调整等入口，避免 install 在写盘期间被反向操作插队（安装
    // 会同时写路径与构图，竞态下会出现两个相反的提示与半状态）。
    setState(() => _pickingBackgroundImage = true);
    try {
      // 选图与安装拆成两步：中间插一页裁剪，用户确认构图后才复制落盘；
      // 取消裁剪就什么都不写，旧背景完全不受影响。
      final source = await widget.themeController.pickBackgroundSourceFile();
      if (source == null || !mounted) return;
      final sourceProvider = buildBackgroundImageProvider(source.path);
      // 必须推到根 Navigator：桌面端设置页在内层内容导航里，内层导航在
      // AppShortcutScope / DesktopShell.Shortcuts 子树内，会把空格（播放）、
      // ←/→（seek）、↑/↓（音量）、Enter（整屏播放页）带进裁剪页；点侧栏
      // 或 Ctrl+4/5/6 还会 _popToContentRoot 把正在编辑的页面一起弹掉。
      final crop = await Navigator.of(context, rootNavigator: true)
          .push<BackgroundCrop>(
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => BackgroundCropPage(
                image: sourceProvider,
                initialCrop: BackgroundCrop.center,
              ),
            ),
          );
      // 裁剪页已退出：临时文件的解码结果不会再被用到，主动逐出，避免它
      // 按 LRU 一直占着全尺寸解码位（安装后主层用的是新路径的键）。
      await sourceProvider.evict();
      if (crop == null || !mounted) return;
      await widget.themeController.installBackgroundImage(source, crop: crop);
      if (!mounted) return;
      Toast.success('背景图已设置');
    } catch (error) {
      if (!mounted) return;
      Toast.error('选择图片失败：$error');
    } finally {
      if (mounted) {
        setState(() => _pickingBackgroundImage = false);
      } else {
        _pickingBackgroundImage = false;
      }
    }
  }

  /// 对已选中的背景图重新调整构图（不重新选图、不复制文件，只更新裁剪参数）。
  Future<void> _adjustBackgroundCrop(BuildContext context) async {
    final tc = widget.themeController;
    final path = tc.backgroundImagePath;
    if (path == null) return;
    // 同「选新图」：推到根 Navigator，避免桌面内层导航的全局快捷键与
    // 侧栏切换把正在编辑的裁剪页一起弹掉。
    final crop = await Navigator.of(context, rootNavigator: true)
        .push<BackgroundCrop>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => BackgroundCropPage(
              image: buildBackgroundImageProvider(path),
              initialCrop: tc.backgroundCrop,
            ),
          ),
        );
    if (crop == null || !mounted) return;
    final saved = await tc.setBackgroundCrop(crop);
    if (!mounted) return;
    if (saved) {
      Toast.success('背景位置已更新');
    } else {
      Toast.error('背景位置保存失败，请重试');
    }
  }

  void _showPreview(BuildContext context, String path) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullBackgroundPreview(
          imagePath: path,
          opacity: widget.themeController.backgroundOpacity,
          crop: widget.themeController.backgroundCrop,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除背景图'),
        content: const Text('确定要移除自定义背景图吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final cleared = await widget.themeController.clearBackgroundImage();
      if (!mounted) return;
      // 持久化失败时什么都不该改：提示失败让用户重试，而不是假装移除成功。
      if (cleared) {
        Toast.success('已移除背景图');
      } else {
        Toast.error('移除失败，请重试');
      }
    }
  }
}

// ===== 颜色选择圆点 =====

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: isDesktopFormFactor
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: selected
                    ? Border.all(
                        color: Theme.of(context).colorScheme.onSurface,
                        width: 3,
                      )
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: .35),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: selected
                  ? const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 24,
                    )
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===== 背景透明度滑块 =====

class _BackgroundOpacitySlider extends StatefulWidget {
  const _BackgroundOpacitySlider({
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_BackgroundOpacitySlider> createState() =>
      _BackgroundOpacitySliderState();
}

class _BackgroundOpacitySliderState extends State<_BackgroundOpacitySlider> {
  late double _current;

  @override
  void initState() {
    super.initState();
    _current = widget.value;
  }

  @override
  void didUpdateWidget(covariant _BackgroundOpacitySlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _current = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Icon(
              Icons.opacity_rounded,
              size: 22,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '背景透明度',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${(_current * 100).round()}%',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Slider(
                  value: _current,
                  min: 0.0,
                  max: 0.8,
                  divisions: 80,
                  label: '${(_current * 100).round()}%',
                  onChanged: (v) => setState(() => _current = v),
                  onChangeEnd: widget.onChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===== 背景预览卡片 =====

class _BackgroundPreviewCard extends StatelessWidget {
  const _BackgroundPreviewCard({
    required this.imagePath,
    required this.opacity,
    required this.crop,
  });

  final String imagePath;

  /// 当前背景透明度（0.0 ~ 0.8），预览必须与全局背景层一致，
  /// 不能固定成某一个值，否则用户调完滑杆看到的还是旧效果。
  final double opacity;

  /// 与全局背景层同一套裁剪参数，预览即所见。
  final BackgroundCrop crop;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 160,
        child: Stack(
          children: [
            Positioned.fill(
              // 缩略图按小上限解码，避免为一个 160 高的小卡片解一张整屏大图。
              child: BackgroundCropView(
                image: buildBackgroundImageProvider(
                  imagePath,
                  cap: backgroundPreviewDecodeCap,
                ),
                crop: crop,
                errorBuilder: (context) => Container(
                  color: colorScheme.surfaceContainerHighest,
                  child: const Center(
                    child: Icon(Icons.broken_image_rounded, size: 40),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: ColoredBox(
                color: (isDark ? const Color(0xFF06070A) : Colors.white)
                    .withValues(alpha: 1 - opacity),
              ),
            ),
            Positioned(
              left: 16,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '预览效果（透明度 ${(opacity * 100).round()}%）',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onPrimary,
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

// ===== 全屏背景预览 =====

class _FullBackgroundPreview extends StatelessWidget {
  const _FullBackgroundPreview({
    required this.imagePath,
    required this.opacity,
    required this.crop,
  });

  final String imagePath;
  final double opacity;
  final BackgroundCrop crop;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('背景预览')),
      body: Stack(
        children: [
          Positioned.fill(
            // 与全局背景层同一 provider + 同一裁剪参数，预览即所见。
            child: BackgroundCropView(
              image: buildBackgroundImageProvider(imagePath),
              crop: crop,
              errorBuilder: (context) =>
                  Container(color: colorScheme.surfaceContainerHighest),
            ),
          ),
          Positioned.fill(
            child: ColoredBox(
              color: (isDark ? const Color(0xFF06070A) : Colors.white)
                  .withValues(alpha: 1 - opacity),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '背景透明度 ${(opacity * 100).round()}%',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '这是实际使用时的背景效果。内容卡片会叠加在背景图上方，透明度越高背景图越明显。',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
