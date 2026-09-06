import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 测试注入开关：非 null 时 [isDesktopFormFactor] 直接返回该值。
///
/// 仅用于 widget 测试在任意宿主上覆盖桌面/非桌面双形态；
/// 业务代码禁止写入。
bool? debugDesktopFormFactorOverride;

final bool _osIsDesktop =
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 桌面形态判定：仅由操作系统决定，与窗口大小无关。
///
/// 车机/平板/手机均为 Android，恒为 false，走既有布局路径；
/// Windows/macOS/Linux 视为桌面，启用桌面 Shell。
/// 全项目唯一的桌面平台判定入口，页面代码不得散落 Platform.isWindows。
///
/// ## macOS 适配现状（非发布目标，截至 2026-09 待设备验证）
///
/// macOS 目前保留在桌面形态里只为布局自适应可用，整体**未经真机验证、
/// 不随发布流程出包**。已知待办/风险清单，开始适配时逐项处理：
///
/// 1. 音频后端缺失：just_audio 官方无 macOS 实现，本项目仅接了
///    just_audio_windows（Windows）与 just_audio_media_kit（Linux），
///    macOS 上 AudioPlayer 无平台后端，完全无法发声。需引入
///    just_audio_avfoundation 或在 main.dart 注册 media_kit 的 macOS 分支。
/// 2. Rust 引擎未接入 macOS 构建：rust/ 仅配置了 Android(aarch64) 与
///    Windows(MSVC) 目标，macos/ Runner 的 Xcode 工程没有 cargo 构建步骤，
///    libkugou_engine 库不会被打进 .app（RustApiClient 直接不可用，
///    登录/搜索等核心 API 全挂）。需要在 Xcode 添加 Run Script 构建
///    universal binary (x86_64+aarch64-apple-darwin) 并链接。
/// 3. 托盘图标：desktop_tray 用的是 Windows .ico 资产路径，
///    system_tray 在 macOS 需要 .png 模板图标，需按平台挑选资产。
/// 4. 桌面歌词：desktop_multi_window 的 macOS 子窗引擎同样只注册插件
///    自身（与 Linux 改造前同款问题），且 window_manager macOS 侧
///    setIgnoreMouseEvents 等能力未验证；DesktopLyricsService 目前
///    仅放行 Android/Windows/Linux。
/// 5. Windows 专属 workaround 需复核：全局 ExcludeSemantics（AXTree 崩溃）
///    是 Windows 专属，macOS 不应套用；just_audio_windows 的 WinRT 竞态
///    补丁（completed 延迟/加载串行门）对 macOS 无意义但无害。
/// 6. 系统媒体集成：desktop_system_media 只注册了 Windows SMTC 与
///    Linux MPRIS，macOS 需要 MPNowPlayingInfoCenter（audio_service 生态
///    无现成实现，需自写或找包）。
/// 7. 应用内更新/安装器流程（Inno Setup、checksums）只覆盖
///    Windows/Linux/Android，macOS 需要 .dmg + Sparkle 之类的独立方案。
bool get isDesktopFormFactor =>
    debugDesktopFormFactorOverride ?? _osIsDesktop;
