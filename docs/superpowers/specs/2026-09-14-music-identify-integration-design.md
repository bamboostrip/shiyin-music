# 听歌识曲 (Music Identify) 全平台集成设计规范

## 1. 概述与背景
在 `feature/music-identify` 分支上已实现听歌识曲核心能力：
- **Rust 协议层**：封装酷狗指纹识别服务接口 `fingerprint.service/v1/music_trackid_mulit`，裸 PCM 上传与二进制签名（Lite 身份）；
- **桌面采集引擎**：使用 `cpal` + WASAPI loopback（支持麦克风与系统内录声音）及 `rubato` 重采样到 8000Hz 16-bit 单声道 PCM；
- **移动端采集通道**：Android 端通过 `AudioRecord` 原生通道直接采集 8000Hz PCM；
- **Dart 服务与 UI 层**：`IdentifyService` 分流与模型映射，`IdentifyPage` 独立识别界面（动效、波纹、匹配中、候选歌曲列表、点击播放）。

本次目标是将该分支完整合并至当前分支，并补全手机端首页、PC 端顶栏搜索胶囊、车机端顶栏的快捷入口，确保全平台体验一致。

## 2. 入口与交互规范

### 2.1 手机端（Mobile）
1. **首页顶栏搜索框** (`lib/ui/widgets/home_collapsible_header.dart`):
   - 在 `HomeSearchBar` 胶囊内部右侧添加 `Icons.graphic_eq_rounded` 图标按钮。
   - 点击该图标阻断默认的搜索页跳转，直接全屏打开 `IdentifyPage`；点击搜索框其余部分依然跳转 `SearchPage`。
2. **搜索页顶栏** (`lib/ui/pages/search_page.dart`):
   - 保持已有设计：顶栏输入框左侧放置 `Icons.graphic_eq_rounded` 按钮，点击打开 `IdentifyPage`。

### 2.2 PC 桌面端（Desktop）
1. **顶栏居中搜索胶囊** (`lib/ui/desktop/desktop_title_bar.dart`):
   - 在搜索胶囊内部右侧添加 `Icons.graphic_eq_rounded` 图标按钮（带 tooltip "听歌识曲"）。
   - 悬停具备 hover 背景过渡，点击打开 `fullscreenDialog` 模式的 `IdentifyPage`。
2. **搜索建议浮层** (`lib/ui/desktop/desktop_search_suggest_panel.dart`):
   - 保持已有设计：浮层顶部放置一栏「听歌识曲 · 播放中的歌也能识别」。

### 2.3 车机端（Car Mode）
1. **车机顶部导航栏** (`lib/ui/pages/app_shell.dart` - `_buildCarTopNavBar`):
   - 在已有的「搜索」药丸按钮右侧，新增紧邻的「识曲」药丸按钮（同为 46px 高、圆角 23px，带微边框与背景）。
   - 图标为 `Icons.graphic_eq_rounded`，文字为「识曲」，点击直接打开 `IdentifyPage`。

### 2.4 平台防护与生命周期
- 所有入口统一增加 `IdentifyService.isSupported`（Android / Windows / Linux 开启，其余平台隐藏）。
- `IdentifyPage` 在 `dispose()` 或主动返回时必须触发 `_backend.cancel()`，确保声卡录音流与麦克风通道即刻释放。

## 3. 验证方案
1. **Git 合并验证**：确认 `git merge feature/music-identify` 0 冲突合并。
2. **Rust 层测试**：运行 `cargo test --bin/--lib`，确保协议单测、重采样单测与音频缓冲逻辑通过。
3. **Dart 单元与 Widget 测试**：运行 `identify_service_test.dart` 和 `identify_page_test.dart` 以及各入口测试。
4. **编译验证**：确保 Flutter 桌面端及分析工具无类型与 lint 报错。
