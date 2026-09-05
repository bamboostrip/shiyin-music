# 时音 Windows 更新能力设计（V1）

> 日期：2026-09-05 · 分支：`feature/pc-desktop-adaptation`
> 需求来源：用户提供的《时音 Windows 更新 - 粗略需求文档（V1 简化版）》+ PS 修正意见。

## 1. 背景与调研结论

### 1.1 现状
- 更新检查仅支持 Android（`AppUpdateService.isSupportedPlatform`）；
  数据源 GitHub Releases（`bamboostrip/shiyin-music`），更新 = 跳浏览器下载。
- Android CI（`build-android.yml`）打 `v*` tag 时产出 impeller/skia 双变体 APK，
  按固定顺序（impeller 在前）附加到 Release。
- Windows 端已有本地构建脚本 `build_windows.ps1`，产物为整个 runner 目录
  （exe + dll + data），Rust `kugou_engine.dll` 由 `windows/CMakeLists.txt` 自动 cargo build。

### 1.2 需求文档 PS 修正的调研结论
1. **"sika" = "skia"**：Android 双渲染器分包（`shiyin-vX.Y.Z-skia-arm64.apk`）。
   PC 端不做渲染器分包，每形态一个产物。
2. **Linux/macOS 本期不打包**（"确实不冲突才打包"判定为冲突）：
   - Linux：`linux/CMakeLists.txt` 无 Rust 集成（构建通过但 `kugou_engine` 缺失，
     搜索等核心功能不可用）；且 `just_audio` 在 Linux 无平台实现（无法播放音乐）。
   - macOS：`Runner.xcodeproj` 无 Rust 链接配置；音频虽可用（just_audio darwin），
     但盲改 Xcode 工程无法在本机验证，风险不可控。
   - 待后续单独立项补齐 Rust 集成后再上 CI。
3. **403 风控规避**（移植自 `D:\AllCode\rust\handwrite-sim` 的 `updater.rs` 多级容灾）：
   - L1 `api.github.com /releases/latest`（信息最全，60 次/时/IP 限额，403 风险源）
   - L2 `github.com /releases.atom`（订阅源，无 API 频控）取版本+正文，
     `github.com /releases/expanded_assets/{tag}`（资产页，无频控）取附件直链
   - L3 `github.com /releases/latest` 302 重定向 Location 头探测最新 tag（无频控），
     再配 expanded_assets 补直链
   - L1 返回 404 = 仓库无发布，直接判"暂无发布版本"（无需降级）；
     L1 403/网络失败才逐级降级；三级全失败时聚合报错（含"检查频繁，稍后再试"文案）。
4. **安装版也保留浏览器下载入口**（PS 修正）：安装版弹窗提供
   "浏览器下载"次级按钮（打开 setup.exe 直链），应用内下载仅为主路径。

## 2. 总体方案

| 形态 | 检查 | 下载 | 安装 |
|---|---|---|---|
| 便携版 | 应用内（多级容灾） | 不下载，跳浏览器 zip 直链 | 用户自行解压覆盖 |
| 安装版 | 应用内（同逻辑） | 应用内 dio 下载 setup.exe（进度+取消），**次级入口：浏览器下载** | 停清理 → 拉起向导 → `exit(0)` |

- **形态判定**：启动后首次访问时判定一次并缓存（static late final）——
  exe 同目录存在 `installed_by_inno.flag` ⇒ 安装版，否则便携版。
- **附件命名约定（CI 必须遵守）**：
  `shiyin-vX.Y.Z-windows-x64-portable.zip` / `shiyin-vX.Y.Z-windows-x64-setup.exe`，
  识别靠后缀（`-portable.zip` / `-setup.exe`），顺序不限。
- 分发 exe 更名：CI 打包阶段把 `kgka_music_hl.exe` 复制为 `ShiyinMusic.exe`
  （仅分发产物，开发构建不变；代码中无 exe 文件名依赖，已核实）。

## 3. 代码改动

### 3.1 `lib/models/app_version.dart`
- `AppUpdatePlatform` 增加 `windows` 成员。
- `fromGitHubRelease` 新增 `windowsAssetKind` 参数（`''` 非 Windows /
  `'portable'` / `'setup'`）：Windows 分支按后缀选附件，选不中回退
  同类扩展名 → Release 页。
- 抽出顶层函数 `pickUpdateAssetUrl(assets, {renderer, windowsAssetKind})`：
  统一附件选择规则，供 API 路径与容灾路径（Atom/重定向）复用。

### 3.2 `lib/services/app_update_service.dart`
- `isSupportedPlatform`：Android + Windows（非 Web）。
- `_fetchLatestFromGitHub` 改为三级容灾（见 1.2.3）：
  - `_fetchViaApi`：现逻辑（404 → "暂无发布版本" 直接抛出；其余异常进入降级）。
  - `_fetchViaAtomFeed`：解析首个 `<entry>`（tag 取 `/releases/tag/` 链接或
    `<title>`，正文取 `<content type="html">` 反转义后转伪 Markdown）。
  - `_fetchViaRedirect`：`followRedirects:false` 读 Location 提取 tag。
  - `_fetchExpandedAssets(tag)`：解析 `href="/…/releases/download/…"` 直链（尽力而为）。
  - 新增纯函数（可测）：`parseLatestEntryFromAtom`、`parseExpandedAssetLinks`、
    `extractTagFromLocation`、`htmlReleaseBodyToMarkdown`、`unescapeHtml`。
- Windows 形态判定：`detectWindowsInstalledBuild(exePath)`（@visibleForTesting
  可注入路径）+ `static late final isWindowsInstalledBuild`。
- `downloadWindowsSetup(version, {onProgress, cancelToken})`：dio 下载到
  `Downloads/ShiyinMusic-Setup-v{ver}.exe`，完成后校验 size>0，返回路径。
- `launchWindowsInstallerAndExit(path)`：`Process.start(detached)` 拉起向导
  → `exit(0)`（进程退出自动释放音频/悬浮窗/文件占用；Inno 侧
  `CloseApplications=yes` 兜底其他副本）。
- `downloadAndInstall` 保持浏览器跳转语义（Android / Windows 便携版 /
  安装版"浏览器下载"入口共用）。

### 3.3 `lib/ui/widgets/app_update_widgets.dart`
- `showAppUpdateDialog`：Windows 走新的 `_WindowsUpdateDialog`（StatefulWidget）：
  - 初始态：版本 + 更新说明（复用 `_MarkdownContent`）；
    - 便携版主按钮「去下载」= 浏览器打开 zip 直链 + Toast 提示解压覆盖；
    - 安装版主按钮「下载更新」→ 进度态；次级 TextButton「浏览器下载」（PS 修正）。
    - 无附件直链时主按钮退化为「打开发布页」。
  - 进度态：百分比 + LinearProgressIndicator +「取消」（CancelToken）。
  - 完成态：「退出并安装」（launch+exit）+「稍后再装」（保留文件关闭弹窗）。
  - 失败态：Toast 报错 +「重试」+「改用浏览器下载」。
- Android 路径行为不变。

### 3.4 `installer/`（新增）
- `shiyin.iss`：Inno Setup 脚本。要点：
  - 固定 `AppId`；`DefaultDirName={localappdata}\ShiyinMusic` +
    `PrivilegesRequired=lowest`（免 UAC，per-user）；
  - `CloseApplications=yes`；中文简体+英文语言；
  - 源 = CI 暂存的 portable 目录（与 zip 同源负载）；
  - 安装 `installed_by_inno.flag` 到 `{app}`（形态判定依据）；
  - 版本经 `/DAppVersion=` 注入；桌面/开始菜单快捷方式（可勾选）。
- `installed_by_inno.flag`：空占位文件（仅安装版会有，zip 内绝不含）。

### 3.5 `.github/workflows/build-windows.yml`（新增）
- 触发：`push tags v*` + `workflow_dispatch`；`permissions: contents: write`。
- windows-latest：checkout → Flutter 3.44.8 → Rust stable → rust-cache →
  `flutter build windows --release`（CMake 自动 cargo build）。
- 暂存 `dist/portable/`（exe 改名 ShiYinMusic.exe）→ 7z 打包
  `shiyin-v{tag}-windows-x64-portable.zip`（文件在 zip 根，便于解压覆盖）。
- `choco install innosetup` → `iscc /DAppVersion=` → `dist/shiyin-v{tag}-windows-x64-setup.exe`。
- tag 构建时 `softprops/action-gh-release@v2` 追加两附件（不覆盖 body，不与
  Android 工作流冲突——不同文件名并发上传安全）。

### 3.6 文档
- `docs/release-process.md`：新增 Windows 双产物发版说明、附件命名约定、
  多级容灾与 403 说明、验收步骤；说明 Linux/macOS 暂缓原因与前置条件。

## 4. 非功能
- 网络超时 15s（API）/ 10s（Atom/资产页）；自动检查失败静默，手动失败 Toast。
- 便携版绝不触碰运行中文件；安装版退出安装 = detached 拉起 + exit(0)。
- 伪便携确认：Windows 数据落 `%APPDATA%`（shared_preferences/path_provider），
  与 exe 目录无关，覆盖解压安全。

## 5. 测试与验收
- 单测（新增 `test/services/app_update_fallback_test.dart`）：
  附件选择（portable/setup/android 渲染器）、Atom 解析、expanded_assets 解析、
  Location 提取、HTML→Markdown、flag 形态判定（注入临时目录）。
- `flutter analyze` + 全量 `flutter test` 通过。
- CI 验收以需求文档第 5 节为准（首次打 tag 后人工核对 Release 双附件）。
