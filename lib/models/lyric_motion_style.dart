/// 播放页歌词动效样式（issue #26）。
///
/// 歌词动效很主观，固定一种样式无法兼顾所有人，因此做成可选预设：
/// - [standard]：现有「稳」的样式（逐字扫色 + 当前句放大加粗，性能最好）；
/// - [lively]：Apple Music 风（当前句弹性放大 + 上下行轻微模糊渐隐）；
/// - [upstream]：上游同款景深模糊（非当前行按距离逐行加重高斯模糊，
///   无弹性缩放，焦点线与滚动动画也沿用上游参数）。
///
/// 样式只影响播放页歌词列表（移动端 + PC）；桌面歌词悬浮窗与车机
/// flutter_lyric 视图暂不跟进（见设置弹层的说明文案）。
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
  ),

  /// 上游同款：非当前行按距离逐行加重高斯模糊。
  upstream(
    storageValue: 'upstream',
    label: '上游景深',
    description: '非当前行随距离逐行加重模糊，无弹性放大（较吃性能）',
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
