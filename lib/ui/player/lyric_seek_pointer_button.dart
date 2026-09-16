import 'package:flutter/material.dart';

/// QQ 音乐同款时间播放胶囊 [ ▶ mm:ss ]。
///
/// 移动端竖屏歌词列表与车机横屏歌词面板共用：用户滚动歌词时出现在
/// 焦点/锚点行右侧，点击跳转播放到该行时间。
class LyricSeekPointerButton extends StatelessWidget {
  const LyricSeekPointerButton({
    super.key,
    required this.timeText,
    required this.onTap,
  });

  final String timeText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
        decoration: BoxDecoration(
          color: const Color(0x33000000),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.32),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_arrow_rounded, size: 14, color: Colors.white),
            const SizedBox(width: 3),
            Text(
              timeText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
