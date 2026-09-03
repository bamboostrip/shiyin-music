# 发版流程清单（每次发版按顺序过一遍）

> 换设备发版也以本文件为准。v2.4.8 曾漏掉第 2 步（应用内更新日志），故有此清单。

## 1. 修改版本号（两处必须同步，缺一不可）

| 文件 | 改什么 |
|---|---|
| `pubspec.yaml` | `version: X.Y.Z+N` |
| `lib/config/app_config.dart` | `appVersion = 'X.Y.Z'`、`appVersionCode = 'N'` |

versionCode 规则：`X*100 + Y*10 + Z`（如 2.4.8 → 248）。

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

- 推送 `v*` tag 触发 GitHub Action「Build Android APK (arm64)」（约 10 分钟×2 变体：cargo-ndk 编译 Rust + skia/impeller 双包）。
- 双附件按固定顺序发布：`shiyin-vX.Y.Z-impeller-arm64.apk` 在前、`shiyin-vX.Y.Z-skia-arm64.apk` 在后（顺序不能换，老版本只拿第一个）。
- 签名来自仓库 Secrets（`RELEASE_KEYSTORE_BASE64` / `RELEASE_KEYSTORE_PASSWORD`），未配置时回退 debug 签名，不可覆盖安装正式版。
- 手动 `workflow_dispatch` 也可构建，但不会创建 Release。

## 6. 创建 GitHub Release（更新内容在这一步，Action 不写正文）

Action 只负责把 APK 挂到 Release；标题和正文（应用内更新弹窗展示的就是这份 body）用 gh CLI 手动创建：

```bash
gh release create vX.Y.Z --title "时音 vX.Y.Z" --notes "<更新内容>"
```

先建 Release 也没关系，Action 之后只会往上面挂 APK，不会覆盖正文。

## 7. 验证

```bash
gh run list --limit 1            # 构建应为 success（两个 flavor job）
gh release view vX.Y.Z           # assets 里应有两个 apk：impeller 在前、skia 在后
```

## 8. 收尾（可选）

- 删除已合并的修复分支（本地与远端）。
- Action 日志若出现 actions 版本弃用警告（如 setup-java@v4），有空升级对应 action 版本。
