# 发版流程清单（每次发版按顺序过一遍）

> 换设备发版也以本文件为准。v2.4.8 曾漏掉第 2 步（应用内更新日志），故有此清单。

## 1. 修改版本号（两处必须同步，缺一不可）

| 文件 | 改什么 |
|---|---|
| `pubspec.yaml` | `version: X.Y.Z+N` |
| `lib/config/app_config.dart` | `appVersion = 'X.Y.Z'`、`appVersionCode = 'N'` |

versionCode 规则：`X*1000000 + Y*1000 + Z`（如 2.5.1 → 2005001，minor/patch 须 < 1000）。
旧口径 `X*100 + Y*10 + Z` 在 minor 达两位数时会进位冲突（2.10.0 与 3.0.0 同为 300），已废弃。

## 2. 更新应用内更新日志（容易忘！）

- 文件：根目录 `update.md`，在文件顶部（`# 安卓端KA-Music更新日志` 标题下）新增本版条目。
- 格式：`## vX.Y.Z` + `### 新功能` / `### 修复` 分组 + `- ` 列表，只写用户可感知的内容。
- 此文件由「关于」页读取展示（pubspec `assets` 已声明）。**发版前忘改，关于页更新日志就会停在旧版本**，且已构建的 APK 无法补上。
- 建议直接复用本版条目作为第 6 步 Release 的更新内容，两边措辞保持一致。

## 3. 提交 release commit

```
release: vX.Y.Z

版本号更新为 X.Y.Z（versionCode N）：pubspec 与 app_config 双处同步
（正文可附本版要点）
```

参考历史：`git log --oneline --grep="release:"`。

## 4. 合并并推送 main

```bash
git checkout main
git merge --ff-only <修复分支>   # 有修复分支时
git push origin main
```

## 5. 打 tag 触发自动构建

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

- 推送 `v*` tag 同时触发四条 GitHub Action 流水线：
  - 「Build Android APK (arm64)」（约 10 分钟×2 变体：cargo-ndk 编译 Rust + skia/impeller 双包）；
  - 「Build Windows Desktop」（便携 zip + Inno Setup 安装包 + .sha256 sidecar）；
  - 「Build Linux Desktop」（便携 tar.gz + deb 包 + .sha256 sidecar）；
  - 「Build iOS IPA」（macos-latest，约 15–25 分钟：aarch64-apple-ios 交叉编译 Rust 静态库 + Swift Package Manager 解析插件 + `flutter build ios --release --no-codesign`）。
- Android 双附件按固定顺序发布：`shiyin-vX.Y.Z-impeller-arm64.apk` 在前、`shiyin-vX.Y.Z-skia-arm64.apk` 在后（顺序不能换，老版本只拿第一个）。
- 签名来自仓库 Secrets（`RELEASE_KEYSTORE_BASE64` / `RELEASE_KEYSTORE_PASSWORD`），未配置时回退 debug 签名，不可覆盖安装正式版。
- 手动 `workflow_dispatch` 也可构建，但不会创建 Release。
- iOS 产物是 `shiyin-vX.Y.Z-ios-arm64-unsigned.ipa` + `.sha256`，**未签名**：非越狱设备不能直接安装，需用户自行用 AltStore / Sideloadly / ESign 重签（免费证书 7 天有效），或用 TrollStore。`--no-codesign` 出的是真机 arm64 包，模拟器装不了。它是给有设备的人侧载试用的产物，不是 App Store / TestFlight 分发。
- iOS 的 Rust 静态库由 `scripts/build_rust_ios.sh` 在 macOS 本地构建（CI 里是等价的内联命令）；静态库缺失时链接期直接报 `file not found`，不会静默产出坏包。

## 6. 创建 GitHub Release（更新内容在这一步，Action 不写正文）

四条 Action 只负责把产物挂到 Release；标题和正文（应用内更新弹窗展示的就是这份 body）用 gh CLI 手动创建。**必须建草稿**——`publish-release.yml` 在四线全绿后把草稿转正，直接建正式 Release 会让门禁判定为「已发布」而跳过（内容先对外可见，等于绕过校验）：

```bash
gh release create vX.Y.Z --draft --title "时音 vX.Y.Z" --notes "<更新内容>"
```

建草稿的时机：tag 推送之后、四条流水线跑完之前都行。Android/Windows/Linux 传附件时草稿必须已存在；iOS 更早完成构建，它的上传步骤会轮询等待草稿最多 10 分钟，所以「先推 tag 再建草稿」是安全顺序。

## 7. 验证

```bash
gh run list --limit 4            # 四条流水线（Android/Windows/Linux/iOS）均应为 success
gh release view vX.Y.Z --json isDraft,assets   # 转正后 isDraft 应为 false
gh release view vX.Y.Z           # assets 应含：Android 双 apk（impeller 在前、skia 在后，
                                 # 均带 .sha256）；Windows setup.exe + portable.zip（带
                                 # .sha256）；Linux deb + portable.tar.gz（带 .sha256）；
                                 # iOS shiyin-vX.Y.Z-ios-arm64-unsigned.ipa（带 .sha256）
```

四条全绿之前 `gh release view` 看到的 `isDraft` 应恒为 `true`；若某条失败，Release 会停在草稿，按发版文档「撤回」小节处理后重走。iOS 侧另有构建期守卫：`Verify Rust engine is linked` 步骤会检查主二进制里有没有 `frbgen_shiyin_music*` 符号，没有就失败——这比发出一个装上即「启动初始化失败」的 IPA 要好。

## 8. 收尾（可选）

- 删除已合并的修复分支（本地与远端）。
- Action 日志若出现 actions 版本弃用警告（如 setup-java@v4），有空升级对应 action 版本。
