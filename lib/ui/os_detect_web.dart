/// Web 桩：浏览器宿主一律按非桌面处理（移动端布局）。
/// Web 不是正式发布目标，此处仅保证 `dart:io` 不污染编译。
bool get hostIsDesktop => false;
