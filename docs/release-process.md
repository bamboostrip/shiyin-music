# 时音 发版流程

> 适用仓库：`bamboostrip/shiyin-music`
> CI 工作流：`.github/workflows/build-android.yml`（打 `v*` tag 自动构建 arm64 APK 并附加到 Release）

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

## 三、升级版本号（三处必须同步）

| 文件 | 字段 | 示例 |
|------|------|------|
| `pubspec.yaml` | `version: x.y.z+code` | `2.4.2+242` |
| `lib/config/app_config.dart` | `appVersion` | `'2.4.2'` |
| `lib/config/app_config.dart` | `appVersionCode` | `'242'` |

> ⚠️ **必须在打 tag 之前完成版本号升级**，否则 CI 打出的 APK 内部版本号是旧的，
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

用 `gh` CLI 创建 Release，**先写 Release 再打 tag**，这样 CI 只附加 APK 不覆盖笔记：

```bash
# 1. 写 Release 笔记到临时文件（避免 shell 转义问题）
#    内容从 update.md 对应版本摘取，可加分类标题（Bug 修复 / 新功能 / 技术改进）

# 2. 创建 Release（自动在远程创建 tag，触发 CI）
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
> 当前 workflow 已配置为仅附加 APK、不覆盖 body。

## 七、确认 CI 构建

```bash
gh run list --limit 1          # 查看构建状态
gh run watch                   # 实时跟踪（可选）
gh release view v2.4.2         # 确认 APK 已附加
```

CI 完成后 Release 页面应包含：
- 手写 changelog
- `app-release.apk` 附件（arm64-v8a）

## 八、验证

- 在设备上安装新 APK，确认「关于」页版本号正确
- 点击「检查更新」，应提示"当前已是最新版本"
- 用旧版本 APK 点击「检查更新」，应弹出新版本更新弹窗

---

## 常见问题

### 检查更新提示"已是最新版本"但实际有新版本

- 确认 GitHub API 返回正确：`curl -H "User-Agent: ShiYin-App" https://api.github.com/repos/bamboostrip/shiyin-music/releases/latest`
- 确认 `AppConfig.appVersion` 与当前 APK 版本一致
- 确认 Release 不是 draft / prerelease（`/releases/latest` 不返回这两类）

### 需要撤回已发布的版本

```bash
gh release delete v2.4.2 --yes        # 删除 Release（含附件）
git push origin :refs/tags/v2.4.2     # 删除远程 tag
git tag -d v2.4.2                     # 删除本地 tag
# 修复后重新走发版流程
```
