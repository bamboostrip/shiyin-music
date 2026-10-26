import 'package:flutter/material.dart';

import '../../controllers/theme_controller.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 车机显示缩放档位的中文文案（形如「标准（100%）」）。
///
/// 档位值限定在 [ThemeController.carDisplayScaleOptions] 内，百分数用四舍五入
/// 保证 115% / 130% 这类非整数档位也显示整百分比。
String carDisplayScaleLabel(double scale) {
  final percent = (scale * 100).round();
  if (scale <= 0.8) return '紧凑（$percent%）';
  if (scale <= 0.9) return '略小（$percent%）';
  if (scale <= 1.0) return '标准（$percent%）';
  if (scale <= 1.15) return '放大（$percent%）';
  return '特大（$percent%）';
}

/// 设置页「车机显示」分节。
///
/// 只在车机模式开启时由 `SettingsPage` 挂载（`!isDesktopFormFactor &&
/// theme.carModeEnabled` 的门控在页面层完成，本组件不再自行判断）。
/// 提供界面缩放档位、上下安全留白与恢复默认；真正的视口缩放与留白
/// 由 `CarDisplayViewport` 消费这些设置。
class CarDisplaySettingsSection extends StatelessWidget {
  const CarDisplaySettingsSection({super.key, required this.theme});

  final ThemeController theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '车机显示'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.aspect_ratio_rounded,
              iconColor: const Color(0xFF5C6BC0),
              title: '界面缩放',
              subtitle: carDisplayScaleLabel(theme.carDisplayScale),
              onTap: () => _selectScale(context),
            ),
            const SettingsDivider(),
            SettingsTile(
              icon: Icons.vertical_align_top_rounded,
              iconColor: const Color(0xFF00897B),
              title: '顶部安全留白',
              subtitle: _marginSubtitle(theme.carMarginTop, '为顶部悬浮状态栏让位'),
              onTap: () => _editMargin(context, top: true),
            ),
            const SettingsDivider(),
            SettingsTile(
              icon: Icons.vertical_align_bottom_rounded,
              iconColor: const Color(0xFF26A69A),
              title: '底部安全留白',
              subtitle: _marginSubtitle(theme.carMarginBottom, '为底部悬浮条让位'),
              onTap: () => _editMargin(context, top: false),
            ),
            const SettingsDivider(),
            SettingsTile(
              icon: Icons.restart_alt_rounded,
              iconColor: const Color(0xFFEF6C00),
              title: '恢复默认车机显示',
              subtitle: theme.hasCustomCarDisplay
                  ? '缩放 100%、上下留白 0'
                  : '当前已是默认设置',
              onTap: theme.hasCustomCarDisplay
                  ? () async {
                      await theme.resetCarDisplay();
                      Toast.success('已恢复默认车机显示');
                    }
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  /// 留白瓦片副标题：0 时明确「不额外留白」，避免 0 dp 被误解为未生效。
  String _marginSubtitle(double margin, String purpose) {
    if (margin <= 0) return '0 dp · 不额外留白';
    return '${margin.round()} dp · $purpose';
  }

  /// 底部弹窗选择界面缩放档位。
  ///
  /// 先让弹窗 `pop` 返回选中档位、再 `await setCarDisplayScale`：缩放会
  /// 改变弹窗所在视口，若在弹窗存活期间 notifyListeners，弹窗自身内容
  /// 也会被重排/跳变。
  Future<void> _selectScale(BuildContext context) async {
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
              for (final scale in ThemeController.carDisplayScaleOptions) ...[
                InkWell(
                  onTap: () => Navigator.of(ctx).pop(scale),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          scale == theme.carDisplayScale
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: scale == theme.carDisplayScale
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
                                carDisplayScaleLabel(scale),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              Text(
                                _scaleDescription(scale),
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
                if (scale != ThemeController.carDisplayScaleOptions.last)
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

    final selected = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '界面缩放',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),
                buildOptions(sheetContext),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null) return;
    await theme.setCarDisplayScale(selected);
  }

  String _scaleDescription(double scale) {
    final percent = ((scale - 1) * 100).round();
    if (percent == 0) return '默认大小';
    return percent > 0 ? '整体放大 $percent%' : '整体缩小 ${-percent}%';
  }

  /// 底部弹窗编辑单侧安全留白。
  ///
  /// 留白先随弹窗 `pop` 返回、再 `await` 写入：留白会移动整个视口内容（弹窗
  /// 也在视口内），弹窗存活期间改值会让它自己跳变并遮住真实让位效果。
  Future<void> _editMargin(BuildContext context, {required bool top}) async {
    final selected = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        return _CarMarginSheet(
          title: top ? '顶部安全留白' : '底部安全留白',
          description: top
              ? '车机状态栏悬浮在应用上方、系统未上报高度时，向下留出这段距离'
              : '车机导航条/控制栏悬浮在应用下方、系统未上报高度时，向上留出这段距离',
          value: top ? theme.carMarginTop : theme.carMarginBottom,
        );
      },
    );
    if (selected == null) return;
    if (top) {
      await theme.setCarMarginTop(selected);
    } else {
      await theme.setCarMarginBottom(selected);
    }
  }
}

/// 留白滑杆弹窗：拖动只改本地值，点「完成」才把最终值随 pop 返回给调用方。
class _CarMarginSheet extends StatefulWidget {
  const _CarMarginSheet({
    required this.title,
    required this.description,
    required this.value,
  });

  final String title;
  final String description;
  final double value;

  @override
  State<_CarMarginSheet> createState() => _CarMarginSheetState();
}

class _CarMarginSheetState extends State<_CarMarginSheet> {
  late double _value = widget.value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  '${_value.round()} dp',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            Slider(
              value: _value,
              min: 0,
              max: ThemeController.carMarginMax,
              divisions: 20,
              label: '${_value.round()} dp',
              onChanged: (value) => setState(() => _value = value),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 46,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_value),
                child: const Text('完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
