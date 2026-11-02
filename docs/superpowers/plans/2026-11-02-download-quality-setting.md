# 下载音质设置与无损降级 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 设置页新增「下载音质」（跟随播放音质 / 标准 128K / 高品 320K / 无损 FLAC），下载按该档位取地址并决定落盘格式；无损无源时自动降档。对应 issue #8「可以选择下载最高音质吗，保存为 flac 等格式」。

**Architecture:** 复用现有 `AudioQuality` 三档；`DownloadController` 持有「下载音质覆盖值」（null = 跟随播放音质），下载入口仍传 `player.audioQuality`，由控制器内部解析，**不改 11 处 UI 调用点**。地址解析新增「按档位降级」：仅当上一档返回空地址或 `VipRequiredException` 时降一档，网络错误不降级。实际生效档位贯穿 `DownloadEntry.quality` / 缓存 key / 文件名，天然一致。

**Tech Stack:** Flutter（Dart 3）、`shared_preferences`、`flutter_test`（controller 单测 + widget 测试）。

**Base branch:** `feat/custom-download-dir`（HEAD `110da5b`，已含 issue #10 的 Android 自定义下载目录 + 设置页「下载」分节）。实施时**不 rebase、不合并 main**；完成后由用户把整条分支合回 main。

---

## 一、交接单（给人看的 30 秒版）

| 项 | 内容 |
|---|---|
| 做什么 | 设置页加「下载音质」；下载按设置档位；无损无源自动降档；已下载列表显示音质徽标 |
| 在哪做 | 分支 `feat/custom-download-dir`，在当前 HEAD 上继续提交 |
| 不开 PR | 完成后告知用户，由用户合并 main |
| 预计工作量 | 控制器 + 设置 UI + 降级 + 徽标 + 测试，约 0.5–1 人日 |
| 关键文件 | `lib/controllers/download_controller.dart`、`lib/ui/settings/`、`lib/ui/pages/downloaded_songs_page.dart` |
| 验收 | 第 6 节验收标准全部满足；`flutter analyze` 无问题；`flutter test` 全绿（基线 1604 项） |

---

## 二、Global Constraints

- 不开 PR；直接提交进 `feat/custom-download-dir`（或从其切子分支，最终同样交回用户合并）。
- 提交信息遵循 `docs/commit-convention.md`：`type(scope): 中文首行 ≤30 字` + `- ` bullets，一事一提交。
- 不新增第三方依赖；不动桌面/车机布局骨架；**不改 Android 自定义下载目录逻辑**（本分支已实现的 `downloadDir()` 回退语义保持原样）。
- 文案/注释沿用仓库现有中文风格（解释「为什么」，不只写「做了什么」）。
- 验证命令（本机 Flutter 不在 PATH，见第 5 节环境）：
  - `flutter analyze --no-fatal-infos --no-fatal-warnings`
  - `flutter test`（全量；本分支基线 1604 项全绿）
- **不要跑 `dart format`**：本机 Dart 3.13 的新版 formatter（tall style）会把仓库里大量旧格式代码重排，产生无关 diff；只保持手写风格与周围代码一致。

---

## 三、现状代码地图（实现前必读）

### 3.1 音质档位与播放侧

| 位置 | 说明 |
|---|---|
| `lib/models/song.dart:3` | `enum AudioQuality { standard('128'), high('320'), lossless('flac') }`，带 `label`/`badge`（128K/320K/FLAC） |
| `lib/models/song.dart:875` | `PlayUrl` 只有 `url/hash/privStatus`，**不带真实格式**（后续扩展名判定见 6.2 已知限制） |
| `lib/controllers/player_controller.dart:673` | `AudioQuality audioQuality = AudioQuality.standard;`（全局播放音质） |
| `lib/controllers/player_controller.settings.dart:48` | `setAudioQuality()` 持久化到 prefs（`settings.audio_quality` 一类键），并可按需重载当前歌曲 |
| `lib/ui/pages/settings_page.dart:304` | 设置 → 播放 → 「默认音质」，与新「下载音质」是两件事 |

### 3.2 下载链路

| 位置 | 说明 |
|---|---|
| `lib/controllers/download_controller.dart:101` | `DownloadController extends ChangeNotifier`，构造参数 `(DownloadService, MusicApi)` |
| `:107-109` | prefs 键常量区（`_downloadsIndexKey` / `_playCacheIndexKey` / `_playCacheLimitKey`） |
| `:171` | `initialize()`：读 prefs → 载入索引 → 对账 → 清理播放缓存；**新设置在这里加载** |
| `:459` | `download(Song, AudioQuality quality)`：查重 → 写 downloading 条目 → `_api.songUrl(quality)` → `_transfer` |
| `:508` | `enqueueBatch(List<Song>, AudioQuality quality)`：批量，4 路并发解析地址后复用 `_transfer` |
| `:626` | `_transfer(Song, AudioQuality, String url)`：最终按 quality 生成缓存 key / 文件名 |
| `lib/services/music_api_song.dart:50` | `songUrl()` 把 `quality.apiValue` 透传 rust `/song/url`；`:67-69` 空地址且需 VIP 时抛 `VipRequiredException` |
| `lib/services/download_service.dart` | `fileNameFor()`：`lossless → .flac`，其余 `.mp3`；ID3 标签只写 mp3（FLAC 不写，属已知限制） |
| `lib/controllers/download_controller.dart:19` | `BatchDownloadResult(enqueued, skipped, failed)` |

**下载入口调用点（全部传 `player.audioQuality`，除重试用 `entry.quality`）：**

- `lib/ui/desktop/desktop_player_bar.dart:892`
- `lib/ui/pages/artist_detail_page.dart:382`
- `lib/ui/pages/cloud_drive_page.dart:488-491`
- `lib/ui/pages/downloaded_songs_page.dart:720`（失败重试，传 `entry.quality`，**必须绕过新设置**）
- `lib/ui/pages/playback_history_page.dart:265`
- `lib/ui/pages/playlist_detail_page.dart:1353`、`:3488`（多选/批量入口 → `enqueueBatch`）
- `lib/ui/pages/rank_page.dart:1251`、`:1880`
- `lib/ui/pages/search_song_results.dart:160`
- `lib/ui/player/poster_player.dart:317`
- `lib/ui/widgets/home_song_row.dart:90`

### 3.3 设置页与列表

| 位置 | 说明 |
|---|---|
| `lib/ui/settings/download_settings_section.dart:16` | 本分支新增的「下载」分节，目前只挂 `DownloadLocationSettings` |
| `lib/ui/pages/settings_page.dart:35-45` | 已有可空字段 `DownloadController? downloads;` |
| `lib/ui/pages/settings_page.dart:278` | 挂载处：`const DownloadSettingsSection()` → 需要改为传入 `downloads` / `player` |
| `lib/ui/pages/downloaded_songs_page.dart:461` | 移动端已下载行 `_DownloadedSongRow`（`AppSongRow` + `trailing` 菜单按钮） |
| `lib/ui/pages/downloaded_songs_page.dart:720` | 失败行「重新下载」 |
| `lib/ui/widgets/app_song_row.dart:16` | 通用歌曲行构造：`subtitle` / `trailing` 可扩展 |
| `lib/ui/widgets/desktop_song_table_row.dart:193` | 桌面表格行；`:817` 现有 `_buildQualityBadge()` 是按标题猜的（Hi-Res/SQ/VIP），**不是下载档位** |

---

## 四、产品与技术决策（已定，实施时不要再问）

1. **入口**：设置 → 下载 → 「下载音质」，紧跟「下载位置」下方，三端（手机/车机/桌面）同一分节。
2. **选项**：`跟随播放音质`（默认）/ `标准音质 128K` / `高品音质 320K` / `无损音质 FLAC`。
3. **默认行为不变**：默认「跟随播放音质」等同现状，老用户升级后无感。
4. **持久化**：`settings.download_quality`，值 = `follow`（或缺失）| `AudioQuality.apiValue`（`128` / `320` / `flac`）；脏值按 `follow` 处理。
5. **解析位置**：在 `DownloadController` 内部解析（`_downloadQualityOverride ?? playbackQuality`），UI 调用点继续传 `player.audioQuality`，避免大面积改动。
6. **重试语义**：失败重试必须按条目记录的原档位重下（不受新设置影响），通过 `respectQualityOverride: false` 实现。
7. **降级策略**：仅在「解析到空地址」或 `VipRequiredException` 时按 `flac → 320 → 128` 降一档重试；**网络/超时不降级**（保持现有错误语义，避免把弱网伪装成没音源）。
8. **降级后**：条目/文件按实际档位记录（`entry.quality` = 实际档位），文件名扩展名随之正确；不弹 Toast（批量会刷屏），只 `debugPrint` 日志。
9. **已下载去重语义不变**：同歌已下载则跳过，不会因调高设置自动重下（见 6.2 非目标）。
10. **不做每次下载弹窗选音质**（后续可加；issue #8 用设置项即可满足）。

---

## 五、环境与构建（本机，交接必读）

- Flutter 3.44.8：`C:\develop\flutter\flutter\bin\flutter.bat`（**不在 PATH**，用绝对路径或临时加 PATH）
- JDK：`C:\develop\jdk`（Temurin 21）；Android SDK：`C:\develop\Android\SDK`；NDK：`28.2.13676358`
- Rust：`cargo-ndk 4.1.2` 已装，`aarch64-linux-android` target 已装
- APK 构建（不用仓库脚本也能打，脚本依赖 PATH 里的 flutter）：
  ```powershell
  $env:JAVA_HOME='C:\develop\jdk'
  $env:ANDROID_HOME='C:\develop\Android\SDK'
  $env:ANDROID_NDK_HOME='C:\develop\Android\SDK\ndk\28.2.13676358'
  $env:Path="C:\develop\flutter\flutter\bin;C:\develop\jdk\bin;$env:Path"
  flutter build apk --release --target-platform android-arm64 --flavor impeller `
    --dart-define=APP_RENDERER=impeller --dart-define=APP_ABI=arm64
  ```
  - 覆盖安装要求 versionCode 大于已装包：本分支测试包已用过 `3003001` / `3003010`，新包从 `--build-number=3003011` 起临时提高，**不要写回 pubspec**（正式发版仍按 `docs/release-process.md` 改版本）。
  - `android/key.properties` 存在 → release 用正式签名；不要删除/提交该文件。
- 网络坑：maven central / plugins.gradle.org 偶发 TLS 握手失败（表现为 Gradle "Remote host terminated the handshake"）。先重试；连续失败时临时在 `~/.gradle/init.d/` 放镜像脚本（**构建后删除、绝不提交**）：
  ```groovy
  def addMirrors = { repos ->
      repos.maven { url 'https://maven.aliyun.com/repository/public' }
      repos.maven { url 'https://maven.aliyun.com/repository/google' }
      repos.maven { url 'https://maven.aliyun.com/repository/gradle-plugin' }
  }
  beforeSettings { s ->
      addMirrors(s.pluginManagement.repositories)
      // flutter_tools/gradle 是独立构建且用 PREFER_SETTINGS，不能给它加 settings 级仓库
      if (!s.settingsDir.absolutePath.replace('\\','/').contains('/flutter_tools/')) {
          addMirrors(s.dependencyResolutionManagement.repositories)
      }
  }
  gradle.beforeProject { p -> addMirrors(p.buildscript.repositories) }
  ```
- CI：`.github/workflows/flutter-ci.yml` 只在 push main / PR / `workflow_dispatch` 触发；**分支推送不会自动跑**，所以本地必须自测全绿。

---

## 六、任务分解

### Task 0: 基线确认

**Files:** 无（只验证）

- [ ] `git status` 干净；`git log -1` 为 `110da5b`（或更晚的本分支提交）。
- [ ] `flutter pub get` 成功。
- [ ] `flutter analyze --no-fatal-infos --no-fatal-warnings` 无问题。
- [ ] `flutter test` 全绿（记录总数，基线 1604）。
- [ ] 如失败：先停下排查环境，不要带着红基线开工。

---

### Task 1: 设置值存取 + 生效档位解析（控制器层）

**Files:**
- Modify: `lib/controllers/download_controller.dart`
- Test: `test/controllers/download_quality_test.dart`（新建）

**Interfaces（对后续任务/UI 的契约）：**
- `static const String downloadQualityKey = 'settings.download_quality';`
- `AudioQuality? get downloadQualityOverride;`（null = 跟随播放音质）
- `AudioQuality resolveDownloadQuality(AudioQuality playbackQuality);`
- `Future<void> setDownloadQuality(AudioQuality? quality);`（null = 跟随；内部 `notifyListeners`）

- [ ] **Step 1: 写失败测试**

新建 `test/controllers/download_quality_test.dart`，测试替身可参考 `test/controllers/download_hash_normalization_test.dart:468/572`（`_FakeDownloadService implements DownloadService` + `_FakeApi implements MusicApi`，tmp 目录驱动）。先写以下用例（此时应失败/编译失败）：

```dart
test('默认（未设置）跟随播放音质', () async {
  final controller = DownloadController(_FakeDownloadService(...), _FakeApi());
  await controller.initialize();
  expect(controller.downloadQualityOverride, isNull);
  expect(controller.resolveDownloadQuality(AudioQuality.lossless),
      AudioQuality.lossless);
});

test('设置覆盖值后不再跟随播放音质', () async {
  await controller.setDownloadQuality(AudioQuality.high);
  expect(controller.resolveDownloadQuality(AudioQuality.lossless),
      AudioQuality.high);
});

test('设置持久化：新 controller initialize 后仍生效', () async {
  await controller.setDownloadQuality(AudioQuality.lossless);
  final another = DownloadController(_FakeDownloadService(...), _FakeApi());
  await another.initialize();
  expect(another.downloadQualityOverride, AudioQuality.lossless);
});

test('清除设置（null）恢复跟随', () async { ... });
test('脏值（如 "abc" / "follow"）按跟随处理', () async { ... });
```

- [ ] **Step 2: 实现**

`lib/controllers/download_controller.dart`：

1. 键常量（放在 `_playCacheLimitKey` 旁）：
```dart
  /// 下载音质覆盖值：缺失或 'follow' = 跟随播放音质。
  static const downloadQualityKey = 'settings.download_quality';
```
2. 字段与 getter（放在 `_playCacheLimit` 附近）：
```dart
  AudioQuality? _downloadQualityOverride;
  AudioQuality? get downloadQualityOverride => _downloadQualityOverride;
```
3. `initialize()` 中读 prefs（在 `_playCacheLimit` 之后）：
```dart
    _downloadQualityOverride = _parseDownloadQuality(
      prefs.getString(downloadQualityKey),
    );
```
4. 解析 + 写入 API：
```dart
  /// 脏值一律按「跟随播放音质」处理，避免旧/手改数据把下载锁死在某档。
  static AudioQuality? _parseDownloadQuality(String? raw) {
    if (raw == null || raw.isEmpty || raw == 'follow') return null;
    for (final quality in AudioQuality.values) {
      if (quality.apiValue == raw) return quality;
    }
    return null;
  }

  /// 生效的下载音质：独立设置优先，未设置时跟随 [playbackQuality]。
  AudioQuality resolveDownloadQuality(AudioQuality playbackQuality) =>
      _downloadQualityOverride ?? playbackQuality;

  /// 写入 / 清除下载音质设置（null = 跟随播放音质）。
  Future<void> setDownloadQuality(AudioQuality? quality) async {
    if (_downloadQualityOverride == quality) return;
    _downloadQualityOverride = quality;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (quality == null) {
      await prefs.remove(downloadQualityKey);
    } else {
      await prefs.setString(downloadQualityKey, quality.apiValue);
    }
  }
```

- [ ] **Step 3: 验证**
  - `flutter test test/controllers/download_quality_test.dart`
  - `flutter analyze`

---

### Task 2: 下载入口接入覆盖值 + 重试旁路

**Files:**
- Modify: `lib/controllers/download_controller.dart`
- Modify: `lib/ui/pages/downloaded_songs_page.dart:720`

**Interfaces:**
- `Future<void> download(Song song, AudioQuality playbackQuality, {bool respectQualityOverride = true})`
- `Future<BatchDownloadResult> enqueueBatch(List<Song> songs, AudioQuality playbackQuality)`（保持签名，内部解析）

- [ ] **Step 1: 改 `download()`**

在方法体最前面解析并替换原 quality 使用：

```dart
  Future<void> download(
    Song song,
    AudioQuality playbackQuality, {
    /// 失败重试传 false：按条目原档位重下，不跟随新设置。
    bool respectQualityOverride = true,
  }) async {
    final quality = respectQualityOverride
        ? resolveDownloadQuality(playbackQuality)
        : playbackQuality;
    // ...以下沿用现有逻辑，quality 用解析后的值
  }
```
注意：`_downloads[downloadKey] = DownloadEntry(... quality: quality ...)`、`cacheKeyFor(song, quality)`、`_api.songUrl(quality: quality)`、`_transfer(song, quality, ...)` 全部用解析后的 `quality`。

- [ ] **Step 2: 改 `enqueueBatch()`**

方法体开头：
```dart
    final quality = resolveDownloadQuality(playbackQuality);
```
其余不变（批量没有「同曲重试」语义，恒尊重设置）。

- [ ] **Step 3: 重试旁路**

`lib/ui/pages/downloaded_songs_page.dart:720` 改为：
```dart
onPressed: () => downloads.download(
  song,
  entry.quality,
  respectQualityOverride: false,
),
```

- [ ] **Step 4: 测试**
  - 在 Task 1 的测试文件追加：设置 `high` 时 `download(song, AudioQuality.lossless)` 请求的 `quality` 为 `320`（断言 fake API 收到的 apiValue）；
  - `respectQualityOverride: false` 时请求仍为 `flac`；
  - 批量下载按设置解析。
  - 跑 `flutter test test/controllers/download_quality_test.dart`。

---

### Task 3: 无源自动降档

**Files:**
- Modify: `lib/controllers/download_controller.dart`

**Interfaces:**
- `Future<({AudioQuality quality, String url})> _resolveDownloadUrl(Song song, AudioQuality requested)`
- 单曲 `download()` 与批量 `enqueueBatch()` 都改用它。

- [ ] **Step 1: 写失败测试**（追加到 `test/controllers/download_quality_test.dart`，fake API 可配置每档返回空/抛 VIP）

```dart
test('无损返回 VIP 异常时降级到 320 并记录实际档位', () async { ... });
test('无损地址为空时降级；320 也为空则降到 128', () async { ... });
test('网络异常不降级，直接失败（不伪装成没音源）', () async { ... });
test('设置 320 且 320 无源时降到 128', () async { ... });
```

- [ ] **Step 2: 实现**

```dart
  /// 按档位降级解析下载地址。
  ///
  /// 只在「服务端明确没有该档音源」时降档（空地址 / 需要 VIP）；
  /// 网络异常、超时等直接抛出，由调用方按原错误写失败条目——否则弱网
  /// 会被伪装成「这首歌只有低音质」。
  Future<({AudioQuality quality, String url})> _resolveDownloadUrl(
    Song song,
    AudioQuality requested,
  ) async {
    Object? lastError;
    for (final quality in _downloadQualityFallbackChain(requested)) {
      try {
        final playUrl = await _api.songUrl(song, quality: quality);
        if (playUrl.url.isNotEmpty) {
          if (quality != requested) {
            debugPrint(
              '[download] 音质降级 ${requested.badge} → ${quality.badge}: '
              '${song.hash}',
            );
          }
          return (quality: quality, url: playUrl.url);
        }
        lastError = Exception('这首歌暂时没有可播放地址');
      } on VipRequiredException catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? Exception('这首歌暂时没有可播放地址');
  }

  static List<AudioQuality> _downloadQualityFallbackChain(
    AudioQuality quality,
  ) =>
      switch (quality) {
        AudioQuality.lossless => const [
            AudioQuality.lossless,
            AudioQuality.high,
            AudioQuality.standard,
          ],
        AudioQuality.high => const [AudioQuality.high, AudioQuality.standard],
        AudioQuality.standard => const [AudioQuality.standard],
      };
```
注意：**不要**把普通 `Exception`/网络错误纳入 catch 后继续循环（只 catch `VipRequiredException`；空地址走自然降级）。`_api.songUrl` 的网络异常应原样上抛。

- [ ] **Step 3: 接入两处下载**

`download()`：
```dart
    try {
      final source = await _resolveDownloadUrl(song, quality);
      await _transfer(song, source.quality, source.url);
    } catch (error) { /* 现有失败条目逻辑 */ }
```
`enqueueBatch()` 同样替换「解析 + 判空」两步为 `_resolveDownloadUrl`，失败计数沿用现有分支。

- [ ] **Step 4: 验证**：新增用例 + `flutter test test/controllers/download_quality_test.dart`。

---

### Task 4: 设置页「下载音质」

**Files:**
- Modify: `lib/ui/settings/download_settings_section.dart`
- New: `lib/ui/settings/download_quality_settings.dart`
- Modify: `lib/ui/pages/settings_page.dart:278`
- Test: `test/ui/settings/download_quality_test.dart`（新建）

**Interfaces:**
- `DownloadSettingsSection({super.key, this.downloads, required this.player})`
- `DownloadQualitySettings({super.key, required this.downloads, required this.player})`

- [ ] **Step 1: 写失败 widget 测试**

参考 `test/ui/settings/cache_management_sheet_test.dart` 的 fake 写法（`_FakeDownloads extends ChangeNotifier implements DownloadController` + `noSuchMethod` 兜底）。用例：

```dart
testWidgets('默认跟随播放音质，副标题带当前档位', ...);   // 期望出现 '跟随播放音质（当前 320K）'
testWidgets('点击下载音质弹出四档选项', ...);            // 跟随/标准/高品/无损
testWidgets('选择无损后副标题变为 FLAC，并写入 controller', ...);
testWidgets('downloads 为 null 时不渲染下载音质行', ...); // SettingsPage 测试场景
```

- [ ] **Step 2: 分节改造**

`lib/ui/settings/download_settings_section.dart`（当前只有一行 `const DownloadLocationSettings()`）改为：

```dart
class DownloadSettingsSection extends StatelessWidget {
  const DownloadSettingsSection({
    super.key,
    this.downloads,
    required this.player,
  });

  final DownloadController? downloads;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '下载'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            const DownloadLocationSettings(),
            if (downloads != null) ...[
              SettingsDivider(),
              DownloadQualitySettings(downloads: downloads!, player: player),
            ],
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
```

`lib/ui/pages/settings_page.dart:278`：

```dart
const DownloadSettingsSection(downloads: downloads, player: player),
```
（`SettingsPage` 已有 `downloads` 字段与 `player` 字段，无需改外层 4 个构造点。）

- [ ] **Step 3: 新增 `download_quality_settings.dart`**

StatefulWidget；`initState` 里读 `downloads.downloadQualityOverride` 并 `addListener`（`initialize()` 在首帧后才异步加载，必须能刷新）；`dispose` 移除监听。`build` 里读 `player.audioQuality` 拼副标题。选项弹窗参考 `cache_management_sheet.dart` 的 `_selectCacheLimit`（AlertDialog + RadioListTile）。

```dart
String get _subtitle {
  final override = widget.downloads.downloadQualityOverride;
  if (override == null) {
    return '跟随播放音质（当前 ${widget.player.audioQuality.label}）';
  }
  return '${override.label}（${override.badge}）';
}
```
弹窗 4 项（`跟随播放音质` 的 value 用 null，其余用 `AudioQuality`）：

| 选项 | 说明文案 |
|---|---|
| 跟随播放音质 | 当前：{player.audioQuality.label}；播放音质变了下载也跟着变 |
| 标准音质 · 128K | 省流量，文件最小 |
| 高品音质 · 320K | 推荐；体积与音质均衡 |
| 无损音质 · FLAC | 单曲约 30–50MB；该曲无无损源时自动降级 |

选择后：
```dart
await widget.downloads.setDownloadQuality(quality); // null = 跟随
if (!mounted) return;
setState(() {}); // 或依赖 controller 监听刷新
```

- [ ] **Step 4: 验证**
  - `flutter test test/ui/settings/download_quality_test.dart`
  - `flutter test test/ui/pages/settings_desktop_gate_test.dart`（现测试构造 `SettingsPage` 不传 downloads，新行应隐藏，原断言仍需通过）

---

### Task 5: 已下载列表音质徽标（P1，建议本期一起做）

**Files:**
- New: `lib/ui/widgets/audio_quality_badge.dart`
- Modify: `lib/ui/pages/downloaded_songs_page.dart:461`（移动端行）
- Modify: `lib/ui/widgets/desktop_song_table_row.dart:193`（桌面表格行，加可选徽标参数）
- Test: `test/ui/widgets/audio_quality_badge_test.dart`

- [ ] **Step 1: 新建徽标**

小圆角描边徽标，文本用 `quality.badge`（`128K` / `320K` / `FLAC`），颜色按档位（灰/蓝/橙），尺寸与 `now_playing_badge` / `app_song_row` 的角标同级（建议 10–11px）。要求：不接收点击、不参与语义（`ExcludeSemantics`），避免影响行读屏与手势。

- [ ] **Step 2: 移动端已下载行**

`_DownloadedSongRow.build` 的 `AppSongRow(trailing: [...])` 里，在 `AppSongRowMenuButton` 前插入：
```dart
trailing: [
  AudioQualityBadge(quality: entry.quality),
  AppSongRowMenuButton(onPressed: () => _showActions(context, song)),
],
```

- [ ] **Step 3: 桌面表格行**

`DesktopSongTableRow` 增加可选参数：
```dart
/// 标题后附加的徽标（如已下载页的 128K/320K/FLAC 档位微标）；null 不占位。
final Widget? trailingBadge;
```
在标题行末尾渲染。已下载页的桌面列表（`downloaded_songs_page.dart` 的 `_buildDesktopResults`）传入 `AudioQualityBadge(quality: entry.quality)`。

- [ ] **Step 4: widget 测试 + 全量回归**

---

### Task 6: 文案、日志、更新日志与手工验证

**Files:**
- Modify: `update.md`（`## 未发布` → `### 新功能`，与 issue #10 条目并列）
- 手工验证（见第 7 节）

- [ ] `update.md` 追加一条，建议文案（可按仓库风格润色）：
  ```markdown
  - **下载音质可选**：设置 → 下载新增「下载音质」，可单独指定标准 128K / 高品 320K / 无损 FLAC（默认跟随播放音质）。选无损时下载保存为 FLAC；该曲没有无损源或需要 VIP 时自动降一档下载，并在已下载列表标注实际音质（128K / 320K / FLAC）。已下载的歌不会被自动重下，换档后删除重下即可
  ```
- [ ] `debugPrint` 统一带 `[download]` / `[设置]` 前缀（便于「设置 → 应用 → 运行日志与诊断」排查）。
- [ ] 全量 `flutter analyze` + `flutter test`。
- [ ] 构建 APK 做第 7 节真机清单。

---

## 七、测试矩阵与手工验收

### 7.1 自动化

| 层级 | 用例 |
|---|---|
| 单测 | 默认跟随；覆盖值优先；持久化/脏值；`respectQualityOverride:false`（重试）；批量解析 |
| 单测 | flac VIP 异常 → 320；flac 空 → 320 → 128；网络异常不降级；320 无源 → 128 |
| Widget | 设置项默认副标题、四档弹窗、选择后副标题更新、downloads 为 null 时隐藏 |
| Widget | 音质徽标渲染（128K/320K/FLAC） |
| 回归 | `flutter test` 全量（基线 1604 项） |

### 7.2 真机/桌面手工清单

- [ ] 默认「跟随播放音质」：播放音质切 320 → 下载得到 320 文件；切无损 → 下载得到 `.flac`。
- [ ] 设置固定 320K：播放音质为无损时，下载仍落 `.mp3` 且条目标 320K。
- [ ] 设置无损：找一首有无损源的歌 → 下载后文件为 `.flac`，系统播放器/车机能播；找一首 VIP/无无损源的歌 → 自动降级成功（日志有降级行），条目显示实际档位。
- [ ] 失败重试：在「已下载」失败列表点重新下载，请求档位与条目一致（不被新设置改写）。
- [ ] 批量下载：歌单整单加入队列，按设置档位；无损档大量下载不崩（关注存储）。
- [ ] 重启 App：设置保持；已下载列表徽标与文件一致。
- [ ] Windows / 车机：设置项显示与选择正常；桌面下载条/车机行内下载均按设置。
- [ ] Android 自定义下载目录回归：换目录后下载仍落新目录（不要动 `downloadDir()` 逻辑）。

---

## 八、验收标准（Definition of Done）

1. 设置默认「跟随播放音质」时，下载行为与改动前逐字节等价（除新增设置项外无行为变化）。
2. 设置固定档位后，单曲/批量/行内下载全部按该档位取地址、命名、记索引。
3. 无损无源/VIP 自动降档，条目标记为实际档位，日志可查；网络错误不被降级逻辑吞掉。
4. 失败重试按原档位，不受新设置影响。
5. 已下载列表（移动 + 桌面）能看到 128K/320K/FLAC 徽标。
6. `flutter analyze` 无问题；`flutter test` 全绿；APK 可安装（覆盖安装 versionCode 更大）。
7. `update.md` 有对应条目；无临时文件/调试代码混入提交。

---

## 九、已知限制 / 非目标（本期不做，避免范围膨胀）

- **不做每次下载弹窗选音质**（issue #8 用设置项即可满足；后续可加「单曲菜单 → 下载其他音质」）。
- **不写 FLAC 元数据**：ID3 仅对 mp3 生效；FLAC 的 Vorbis comment（歌名/封面）另立任务。
- **不嗅探 URL 真实格式**：`PlayUrl` 不返回格式；若请求 flac 但服务端实际给 320 源，会存成 `.flac` 的 mp3 内容（能播，扩展名不准）。若要修，先抓 3 首样本确认 URL 后缀规则再决定（属于本期外的小优化）。
- **已下载不会自动重下**：调高下载音质后，已下载的歌保持原档位；用户需删除后重下。可另立 issue「按新音质重新下载」。
- **不改 Android 自定义下载目录/对账逻辑**，不改 iOS（未分发）。
- 无损批量下载的存储预警不做硬限制（可在设置弹窗文案里提示体积）。

---

## 十、交接与合并说明

1. **分支**：`feat/custom-download-dir`（远程同名分支已存在；PR #11 已按用户要求关闭，**不要重开 PR**）。
2. 实施者直接在该分支继续提交（或从它切子分支，最终 cherry-pick/合并回该分支），保持提交粒度：控制器/降级/设置 UI/徽标/文案可各一条。
3. 完成后把「改了什么 + 测试结果 + APK 路径」告知用户；**不要自行合并 main**，由用户合并这整条分支。
4. 合并前自检：
   - `git log --oneline 110da5b..HEAD` 无 WIP/临时提交；
   - `git status` 干净，无 `~/.gradle` 镜像脚本、`build/` 产物被误加；
   - `update.md` 同时包含 issue #10 与「下载音质」两条；
   - 版本号仍为 `3.0.15+3000015`（测试包用 `--build-number` 临时提高，不改 pubspec）。
5. 发版时按 `docs/release-process.md` 统一改 `pubspec.yaml` + `lib/config/app_config.dart`，并打 tag。
