# 听歌时光机（二期·上报）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 提供可选的播放记录云端上报（酷狗 `/playhistory/v1/upload_songs`）：设置开关默认关闭，开启后起播成功即上报（仅酷狗在线音源），失败静默不影响播放。

**Architecture:** 引擎暴露 `upload_play_history`（report.rs 现成 dead_code 函数）为 POST 路由；`MusicApi.uploadPlayHistory` 薄包装；`PlayerController` 持有持久化开关（参照「增加听歌时长」开关链）并在 `playSong` 成功钩子（与本地历史/统计同位）异步上报；设置页在「听歌时光机」瓦片后加 `SettingsSwitchTile`。延续一期分支 `feat/time-machine`。

**Tech Stack:** Rust（kugou_engine，无需 FRB 代码生成）/ Flutter Dart（无新依赖）/ flutter_test（手写 Fake）。

## Global Constraints

- **默认关闭**：`cloudHistoryUploadEnabled` 初始值必须是 `false`（一期风险控制的决定性条款，不得照抄 addListeningTimeEnabled 的默认 true）。
- **只报酷狗在线音源**：mixsongid 口径与评论按钮一致——`song.source == SongSource.kugou` 且 `int.tryParse(song.albumAudioId ?? song.id)` 非空；本地音乐、网易源、hash 兜底的非数字 id 一律不上报。
- **失败静默**：单次调用、catch 吞错只 debugPrint、无重试/队列/风暴；**绝不阻塞播放主链路**（unawaited）。
- 上报参数固定：每次播放 `play_count=1`、`ot` 不传（服务端取当次时间），与官方客户端"每次播放记一条"语义一致。
- 不新增 pubspec 依赖；不改 FFI 签名（不跑 codegen）。
- `flutter analyze` 零 issue、`flutter test` 全绿（一期后基线 1156 通过 + 1 跳过）、`cargo check` 通过。
- 文案全部中文；颜色 colorScheme（开关瓦片 iconColor 用计划给定硬编码色）；图标 `*_rounded`/`*_outlined`。
- 提交格式 `type(scope): 中文描述`，scope 固定 `timemachine`。
- 工作分支：`feat/time-machine`（一期 7 提交之上追加，勿切分支勿动 main）。

**既有事实（实现者无需重查）：**
- `upload_play_history` 在 `rust/src/services/report.rs:11-29`（带 `#[allow(dead_code)]`，未接路由），签名 `(client, session, mix_song_id: i64, timestamp: Option<i64>, play_count: i64)`，body 含 `op:1/ot/pc/mxid`。
- engine.rs POST 带参先例：`("POST", "/playlist/del")`（614-621 行）用 `first_str(&[&body_val], params, &[...])`；query 与 body 都会进 `params`（engine.rs:64-88）；`("GET", "/user/playhistory")` 路由在一期已加（约 704 行），`("POST", "/listen/timeadd")` 在 709 行。
- Dart 侧 `_client.post(path, query: {...})` 的 query 值会 toString 后进引擎 params（rust_api_client.dart:70-122）。
- `MusicApi.addListeningTime`（music_api_auth.dart:130-132）是不校验信封的最简 POST 先例。
- PlayerController 构造 `PlayerController(super.api, super.audioHandler)`（player_controller.dart:175），`_api` 为 MusicApi（454 行）；playSong 成功钩子在 player_controller.playback.dart:235-236（`unawaited(_historyService.record(song)); unawaited(_statsService.recordPlay(song));`）。
- 开关链参照（同文件可照抄结构）：key 常量 player_controller.dart:101（`'settings.add_listening_time_enabled'` 风格）、字段 614 行、setter `setKeepScreenOnEnabled`（settings.dart:20-28：同值早退→赋值→prefs.setBool→notifyListeners）、恢复 settings.dart:338-341（`prefs.getBool(key) ?? 字段默认`）。
- 设置瓦片：`SettingsSwitchTile(icon:, title:, value:, onChanged:, iconColor:, subtitle:)`（settings_widgets.dart:172-188）；一期已在 playback_settings_section.dart 加了「听歌时光机」SettingsTile，其后有既有 `SettingsDivider()`。
- 测试装置参照：test/controllers/play_confirm_timeout_test.dart（PlayerController(api, handler) 构造、settle() 跑 30 轮 microtask、_MockMusicApi/_RecordingAudioHandler）；test/controllers/player_precache_test.dart:152-173（Fake MusicApi 记录调用的 spy 写法）。
- 已知会受影响的存量测试：pump 设置页的两个 UI 测试用 Fake player 覆写了 `addListeningTimeEnabled`（test/ui/pages/settings_desktop_dialog_test.dart:218、test/ui/pages/settings_desktop_gate_test.dart:383）——新开关瓦片会读 `player.cloudHistoryUploadEnabled`，这些 Fake 需补 `@override bool get cloudHistoryUploadEnabled => false;`，否则 null 崩溃。

---

### Task 1: Rust 引擎暴露播放记录上报路由

**Files:**
- Modify: `rust/src/engine.rs`（一期 `("GET", "/user/playhistory")` 臂之后）
- Modify: `rust/src/services/report.rs:11`（摘 dead_code）

**Interfaces:**
- Produces: 引擎路由 `("POST", "/playhistory/upload")`，参数 `mixsongid`（必填，须可解析为正整数）、`play_count`（可选，默认 1）；Task 2 的 Dart 方法依赖此路径与参数名。

- [ ] **Step 1: engine.rs 加路由**

在 `rust/src/engine.rs` 中一期加的这行之后：

```rust
            ("GET", "/user/playhistory") => user::user_history(client, session).await,
```

插入：

```rust
            ("POST", "/playhistory/upload") => {
                // Dart 走 query: mixsongid / play_count
                let mixsongid = first_str(&[], params, &["mixsongid", "mixSongId"])
                    .and_then(|s| s.parse::<i64>().ok())
                    .unwrap_or(0i64);
                if mixsongid <= 0 {
                    Err(AppError::Other(
                        "playhistory/upload 需要有效的 mixsongid".into(),
                    ))
                } else {
                    let play_count = params
                        .get("play_count")
                        .and_then(|s| s.parse::<i64>().ok())
                        .unwrap_or(1i64);
                    report::upload_play_history(client, session, mixsongid, None, play_count)
                        .await
                }
            }
```

- [ ] **Step 2: 摘掉 upload_play_history 的 dead_code 标记**

`rust/src/services/report.rs` 删除 `pub async fn upload_play_history` 上方的 `#[allow(dead_code)]` 行（第 11 行），函数本体勿动。同文件 `latest_songs` 的标记保留。

- [ ] **Step 3: cargo check 验证**

Run: `cd rust && cargo check`
Expected: Finished 无 error 无新 warning。（薄封装无离线单测，真实上报归 Task 5 验收说明的真机灰度项。）

- [ ] **Step 4: Commit**

```bash
git add rust/src/engine.rs rust/src/services/report.rs
git commit -m "feat(timemachine): 引擎暴露播放记录上报路由 /playhistory/upload"
```

---

### Task 2: MusicApi 上报方法

**Files:**
- Modify: `lib/services/music_api_auth.dart`（一期 `cloudPlayHistory` 方法之后）
- Test: `test/services/upload_play_history_api_test.dart`

**Interfaces:**
- Consumes: Task 1 的路由（POST /playhistory/upload，query mixsongid/play_count）。
- Produces（Task 3 依赖）: `Future<void> uploadPlayHistory({required String mixSongId, int playCount = 1})`——MusicApi 实例方法，失败向上抛（由调用方吞错）。

- [ ] **Step 1: 写失败测试**

创建 `test/services/upload_play_history_api_test.dart`（假客户端参照 test/rank_audio_all_test.dart）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 假客户端：记录 POST 调用并可预置响应/异常。
class _FakeUploadClient implements ApiClientInterface {
  _FakeUploadClient({this.response, this.error});

  final Object? response;
  final Object? error;
  final List<Map<String, Object?>> posts = [];

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(String path,
      [Map<String, Object?> query = const {}]) async {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(String path,
      {Map<String, Object?> query = const {},
      Map<String, Object?>? body}) async {
    posts.add({'path': path, ...query});
    if (error != null) throw error!;
    return response;
  }

  @override
  void close() {}
}

void main() {
  group('MusicApi.uploadPlayHistory', () {
    test('POST /playhistory/upload 携带 mixsongid 与默认 play_count=1', () async {
      final client = _FakeUploadClient(response: {'status': 1});
      final api = MusicApi(client);

      await api.uploadPlayHistory(mixSongId: '123456');

      expect(client.posts.single['path'], '/playhistory/upload');
      expect(client.posts.single['mixsongid'], '123456');
      expect(client.posts.single['play_count'], 1);
    });

    test('显式 play_count 透传', () async {
      final client = _FakeUploadClient(response: {'status': 1});
      final api = MusicApi(client);

      await api.uploadPlayHistory(mixSongId: '42', playCount: 2);

      expect(client.posts.single['play_count'], 2);
    });

    test('客户端异常向上抛（由调用方吞错，不在 API 层吞）', () async {
      final api = MusicApi(_FakeUploadClient(error: Exception('网络异常')));

      await expectLater(
        api.uploadPlayHistory(mixSongId: '1'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/services/upload_play_history_api_test.dart`
Expected: 编译错误（`uploadPlayHistory` 未定义）。

- [ ] **Step 3: 写实现**

在 `lib/services/music_api_auth.dart` 的 `cloudPlayHistory` 方法之后插入：

```dart
  /// 上报一条播放记录到酷狗云端（「听歌时光机」二期，写操作）。
  ///
  /// 由设置开关「同步播放记录」控制，PlayerController 在起播成功后调用；
  /// 失败向上抛、由调用方吞错，不影响播放主链路。与 addListeningTime
  /// 同款最简 POST，不做信封校验（无 UI 反馈，静默语义）。
  Future<void> uploadPlayHistory({
    required String mixSongId,
    int playCount = 1,
  }) async {
    await _client.post(
      '/playhistory/upload',
      query: {'mixsongid': mixSongId, 'play_count': playCount},
    );
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/services/upload_play_history_api_test.dart`
Expected: 全部 PASS。

- [ ] **Step 5: flutter analyze + Commit**

Run: `flutter analyze` → `No issues found!`

```bash
git add lib/services/music_api_auth.dart test/services/upload_play_history_api_test.dart
git commit -m "feat(timemachine): MusicApi 播放记录上报薄包装"
```

---

### Task 3: PlayerController 开关与起播上报钩子

**Files:**
- Modify: `lib/controllers/player_controller.dart`（key 常量 + 字段默认 false）
- Modify: `lib/controllers/player_controller.settings.dart`（setter、恢复、上报函数）
- Modify: `lib/controllers/player_controller.playback.dart:236` 附近（钩子）
- Test: `test/controllers/cloud_history_upload_test.dart`

**Interfaces:**
- Consumes: Task 2 的 `MusicApi.uploadPlayHistory({required String mixSongId, int playCount})`。
- Produces（Task 4 依赖）:
  - `bool cloudHistoryUploadEnabled = false;`（PlayerController 公开字段，默认 false）
  - `Future<void> setCloudHistoryUploadEnabled(bool enabled)`
  - `@visibleForTesting static int? cloudUploadMixSongIdOf(Song song)`（mixsongid 资格判定，纯静态）
  - 私有 `Future<void> _reportCloudPlayHistory(Song song)`（吞错上报）
  - prefs key：`settings.cloud_history_upload_enabled`

- [ ] **Step 1: 写失败测试**

创建 `test/controllers/cloud_history_upload_test.dart`。装置拷贝自 test/controllers/play_confirm_timeout_test.dart（`_MockMusicApi`、`_RecordingAudioHandler`、`settle()`、`_song()` 若有；拷贝后按下面扩展），widget 侧 SharedPreferences 用 `SharedPreferences.setMockInitialValues(const {})`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 其余 import 按装置来源文件与实际类型补齐（music_api/player_controller/models）

/// Spy：在 _MockMusicApi 基础上记录 uploadPlayHistory 调用，可注入异常。
class _SpyMusicApi extends _MockMusicApi {
  final List<String> uploadedMixSongIds = [];
  Object? uploadError;

  @override
  Future<void> uploadPlayHistory({
    required String mixSongId,
    int playCount = 1,
  }) async {
    if (uploadError != null) throw uploadError!;
    uploadedMixSongIds.add(mixSongId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const {});

  group('cloudUploadMixSongIdOf 资格判定（纯静态）', () {
    test('酷狗源 + 数字 albumAudioId → 解析为 int', () {
      final song = Song(
          id: '999', title: 'T', artist: 'A', hash: 'h',
          albumAudioId: '123456');
      expect(PlayerController.cloudUploadMixSongIdOf(song), 123456);
    });

    test('albumAudioId 缺省时回退 song.id（与评论按钮同口径）', () {
      final song = Song(id: '777', title: 'T', artist: 'A', hash: 'h');
      expect(PlayerController.cloudUploadMixSongIdOf(song), 777);
    });

    test('网易源 → null（不上报）', () {
      final song = Song(
          id: '123', title: 'T', artist: 'A', hash: 'ne_1',
          source: SongSource.netease);
      expect(PlayerController.cloudUploadMixSongIdOf(song), isNull);
    });

    test('本地源 → null（不上报）', () {
      final song = Song(
          id: '/storage/a.mp3', title: 'T', artist: 'A', hash: '/storage/a.mp3',
          source: SongSource.local);
      expect(PlayerController.cloudUploadMixSongIdOf(song), isNull);
    });

    test('非数字 id（hash 兜底）→ null（不上报）', () {
      final song = Song(
          id: 'ABCDEF1234', title: 'T', artist: 'A', hash: 'ABCDEF1234');
      expect(PlayerController.cloudUploadMixSongIdOf(song), isNull);
    });
  });

  group('起播上报钩子（行为）', () {
    test('默认关：起播成功不调用上报', () async {
      // 装置：SpyMusicApi + handler，参照 play_confirm_timeout_test 构造
      final api = _SpyMusicApi();
      final controller = PlayerController(api, handler);
      addTearDown(controller.dispose);
      await controller.playSong(kugouSong, queue: [kugouSong]);
      await settle(); await settle();

      expect(controller.cloudHistoryUploadEnabled, isFalse);
      expect(api.uploadedMixSongIds, isEmpty);
    });

    test('开启后：酷狗歌起播成功 → 上报一次且 id 正确', () async {
      final api = _SpyMusicApi();
      final controller = PlayerController(api, handler);
      addTearDown(controller.dispose);
      await controller.setCloudHistoryUploadEnabled(true);
      await controller.playSong(kugouSong, queue: [kugouSong]);
      await settle(); await settle();

      expect(api.uploadedMixSongIds, ['123456']);
    });

    test('开启后：上报异常不影响播放（无 errorMessage、本地历史照记）', () async {
      final api = _SpyMusicApi()..uploadError = Exception('云端 4xx');
      final controller = PlayerController(api, handler);
      addTearDown(controller.dispose);
      await controller.setCloudHistoryUploadEnabled(true);
      await controller.playSong(kugouSong, queue: [kugouSong]);
      await settle(); await settle();

      expect(api.uploadedMixSongIds, isEmpty);
      expect(controller.errorMessage, isNull);
      final history = await PlaybackHistoryService().getHistory();
      expect(history.map((s) => s.hash), contains(kugouSong.hash));
    });
  });

  group('开关持久化', () {
    test('setCloudHistoryUploadEnabled 写入 prefs 且恢复读回', () async {
      final controller = PlayerController(_SpyMusicApi(), handler);
      addTearDown(controller.dispose);

      expect(controller.cloudHistoryUploadEnabled, isFalse); // 默认关

      await controller.setCloudHistoryUploadEnabled(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings.cloud_history_upload_enabled'), isTrue);
    });
  });
}
```

（`kugouSong` 为 `Song(id: '123456', title: 'T', artist: 'A', hash: 'hash1', albumAudioId: '123456')`；`handler` 为拷贝自 play_confirm_timeout_test 的 `_RecordingAudioHandler()`，让 playSong 走成功路径。装置细节以来源文件为准，测试断言逐字保留。）

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/controllers/cloud_history_upload_test.dart`
Expected: 编译错误（`cloudUploadMixSongIdOf` / `cloudHistoryUploadEnabled` 未定义）。

- [ ] **Step 3: 写实现**

1. `lib/controllers/player_controller.dart`：在一组 `const _xxxSettingKey = 'settings.xxx';` 常量区（101 行附近）加：

```dart
const _cloudHistoryUploadSettingKey = 'settings.cloud_history_upload_enabled';
```

在 `bool addListeningTimeEnabled = true;`（614 行附近）之后加：

```dart
  /// 云端播放记录上报开关（「听歌时光机」二期）。默认关闭：
  /// 上报是把听歌行为写进酷狗账号画像的写操作，必须用户显式开启。
  bool cloudHistoryUploadEnabled = false;
```

2. `lib/controllers/player_controller.settings.dart`：`setAddListeningTimeEnabled`（5-18 行）之后加 setter：

```dart
  Future<void> setCloudHistoryUploadEnabled(bool enabled) async {
    if (cloudHistoryUploadEnabled == enabled) {
      return;
    }
    cloudHistoryUploadEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cloudHistoryUploadSettingKey, enabled);
    notifyListeners();
  }
```

`_restoreSettings()`（338 行附近，`addListeningTimeEnabled` 恢复行旁）加：

```dart
    cloudHistoryUploadEnabled =
        prefs.getBool(_cloudHistoryUploadSettingKey) ?? cloudHistoryUploadEnabled;
```

文件内 listen-time 代码（569-597 行附近）之后加上报函数：

```dart
  /// 云端上报用的 mixsongid（与评论按钮同口径）：仅酷狗在线源，
  /// 且 id 须可解析为数字；本地/网易源、hash 兜底的非数字 id 一律不上报。
  @visibleForTesting
  static int? cloudUploadMixSongIdOf(Song song) {
    if (song.source != SongSource.kugou) return null;
    final id = song.albumAudioId ?? song.id;
    if (id.isEmpty) return null;
    return int.tryParse(id);
  }

  /// 起播成功后上报一条播放记录。失败静默（debugPrint）：
  /// 云端记录是锦上添花，绝不打扰播放主链路，也不做重试。
  Future<void> _reportCloudPlayHistory(Song song) async {
    final mixSongId = cloudUploadMixSongIdOf(song);
    if (mixSongId == null) return;
    try {
      await _api.uploadPlayHistory(mixSongId: '$mixSongId');
    } catch (error) {
      debugPrint('[时音][cloud-history] upload failed: $error');
    }
  }
```

（`@visibleForTesting` 所在 import：若 settings.dart 未直接 import foundation，则用文件内既有可用的来源；以编译器为准补 import。）

3. `lib/controllers/player_controller.playback.dart:236`：`unawaited(_statsService.recordPlay(song));` 之后插：

```dart
      // 云端播放记录上报（默认关；仅酷狗在线源；失败静默）
      if (cloudHistoryUploadEnabled) {
        unawaited(_reportCloudPlayHistory(song));
      }
```

- [ ] **Step 4: 跑测试确认通过 + 全量摸底**

Run: `flutter test test/controllers/cloud_history_upload_test.dart`
Expected: 全部 PASS。

Run: `flutter test`
Expected: 除下述已知破坏外全绿——pump 设置页的 UI 测试若因 Fake player 缺 `cloudHistoryUploadEnabled` 覆写而失败（预计 test/ui/pages/settings_desktop_dialog_test.dart 与 settings_desktop_gate_test.dart），**不要在本任务修**（归 Task 4，瓦片加上后一起补 Fake）。若还有其他文件因此失败，记录清单写入报告。

- [ ] **Step 5: flutter analyze + Commit**

Run: `flutter analyze` → `No issues found!`

```bash
git add lib/controllers/player_controller.dart lib/controllers/player_controller.settings.dart lib/controllers/player_controller.playback.dart test/controllers/cloud_history_upload_test.dart
git commit -m "feat(timemachine): 播放记录云端上报开关与起播钩子（默认关）"
```

---

### Task 4: 设置页「同步播放记录」开关

**Files:**
- Modify: `lib/ui/settings/playback_settings_section.dart`（「听歌时光机」瓦片 + 其后 divider 之后）
- Test: 补 pump 设置页的存量测试 Fake（Task 3 摸底清单），必要时新增直接 pump 本分区的测试

**Interfaces:**
- Consumes: Task 3 的 `player.cloudHistoryUploadEnabled` / `player.setCloudHistoryUploadEnabled`。
- Produces: 无（UI 末端）。

- [ ] **Step 1: 加开关瓦片**

在 playback_settings_section.dart 中一期「听歌时光机」`SettingsTile` 之后的既有 `SettingsDivider()` 之后插入（该 divider 之后、`if (!isDesktopFormFactor)` 块之前，保持「瓦片-分隔线-开关」节奏）：

```dart
            SettingsSwitchTile(
              icon: Icons.cloud_upload_outlined,
              iconColor: const Color(0xFF5C6BC0),
              title: '同步播放记录',
              subtitle: '开启后，在时音的播放上报到酷狗账号（默认关闭）',
              value: player.cloudHistoryUploadEnabled,
              onChanged: player.setCloudHistoryUploadEnabled,
            ),
```

（全平台可见、不加桌面门控：桌面端同样登录酷狗账号、同样有时光机入口。）

- [ ] **Step 2: 修复/补齐受影响测试 Fake**

Task 3 摸底清单中的每个测试文件：在覆写 `addListeningTimeEnabled` 的 Fake player 旁补：

```dart
  @override
  bool get cloudHistoryUploadEnabled => false;
```

（已知两处：test/ui/pages/settings_desktop_dialog_test.dart:218、test/ui/pages/settings_desktop_gate_test.dart:383；以 Task 3 清单与实际跑测为准。）

- [ ] **Step 3: 写开关交互测试**

创建 `test/ui/settings/cloud_history_upload_switch_test.dart`：直接 pump `PlaybackSettingsSection`（Fake api/auth/player + `onSelectDefaultAudioQuality: () {}`，Fake player 覆写 getter 返回 false、覆写 setter 记录调用），断言：

```dart
    testWidgets('「同步播放记录」默认关，点击开关调用 setter(true)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PlaybackSettingsSection(
            api: fakeApi, auth: fakeAuth, player: fakePlayer,
            onSelectDefaultAudioQuality: () {},
          ),
        ),
      ));

      expect(find.text('同步播放记录'), findsOneWidget);
      final switchFinder = find.descendant(
        of: find.text('同步播放记录'),
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(switchFinder).value, isFalse);

      await tester.tap(switchFinder);
      await tester.pump();

      expect(fakePlayer.setterCalls, contains(true));
    });
```

（Fake player 的 setter 覆写只记录不落盘，避免 prefs；Fake api/auth 参照同文件既有测试的写法——若该文件是新建的，参照 test/ui/pages/settings_desktop_gate_test.dart 内 Fake 构造。若 PlaybackSettingsSection 在 pump 时触及其他 player getter 导致 Fake 返回 null 崩溃，按需补 `=> false` / 合理默认值的覆写，在报告列明。）

- [ ] **Step 4: 跑测试与静态检查**

Run: `flutter test test/ui/settings/cloud_history_upload_switch_test.dart test/ui/pages/settings_desktop_dialog_test.dart test/ui/pages/settings_desktop_gate_test.dart`
Expected: 全部 PASS。

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/ui/settings/playback_settings_section.dart test/ui/settings/cloud_history_upload_switch_test.dart test/ui/pages/settings_desktop_dialog_test.dart test/ui/pages/settings_desktop_gate_test.dart
git commit -m "feat(timemachine): 设置页新增同步播放记录开关（默认关）"
```

（git add 清单以实际改动文件为准。）

---

### Task 5: 全量验证、变更记录与收尾

**Files:**
- Modify: `update.md`（「未发布」段追加）

**Interfaces:**
- Consumes: Task 1-4 全部产物。

- [ ] **Step 1: 全量验证**

Run: `flutter analyze` → `No issues found!`
Run: `flutter test` → 全绿（一期基线 1156 + 1 skip + 二期新增，0 失败）。
Run: `cd rust && cargo check` → Finished 无 error。

- [ ] **Step 2: update.md 追加**

「未发布」段的「### 新功能」列表（一期已建）追加一行：

```
- 同步播放记录：可选开启，把播放记录上报到酷狗云端账号（默认关闭）
```

- [ ] **Step 3: Commit**

```bash
git add update.md
git commit -m "docs(timemachine): update.md 记录同步播放记录开关"
```

---

## 验收说明（真机项，代码合入后另行执行）

- **小号灰度先行**（一期风险分析既定）：开关打开后连播数首酷狗在线歌 → 登录同一账号的官方概念版 App 查「最近播放/时光机」是否出现这些歌；观察账号无异常再自用。
- 本地音乐 / 网易源播放不应产生上报（抓包确认无 /playhistory/upload 请求）。
- 弱网/未登录时开启开关播放：无崩溃、无错误弹窗、播放不受影响。

## Self-Review 结论

- 覆盖检查：路由（Task 1）、API 包装（Task 2）、开关+钩子+资格判定（Task 3）、设置 UI + 存量测试修复（Task 4）、验证与变更记录（Task 5）——用户诉求「开关控制、开才上报、关不上报」全覆盖；默认关/静默/仅在线源三条风险控制均落为可测断言。
- 占位符检查：无 TBD；Task 3 测试装置指示从 play_confirm_timeout_test.dart 拷贝（装置在仓库内非计划内代码），断言体逐字完整；Task 4 依赖 Task 3 摸底清单属既定的跨任务接口。
- 类型一致性：`uploadPlayHistory({required String mixSongId, int playCount = 1})`、`cloudUploadMixSongIdOf(Song) → int?`、prefs key `settings.cloud_history_upload_enabled`、路由 `POST /playhistory/upload` 与参数 `mixsongid/play_count` 在各任务间一致；测试引用与定义一致（Song 构造必需参 id/title/artist/hash 与 song.dart 一致）。
