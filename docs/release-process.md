# 时音 发版流程

> 适用仓库：`bamboostrip/shiyin-music`
> CI 工作流：
> - `.github/workflows/build-android.yml`（打 `v*` tag 自动构建 skia/impeller 双变体 arm64 APK 并按固定顺序附加到 Release）
> - `.github/workflows/build-windows.yml`（打 `v*` tag 自动构建 Windows 便携包 + 安装包并附加到 Release）
> - `.github/workflows/build-linux.yml`（打 `v*` tag 自动构建 Linux 便携包 + deb 包并附加到 Release）

---

## 一、发版前检查

1. 确认所有要发布的修改已合并到 `main`
2. 确认 CI 在 `main` 上最近一次构建通过（如有）
3. 确认 Release notes 首行「适用平台」标记与实际改动影响的平台一致
   （见「版本适用平台标记」一节）

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
| `pubspec.yaml` | `version: x.y.z+code` | `2.5.1+2005001` |
| `lib/config/app_config.dart` | `appVersion` | `'2.5.1'` |
| `lib/config/app_config.dart` | `appVersionCode` | `'2005001'` |

> ⚠️ **必须在打 tag 之前完成版本号升级**，否则 CI 打出的包内部版本号是旧的，
> 会导致"关于"页显示错误版本、检查更新逻辑异常。

版本号规则：
- `versionName`：语义化版本 `major.minor.patch`
- `versionCode`：`major * 1000000 + minor * 1000 + patch`（如 `2.5.1` → `2005001`，pubspec 写作 `2.5.1+2005001`）
- 约束：`minor` 与 `patch` 须 `< 1000`（各占 3 位），否则高位进位破坏单调性

## 四、更新更新日志

编辑 `update.md`，在顶部添加新版本条目，格式参考已有版本：

```markdown
## v2.4.2

- 修复 xxx 问题
- 新增 xxx 功能
- 优化 xxx 体验
```

## 版本适用平台标记（v3.0.2 起生效）

发版永远是**全平台单 Release**（`v*` tag 三平台 CI 全建、附件全家桶、版本号全局统一）。
「适用平台」标记只是 Release notes 首部的一行元信息（人可读 + 机器可读），用于
**新版客户端**按平台过滤更新提示；它不改变任何发版/附件流程。

### 格式规范

Release notes 首部写一行 blockquote（GitHub 网页上渲染为引用块，直观可读）：

```markdown
> 适用平台：全平台
```

或按实际影响的平台写，如：

```markdown
> 适用平台：Windows、Linux
> 适用平台：Android
```

**省略标记 = 全平台**（历史 Release 的兜底口径，不写也不会出错）。

### 词表与同义词

| 写法 | 含义 |
|------|------|
| `全平台` / `all` | 全平台 |
| `Windows` / `win` | Windows |
| `Linux` | Linux |
| `PC` / `桌面` / `桌面端` | Windows + Linux |
| `Android` / `安卓` / `移动端` / `手机` | Android |

词切分支持 `、` `，` `,` `/` 与空格（如 `Windows、Android`）；大小写不敏感。
未知词忽略；整行全是未知词时按全平台处理（宁多提示不漏提示）。

> ⚠️ **未来新增端（TV/手表等）时必须同步两处**：
> 1. 客户端 `lib/models/app_version.dart` 的 `parseApplicablePlatforms` 词表
> 2. 本文档的词表

### 客户端行为

- **新版客户端**（v3.0.2 起）检查更新时只对"影响本平台的版本"弹提示，且是
  **跨版本累积判断**：例如手机停在 3.0.1，之后 3.0.2/3.0.3 仅 PC——手机不弹
  提示；3.0.4 含移动端修复——手机一次提示升到 3.0.4（弹窗 changelog 拼接
  期间影响本平台的版本说明）。
- **老客户端不受任何影响**：每个 Release 永远含全平台附件，老客户端不解析
  标记，照常提示并更新。

### 保守边界

L1（API 通道）取最近 30 个、L2（Atom 通道）取最近约 10 个 Release 做判断。
当这批版本**全部**与本平台无关、且页内看不到"≤当前版本"的边界时，客户端
保守起见仍提示最新版——连续 30/10 个无关版本才会触发，宁可多提示不漏提示。

### 维护者警示：不要改成"按端拆 Release"

latest 必须永远是全家桶，**不能**把 Android/Windows/Linux 拆成多个 Release：

- **新用户/被推荐者只看 latest**：拆分后 latest 可能恰好缺其平台的附件，
  "下载更新"直接失败；
- **老客户端只认 latest**：老版本不解析「适用平台」标记，永远从 latest 拿
  本平台附件——拆分后老客户端要么拿到缺附件的 Release，要么被引导去错误
  平台的 Release；
- **标签爆炸**：三平台 × 多形态（apk 双变体/zip/exe/deb/tar.gz）拆分后
  tag 与 Release 数量成倍增长，版本号无法全局统一，回滚与 compare 链接
  全部失效。

"按平台过滤提示"永远只通过 notes 首部的标记行实现，不通过拆分 Release 实现。

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
> 适用平台：全平台

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

> 首行「适用平台」按实际改动影响的平台修改（如 `> 适用平台：Windows、Linux`），
> 规范见「版本适用平台标记」一节；不写则按全平台处理。

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
- `shiyin-vX.Y.Z-impeller-arm64.apk.sha256`（完整性 sidecar）
- `shiyin-vX.Y.Z-skia-arm64.apk`（老 GPU 闪屏/冻屏用户用这个）
- `shiyin-vX.Y.Z-skia-arm64.apk.sha256`

Windows（顺序不限，应用内按文件后缀识别）：
- `shiyin-vX.Y.Z-windows-x64-portable.zip`（便携版，解压即用）
- `shiyin-vX.Y.Z-windows-x64-portable.zip.sha256`
- `shiyin-vX.Y.Z-windows-x64-setup.exe`（Inno 安装版）
- `shiyin-vX.Y.Z-windows-x64-setup.exe.sha256`

Linux（顺序不限）：
- `shiyin-vX.Y.Z-linux-x64-portable.tar.gz`（便携版）
- `shiyin-vX.Y.Z-linux-x64-portable.tar.gz.sha256`
- `shiyin-vX.Y.Z-linux-x64.deb`（deb 安装包，Ubuntu 22.04+/Debian 12+）
- `shiyin-vX.Y.Z-linux-x64.deb.sha256`

> **sha256 sidecar**：CI 为每个附件生成同名 `.sha256` 文件（sha256sum
> 文本格式）。应用内更新（Windows 安装版的 setup.exe 下载）完成后拉取
> 同 URL 的 `.sha256` 比对，不一致即删包报错，杜绝截断/损坏/被替换的
> 安装包落地执行；手动下载的用户可 `sha256sum -c` 自行核对。每产物独立
> sidecar 而非单一汇总清单，是为了三条流水线并发上传同一 Release
> 互不冲突。

> 附件命名是应用内更新的识别约定，**必须严格遵守**：
> Android 靠 `-{flavor}-arm64.apk` 选渲染器包，Windows 靠
> `-portable.zip` / `-setup.exe` 后缀选形态包，Linux 靠 `.deb` /
> `-portable.tar.gz` 选形态包。zip 内文件在压缩包根目录，
> 便携版用户"解压覆盖旧目录"即可完成更新。

## 八、Windows 分发形态说明

双轨分发，数据均为"伪便携"（数据存 `%APPDATA%`，与 exe 目录无关）：

| 形态 | 来源 | 应用内更新方式 |
|---|---|---|
| 便携版 | `portable.zip` 解压任意目录 | 弹窗提示 → 跳浏览器下载新 zip → 用户解压覆盖旧目录 |
| 安装版 | `setup.exe`（装到 `%LocalAppData%\ShiYinMusic`，免 UAC） | 弹窗 → 应用内下载 setup.exe（进度+取消，另保留"浏览器下载"入口）→ 退出并拉起安装向导 |

- **形态判定**：Inno 安装时把 `installer/installed_by_inno.flag` 写进安装目录；
  应用检查 exe 同目录有无该文件（`AppUpdateService.isWindowsInstalledBuild`）。
  该文件**绝不能**打进 portable.zip（否则便携版被误判为安装版）。
- **安装包要点**（`installer/shiyin.iss`）：固定 `AppId`、
  `DefaultDirName={localappdata}\ShiYinMusic` + `PrivilegesRequired=lowest`（免 UAC）、
  `CloseApplications=yes`（安装时提示关闭运行中的时音）、卸载不清理用户数据。
- CI 中 zip 与 setup.exe 共用同一份暂存负载；分发 exe 名 `ShiYinMusic.exe`
  由 `windows/CMakeLists.txt` 的 `BINARY_NAME` 直接产出（无需打包阶段改名）。

## 九、检查更新的多级容灾（403 规避）

应用内检查更新按以下顺序探测，任一级拿到确定结果（有更新 / 确定无更新）即返回
（对齐 handwrite-sim 的 updater 策略，规避 api.github.com 未鉴权 60 次/时/IP
的 403 风控）；L1/L2 均做「适用平台」过滤（见「版本适用平台标记」一节）：

1. **GitHub REST API** `api.github.com/…/releases?per_page=30` 列表接口
   （信息最全；取最近 30 个 Release 做平台相关性选版，空列表 = 无发布）
2. **Releases Atom 订阅源** `github.com/…/releases.atom` 取版本与正文 +
   **expanded_assets 资产页** `github.com/…/releases/expanded_assets/{tag}` 取附件直链
   （都在 github.com 域，不占 API 频次；最近约 10 条，同样做平台选版）
3. **/releases/latest 网页 302 重定向**探测最新 tag + expanded_assets 补直链
   （拿不到 notes 正文，不做平台过滤，由客户端 semver 比较兜底）

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
- 安装版：setup.exe 安装到 `%LocalAppData%\ShiYinMusic` 全程无 UAC；
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

### GitHub 上明明有新版本，手机端却提示"已是最新"

- **这是设计行为**：该版本仅含 PC 端改动（Release notes 首部的「适用平台」
  标记不含 Android），带平台过滤的新客户端（v3.0.2 起）不会对无关平台弹
  提示；老客户端不解析标记，会照常提示更新。
- 可打开该 Release 页面，对照 notes 首部「适用平台」标记确认。

### 检查更新提示限流 / 403

- API 被风控时会自动走 Atom 订阅源与网页重定向两级容灾（见第九节），
  全部失败才报错；一般等待即可恢复
- 手动复现：`curl -H "User-Agent: x" https://api.github.com/rate_limit` 查看余量

### Linux 包（build-linux.yml）

- **形态**：`shiyin-<tag>-linux-x64-portable.tar.gz`（解压即用）+
  `shiyin-<tag>-linux-x64.deb`（/opt/shiyin-music，带 .desktop 与图标）。
- **运行期依赖**：音频后端是 media_kit(libmpv)——deb 经
  `Depends: libmpv2 | libmpv1` 自动安装（Ubuntu 24.04/Debian 12 装前者，
  Ubuntu 22.04 只有 libmpv1；media_kit 按 libmpv.so → libmpv.so.2 →
  libmpv.so.1 顺序探测，两个 soname 均可用）；便携包需用户自行安装
  `libmpv2`（22.04 为 `libmpv1`）与 `libayatana-appindicator3-1`
  （包内 README-LINUX.txt 有说明）。
- **实现要点**：`linux/CMakeLists.txt` 的 `rust_engine_build` 目标在构建期
  `cargo build` 并把 `libkugou_engine.so` 安装进 `bundle/lib`（frb 经
  RPATH `$ORIGIN/lib` 加载）；just_audio 的 Linux 后端由
  `just_audio_media_kit` 提供，`main.dart` 在 `Platform.isLinux` 分支注册，
  Windows 仍走 `just_audio_windows`（windows 侧 generated_plugins 不受影响）。
- **runner 注意**：`build-linux.yml` 用 `ubuntu-22.04`（glibc 2.35 基线，
  覆盖 22.04/24.04 双 LTS）。官方镜像 2026-09-17 起弃用告警、2027-04-17 移除
  （actions/runner-images#14254），届时改 `runs-on: ubuntu-24.04`，但 glibc
  基线将升至 2.39（22.04 用户无法运行），需在 Release 说明中注明。
- 本地验证可在 WSL2 内执行 `scripts/build_linux_wsl.sh`（自动引导
  ninja/rustup/Flutter SDK 与用户态 appindicator staging，无需 sudo）。

### 为什么暂时没有 macOS 包

- **macOS**：`Runner.xcodeproj` 缺 Rust 库链接配置；音频可用（just_audio darwin）
  但盲改工程无法在 Windows 上验证。前置工作：Xcode 添加 libkugou_engine
  构建阶段 + macOS 实机验证。就绪后在 CI 矩阵中加入
  （附件命名沿用 `shiyin-vX.Y.Z-{platform}-{arch}-…` 约定）。

### 需要撤回已发布的版本

```bash
gh release delete v2.4.2 --yes        # 删除 Release（含附件）
git push origin :refs/tags/v2.4.2     # 删除远程 tag
git tag -d v2.4.2                     # 删除本地 tag
# 修复后重新走发版流程
```
