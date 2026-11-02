import 'package:flutter/material.dart';

import '../../models/music_models.dart';

/// 下载音质档位微标（128K / 320K / FLAC）。
///
/// 与桌面表格行里按标题猜的 Hi-Res/SQ/VIP 微标不是一回事：这里展示的是
/// 「已下载文件的实际档位」，同一行可能两个都有，
/// 所以尺寸、内边距刻意对齐 `_buildQualityBadge`，风格保持同级。
///
/// 只读展示：不允许接收点击（纯 Container 不参与命中测试），也不参与语义
/// （[ExcludeSemantics]）——整行本身已可点击并有自己的读屏文案，徽标再
/// 冒出 "128K" 只会给读屏添噪。
class AudioQualityBadge extends StatelessWidget {
  const AudioQualityBadge({super.key, required this.quality});

  final AudioQuality quality;

  /// 按档位取色：灰 / 蓝 / 橙。
  ///
  /// 深色主题下直接用 600 系深色会和深底糊在一起，所以蓝色、橙色各提亮
  /// 一档；灰色沿用 [ColorScheme.onSurfaceVariant]，跟随主题自动适配。
  Color _badgeColor(ColorScheme colorScheme, bool isDark) {
    switch (quality) {
      case AudioQuality.standard:
        return colorScheme.onSurfaceVariant;
      case AudioQuality.high:
        return isDark ? const Color(0xFF64B5F6) : const Color(0xFF1E88E5);
      case AudioQuality.lossless:
        return isDark ? const Color(0xFFFFB74D) : const Color(0xFFEF6C00);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = _badgeColor(colorScheme, isDark);

    // 极淡的同色底让描边徽标在密集列表里更易分辨；深色主题提高一档浓度，
    // 否则 8% 透明度在深底上几乎不可见。
    final fillAlpha = isDark ? 0.16 : 0.08;

    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: fillAlpha),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: color.withValues(alpha: 0.75), width: 1),
        ),
        child: Text(
          quality.badge,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: color,
            // 压缩行高：10.5px 字号配 1.1 行高，整枚徽标才能压在 18px 内，
            // 不会把 48px 桌面表格行标题行撑高。
            height: 1.1,
          ),
        ),
      ),
    );
  }
}
