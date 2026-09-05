# Linux 桌面平台支持 — 设计说明

日期：2026-09-05
分支：feature/pc-desktop-adaptation
状态：已实施（验证过程见文末）

## 1. 背景与目标

项目此前只有 Windows 桌面完整可用（Android 车机另算）。`flutter build linux`
能通过但产物是残的：Rust 引擎没编没拷、just_audio 无 Linux 后端、应用启动即
在 `RustLib.init()` 处崩溃。目标：让 Linux 桌面达到与 Windows 对等的可用度
（搜索/登录/播放/歌词/下载/托盘/窗口管理），并补 CI 打包。

## 2. 对外部建议的核实结论

| 建议 | 核实结果 |
| --- | --- |
| ① Rust 没接（linux/CMakeLists.txt 无 cargo/kugou 字样） | **属实**。frb 2.12.0 加载器在 Linux 找 `libkugou_engine.so`；`main.dart` 无条件 `RustApiClient.getInstance()` → 启动即崩，是最硬阻断点。 |
| ② 音频没实现（just_audio/audio_service 无 Linux 端） | **属实**。但实际影响面比预想小：项目对 just_audio 的 API 用得很窄（setUrl/play/pause/seek/setSpeed/setVolume + 状态流；循环/随机/均衡器全部自行实现或 Android 专属），`just_audio_media_kit` 完全覆盖。 |
| ③ 启动路径没分支（无条件 AudioService.init + AudioPlayer()） | **部分不成立**。audio_service 0.18.19 的 platform interface 在 Windows/Linux 默认就是 `NoOpAudioService`（Windows 版本现在就是这么出货的，`AudioService.init` 不会崩）。真正的雷只是 just_audio 无后端，装上 media_kit 后端即可，**不需要给启动路径做大分支**。 |

## 3. 设计决策

### D1 Rust 集成：镜像 Windows 的自定义 CMake target
`linux/CMakeLists.txt` 增加与 `windows/CMakeLists.txt:63-73` 同模式的
`rust_engine_build` 自定义目标（裸 `cargo build`，cargo 增量自判重编），并把
`libkugou_engine.so` install 到 `${INSTALL_BUNDLE_LIB_DIR}`（bundle/lib）。
frb 加载器 `DynamicLibrary.open('libkugou_engine.so')` 经模板既有的
RPATH `$ORIGIN/lib` 命中。
- 备选一（FRB 官方 rust_builder + cargokit）：更"标准"但要重排工程结构、
  引入 cargokit 子模块，改动面大；弃。
- 备选二（预编 .so 提交仓库）：体积与安全皆劣；弃。

### D2 Linux 音频后端：just_audio_media_kit (^2.1.0)
依赖 `just_audio_media_kit` + `media_kit_libs_linux`；`main.dart` 在
`Platform.isLinux` 分支、`AudioService.init` 之前调用
`JustAudioMediaKit.ensureInitialized()`（源码核实：按平台标志位注册，
不碰其他平台）。media_kit 依赖为纯 Dart（media_kit 1.2.6），实测
**Windows 侧 generated_plugins.cmake 零变化**，just_audio_windows 照常。
- 运行期依赖系统 libmpv（media_kit 按序 dlopen `libmpv.so` → `.so.2` →
  `.so.1`，runtime 包即可，无需 -dev）。
- 备选（整体迁 media_kit 播放栈）：侵入 PlayerController 巨大且 Windows 无收益；弃。
- API 风险核查：项目未用 Equalizer / shuffleOrder / ConcatenatingAudioSource /
  ICY 元数据（media_kit 后端不支持或实验性的项全部未用）。

### D3 启动路径：不加 AudioService.init 分支
NoOpAudioService 证据见上；media 键/系统媒体会话属增强项而非可用性阻塞。

### D4 周边小适配
- 托盘图标：Linux 走 StatusNotifier/AppIndicator，`.ico` 兼容性差，
  `desktop_tray.dart` 在 Linux 改用打包内 `lib/assets/logo.png`。
- 下载目录：Linux 并入 `getDownloadsDirectory()` 分支（XDG ~/Downloads，
  path_provider_linux 原生支持，失败仍回退文档目录）。
- 其余插件（window_manager 本地副本、system_tray、desktop_multi_window、
  local_notifier、launch_at_startup、screen_retriever、connectivity_plus、
  url_launcher、path_provider、shared_preferences、image_picker）均声明并
  注册了 Linux 实现，无需改码。
- app_update_service 的 `isSupportedPlatform` 保持 Android/Windows：Linux
  更新通道（deb 版本比对）留作后续，无崩溃路径。

### D5 不接入 audio_service_mpris（本次）
0.2.1 稳定版缺 Seek/Seeked 信号支持，1.0 还在 beta。不接则 media 键不可用
但无任何崩溃路径（NoOp）。留作后续增强。

### D6 CI 打包（build-linux.yml）
- `ubuntu-22.04` runner（glibc 2.35 基线，覆盖 22.04/24.04 双 LTS）。
  该镜像 2026-09-17 起弃用告警、2027-04-17 移除，届时一行改 24.04
  （代价：放弃 22.04 用户），已在 workflow 注释与 release-process.md 标注。
- apt：ninja-build、libgtk-3-dev、libayatana-appindicator3-dev（system_tray
  的 CMake 硬依赖）。libmpv 是运行期 dlopen 依赖，构建期不需要。
- 产物：`shiyin-<tag>-linux-x64-portable.tar.gz`（含 README-LINUX.txt 说明
  libmpv2 安装）+ `shiyin-<tag>-linux-x64.deb`（/opt/shiyin-music +
  .desktop + hicolor 图标，`Depends: libgtk-3-0, libmpv2,
  libayatana-appindicator3-1`）。
- 备选（AppImage/fastforge）：linuxdeploy 拉起 mpv 闭包较脆、维护成本高；暂缓。

### D7 本地验证工具：scripts/build_linux_wsl.sh
WSL2 内免 sudo 引导 ninja（静态二进制）/rustup（minimal）/Flutter SDK
（与 CI 同版本 tarball），仓库拷入 WSL 原生 fs（DrvFS 上跑 cargo LTO 极慢），
并用 `apt-get download + dpkg -x + 自写 .pc（PKG_CONFIG_PATH）` 用户态
staging appindicator，绕过 system_tray 的构建硬依赖。

## 4. 明确不做 / 已知限制
- 桌面歌词悬浮窗（desktop_multi_window + 穿透）在 Linux 未做原生验证，
  代码路径已有逐项 try/catch 降级；实测后如有问题另行修复。
- media 键 / MPRIS 缺失（D5）；GNOME 托盘需用户装 AppIndicator 扩展（生态现状）。
- 均衡器/音效仅 Android（与 Windows 现状一致，MethodChannel 门控已生效）。
- loudness 分析 MethodChannel 在桌面无原生实现，MissingPluginException 已被
  捕获降级（Windows 同样如此，负增益走 setVolume 仍可用）——非 Linux 特有，不动。
- main.dart / playlist_detail / desktop_song_table_row 的 ExcludeSemantics
  仅包 Windows（AXTree 崩溃规避是 Windows 特有缺陷），Linux 不套。

## 5. 验证（2026-09-06 实测）

- Windows 回归（全部通过）：
  - `flutter pub get` / `flutter analyze`（0 issue）/ `flutter test`（365 通过）
    / `flutter build windows --release`；
  - `windows/flutter/generated_plugins.cmake` 零变化，pubspec.lock 无任何
    media_kit Windows 侧插件混入，just_audio_windows 照常。
- Linux 真实构建（WSL2 Ubuntu 24.04，`scripts/build_linux_wsl.sh`）：
  - `✓ Built build/linux/x64/release/bundle/kgka_music_hl`；
  - `bundle/lib/libkugou_engine.so`（4.5MB，cargo release LTO 产物）与
    libapp.so、libflutter_linux_gtk.so、10 个插件 .so 全部入库；
  - `ldd` 全 bundle 零 "not found"。
- Linux 冒烟（WSLg 图形会话，用户态解包 libmpv2 闭包 + LD_LIBRARY_PATH）：
  - FRB 加载 `libkugou_engine.so` 成功（启动序列无 FFI 错误）；
  - `media_kit_libs_linux registered`，media_kit 找到 libmpv（音频后端就绪）；
  - 托盘初始化成功：`SystemTray::set_system_tray_info icon_path:
    .../logo.png, toolTip: 时音`，右键菜单 8 项全部构建（验证了 .png 适配）；
  - runApp 完成后进程持续存活（timeout 击杀，exit 124 = 全程无崩溃）。
- 构建脚本在无 sudo 环境的自动兜底（均在脚本内自动化）：
  clang（flutter 硬依赖，CC/CXX 被工具硬编码）、appindicator/ido/libnotify
  （插件 CMake 硬依赖，staged .pc 修正 prefix 经 PKG_CONFIG_PATH 注入）、
  rustup 工具链损坏自修复、pub.dev 不可达自动切换 flutter-io.cn 镜像 +
  `--offline` 兜底。
- 顺带修复的预先存在 bug：`linux/CMakeLists.txt` 的 bundle 目录变量定义在
  `add_subdirectory(runner)` 之后，runner 的图标 install() 解析到
  `/app_icon` 导致 install 阶段必炸——此前 Linux 从未构建到该步骤故未暴露；
  现已把变量定义上移。
- 本地网络受限兜底（仅 WSL 本机构建，CI 不受影响）：本机网络曾对
  github codeload 干扰，media_kit_libs_linux 的 mimalloc 下载反复
  "Integrity check failed"。曾临时在 WSL pub 缓存把
  MIMALLOC_USE_STATIC_LIBS 置 OFF 完成验证（分配器性能覆盖项，功能等价）；
  **网络恢复后已还原 ON 并完成完整静态路径验证**：codeload 下载
  （MD5 5179c8f5… 校验通过）→ mimalloc.o 编译 → 链接进 runner，
  全净构建 + 冒烟全绿。备选通道与操作方法见 build_linux_wsl.sh 头部注释
  （含 gh CLI 认证端点字节一致的取法）。
- 已知 WSL 日志噪音：connectivity_plus 内部对 NetworkManager 的
  fire-and-forget 调用在无 NM 的极简环境（WSL）打印 Unhandled Exception，
  不影响运行；真实 Linux 桌面均有 NM 不会出现。NetworkMonitor 的事件流
  已加 onError 降级。
