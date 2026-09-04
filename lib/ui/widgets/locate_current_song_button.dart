import 'package:flutter/material.dart';

/// 「定位到当前播放」圆形悬浮按钮（歌单/列表页右下角）。
///
/// 纯外观组件：可见性与点击行为由宿主页面控制。圆形（[CircleBorder]），
/// 配色走主题 token（surfaceContainerHigh + 阴影），悬停/长按显示
/// Tooltip，语义标签「定位到当前播放」（桌面 hover 与读屏均可感知）。
class LocateCurrentSongButton extends StatelessWidget {
  const LocateCurrentSongButton({super.key, required this.onPressed});

  /// 定位到当前播放歌曲；进行中时宿主可传 null 禁用。
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '定位到当前播放',
      button: true,
      child: Tooltip(
        message: '定位到当前播放',
        child: Material(
          color: colorScheme.surfaceContainerHigh,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: Colors.black.withValues(alpha: .25),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(
                Icons.my_location_rounded,
                size: 22,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
