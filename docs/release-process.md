# 时音 发版流程

> 适用仓库：`bamboostrip/shiyin-music`
> CI 工作流：
> - `.github/workflows/build-android.yml`（打 `v*` tag 自动构建 skia/impeller 双变体 arm64 APK 并按固定顺序附加到 Release）
> - `.github/workflows/build-windows.yml`（打 `v*` tag 自动构建 Windows 便携包 + 安装包并附加到 Release）

---

## 一、发版前检查

1. 确认所有要发布的修改已合并到 `main`
2. 确认 CI 在 `main` 上最近一次构建通过（如有）

## 二、签名配置（已就绪，无需每次操作）

本地和 CI 使用**同一个 release keystore**，签名一致，可互相覆盖安装。

| 项目 | 说明 |
|------|------|
| 密钥文件 | `android/app/release.keystore`（已 gitignore，**不可丢失**） |
| 本地配置 | `android/key.properties`（已 gitignore） |
| CI 配置 | GitHub Secrets：`RELEASE_KEYSTORE_BASE64` + `RELEASE_KEYSTORE_PASSWORD` |
| 别名 | `shiyin` |
| 构建逻辑 | `build.gradle.kts` 检测到 `key.properties` 时用 release 签名，否则回退 debug |

> ⚠️ **密钥密码丢失 = app 永远无法覆盖更新**，务必备份密码和 keystore 文件。
>
> 历史说明：v2.4.2 及之前的 CI 构建使用 debug 签名，与当前 release 签名不一致。
> 从 v2.4.3 起统一为 release 签名，旧版用户需卸载后重装。

Windows 分发无签名要求（不做代码签名），但 Inno 的 `AppId` 一经发布**不可更改**
（见 `installer/shiyin.iss`，升级安装与卸载识别都依赖它）。

## 三、升级版本号（三处必须同步）

| 文件 | 字段 | 示例 |
|------|------|------|
| `pubspec.yaml` | `version: x.y.z+code` | `2.4.2+242` |
| `lib/config/app_config.dart` | `appVersion` | `'2.4.2'` |
| `lib/config/app_config.dart` | `appVersionCode` | `'242'` |

> ⚠️ **必须在打 tag 之前完成版本号升级**，否则 CI 打出的包内部版本号是旧的，
> 会导致"关于"页显示错误版本、检查更新逻辑异常。

版本号规则：
- `versionName`：语义化版本 `major.minor.patch`
- `versionCode`：`major * 10000 + minor * 100 + patch`（如 `2.4.2` → `20402`，简写 `242`）

## 四、更新更新日志

编辑 `update.md`，在顶部添加新版本条目，格式参考已有版本：

```markdown
## v2.4.2

- 修复 xxx 问题
- 新增 xxx 功能
- 优化 xxx 体验
```

## 五、提交并推送

```bash
git add -A
git commit -m "release: v2.4.2"
git push origin main
```

## 六、创建 GitHub Release（带详细 changelog）

用 `gh` CLI 创建 Release，**先写 Release 再打 tag**，这样两个 CI 工作流只附加
附件、不覆盖笔记：

```bash
# 1. 写 Release 笔记到临时文件（避免 shell 转义问题）
#    内容从 update.md 对应版本摘取，可加分类标题（Bug 修复 / 新功能 / 技术改进）

# 2. 创建 Release（自动在远程创建 tag，同时触发 Android 与 Windows 两条流水线）
gh release create v2.4.2 --target main --title "时音 v2.4.2" --notes-file <notes-file>
```

Release 笔记模板：

```markdown
## 更新内容

### 🐛 Bug 修复

- **简要标题**：详细说明

### ✨ 新功能

- **简要标题**：详细说明

### 🔧 技术改进

- 说明

---

**完整变更**：https://github.com/bamboostrip/shiyin-music/compare/v2.4.1...v2.4.2
```

> ⚠️ CI workflow 中 **不要** 开启 `generate_release_notes: true`，否则会覆盖手写笔记。
> 当前两个 workflow 均配置为仅附加附件、不覆盖 body。

## 七、确认 CI 构建

```bash
gh run list --limit 3          # 查看构建状态（Android 与 Windows 两条）
gh run watch                   # 实时跟踪（可选）
gh release view v2.4.2         # 确认附件已附加
```

CI 完成后 Release 页面应包含：

Android（**顺序不能变**，impeller 在前）：
- `shiyin-vX.Y.Z-impeller-arm64.apk`（默认渲染，老版本客户端只拿第一个 .apk 附件）
- `shiyin-vX.Y.Z-skia-arm64.apk`（老 GPU 闪屏/冻屏用户用这个）

Windows（顺序不限，应用内按文件后缀识别）：
- `shiyin-vX.Y.Z-windows-x64-portable.zip`（便携版，解压即用）
- `shiyin-vX.Y.Z-windows-x64-setup.exe`（Inno 安装版）

> 附件命名是应用内更新的识别约定，**必须严格遵守**：
> Android 靠 `-{flavor}-arm64.apk` 选渲染器包，Windows 靠
> `-portable.zip` / `-setup.exe` 后缀选形态包。zip 内文件在压缩包根目录，
> 便携版用户"解压覆盖旧目录"即可完成更新。

## 八、Windows 分发形态说明

双轨分发，数据均为"伪便携"（数据存 `%APPDATA%`，与 exe 目录无关）：

| 形态 | 来源 | 应用内更新方式 |
|---|---|---|
| 便携版 | `portable.zip` 解压任意目录 | 弹窗提示 → 跳浏览器下载新 zip → 用户解压覆盖旧目录 |
| 安装版 | `setup.exe`（装到 `%LocalAppData%\ShiyinMusic`，免 UAC） | 弹窗 → 应用内下载 setup.exe（进度+取消，另保留"浏览器下载"入口）→ 退出并拉起安装向导 |

- **形态判定**：Inno 安装时把 `installer/installed_by_inno.flag` 写进安装目录；
  应用检查 exe 同目录有无该文件（`AppUpdateService.isWindowsInstalledBuild`）。
  该文件**绝不能**打进 portable.zip（否则便携版被误判为安装版）。
- **安装包要点**（`installer/shiyin.iss`）：固定 `AppId`、
  `DefaultDirName={localappdata}\ShiyinMusic` + `PrivilegesRequired=lowest`（免 UAC）、
  `CloseApplications=yes`（安装时提示关闭运行中的时音）、卸载不清理用户数据。
- CI 中 zip 与 setup.exe 共用同一份暂存负载，分发 exe 名统一为
  `ShiyinMusic.exe`（构建产物 `kgka_music_hl.exe` 在打包阶段改名）。

## 九、检查更新的多级容灾（403 规避）

应用内检查更新按以下顺序探测，任一级拿到版本即返回（对齐 handwrite-sim 的
updater 策略，规避 api.github.com 未鉴权 60 次/时/IP 的 403 风控）：

1. **GitHub REST API** `api.github.com/…/releases/latest`（信息最全；404 = 无发布）
2. **Releases Atom 订阅源** `github.com/…/releases.atom` 取版本与正文 +
   **expanded_assets 资产页** `github.com/…/releases/expanded_assets/{tag}` 取附件直链
   （都在 github.com 域，不占 API 频次）
3. **/releases/latest 网页 302 重定向**探测最新 tag + expanded_assets 补直链

三级全部失败时：若见过 403/429 提示"检查频繁触发 GitHub 限流，请稍后再试"，
否则提示请求失败；自动检查静默，手动检查 Toast。

## 十、验证

Android：
- 在设备上安装对应变体 APK，确认「关于」页版本号正确且渲染引擎显示正确
- 点击「检查更新」，应提示"当前已是最新版本"
- 用旧版本 APK 点击「检查更新」，应弹出新版本更新弹窗

Windows：
- 便携包：解压运行，关于页能查出新版；点「去下载」正确打开 zip 直链；
  手动把新版 zip 解压覆盖旧目录后版本号更新
- 安装版：setup.exe 安装到 `%LocalAppData%\ShiyinMusic` 全程无 UAC；
  应用内下载 setup.exe 显示进度；「退出并安装」后旧进程退出、向导拉起，
  装完版本号更新且安装目录存在 `installed_by_inno.flag`
- 断网/限流：手动检查有 Toast 提示，启动自动检查不打扰

---

## 常见问题

### 检查更新提示"已是最新版本"但实际有新版本

- 确认 GitHub API 返回正确：`curl -H "User-Agent: ShiYin-App" https://api.github.com/repos/bamboostrip/shiyin-music/releases/latest`
- 确认 `AppConfig.appVersion` 与当前安装版本一致
- 确认 Release 不是 draft / prerelease（`/releases/latest` 不返回这两类）
- 确认附件命名符合约定（Windows 找不到 `-setup.exe`/`-portable.zip`
  后缀时弹窗会退化为"打开发布页"）

### 检查更新提示限流 / 403

- API 被风控时会自动走 Atom 订阅源与网页重定向两级容灾（见第九节），
  全部失败才报错；一般等待即可恢复
- 手动复现：`curl -H "User-Agent: x" https://api.github.com/rate_limit` 查看余量

### 为什么暂时没有 Linux / macOS 包

- **Linux**：`linux/CMakeLists.txt` 尚未集成 Rust `kugou_engine` 构建
  （编出的应用缺原生库，搜索等核心功能不可用）；且 `just_audio` 在 Linux
  无平台实现（无法播放）。前置工作：Linux 端 Rust 集成 + Linux 音频方案选型。
- **macOS**：`Runner.xcodeproj` 缺 Rust 库链接配置；音频可用（just_audio darwin）
  但盲改工程无法在 Windows 上验证。前置工作：Xcode 添加 libkugou_engine
  构建阶段 + macOS 实机验证。
- 两者就绪后再在 CI 矩阵中加入对应平台（附件命名沿用
  `shiyin-vX.Y.Z-{platform}-{arch}-…` 约定）。

### 需要撤回已发布的版本

```bash
gh release delete v2.4.2 --yes        # 删除 Release（含附件）
git push origin :refs/tags/v2.4.2     # 删除远程 tag
git tag -d v2.4.2                     # 删除本地 tag
# 修复后重新走发版流程
```
