/// 播放页歌词动效样式（issue #26）。
///
/// 歌词动效很主观：默认保留现有「稳」的样式（逐字扫色 + 当前句放大加粗，
/// 性能最好）；另给一套 Apple Music 那一类的样式——当前句弹性放大、
/// 上下行轻微模糊并渐隐。样式只影响播放页歌词列表（移动端 + PC），
/// 桌面歌词悬浮窗与车机 flutter_lyric 视图暂不跟进。
enum LyricMotionStyle {
  /// 现有默认样式（性能最好）。
  standard(
    storageValue: 'standard',
    label: '标准',
    description: '逐字高亮扫过，当前句放大加粗，性能最好',
  ),

  /// Apple Music 风：弹性放大 + 上下行模糊渐隐。
  lively(
    storageValue: 'lively',
    label: '灵动',
    description: '当前句弹性放大，上下行轻微模糊渐隐（Apple Music 风）',
  );

  const LyricMotionStyle({
    required this.storageValue,
    required this.label,
    required this.description,
  });

  /// 持久化值：与 enum 名称解耦，改名不破坏老用户的设置。
  final String storageValue;
  final String label;
  final String description;

  /// 读盘容错：未知/损坏值一律回退默认样式，不阻断启动。
  static LyricMotionStyle fromStorageValue(String? value) {
    for (final style in values) {
      if (style.storageValue == value) return style;
    }
    return LyricMotionStyle.standard;
  }
}
