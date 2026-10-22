# 听歌时光机（一期·只读）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户在时音内查看自己酷狗账号的云端播放历史，按日期分组呈现为「听歌时光机」页面（issue #2 一期，只读拉取，不做上报）。

**Architecture:** Rust 引擎已实现 `user_history`（酷狗 `/playhistory/v1/get_songs`，需登录）但标记 dead_code 未接入 dispatch；本计划在 `engine.rs` 暴露一条 GET 路由，Dart 侧经既有 `RustApiClient → MusicApi` 链路拉取，用容错解析器把未知形状的响应转成 `CloudPlayRecord` 列表，纯函数按自然日分组，页面复用 `AppSongRow` 展示并从设置分区进入。

**Tech Stack:** Rust（kugou_engine，无需 FRB 代码生成——`engine_request` 签名不变）/ Flutter Dart（无新依赖）/ flutter_test（手写 Fake，无 mockito）。

## Global Constraints

- **只读**：不调用 `/playhistory/v1/upload_songs`，不写任何云端数据（上报是明确的二期，本计划禁止顺手实现）。
- 不新增 pubspec 依赖；不改 `rust/` 下 FFI 接口签名（不跑 flutter_rust_bridge_codegen）。
- `flutter analyze` 必须零 issue（flutter_lints ^6.0.0），`flutter test` 全绿（基线 1138 通过 1 跳过），`cargo check`（rust/ 目录）通过。
- 解析层必须**容错**：`get_songs` 的真实响应形状未经真机验证，解析器不得对未知形状抛异常，解析不出记录时返回空列表；失败的信封（status≠1/200）由 API 层抛 `ApiException`。
- 文案全部中文；颜色一律 `Theme.of(context).colorScheme`（入口瓦片 iconColor 沿用该文件既有硬编码色风格）；图标命名 `*_rounded`/`*_outlined`。
- 提交信息格式沿用仓库惯例 `type(scope): 中文描述`，本特性 scope 固定为 `timemachine`。
- 工作分支：`feat/time-machine`（自 `main` 创建，main 与 origin/main 同步）。

**既有事实（实现者无需重查）：**
- 引擎 dispatch：`rust/src/engine.rs` 的 `match (method, path)`，已登录用户信息在 `KgSession`；`user_history` 定义于 `rust/src/services/user.rs:70`，内部已 POST 酷狗 `/playhistory/v1/get_songs`。
- 引擎响应语义（`rust/src/kugou/api_response.rs:64`、`transport.rs:255`）：成功时把 `data` 提升为根（data 是 Map 时注入 `status:1`）；失败时原始信封（含非 1 的 `status`）原样返回，**不走 Err**；未登录抛 `AppError::Unauthorized("此接口需要登录")` → Dart 侧 `ApiException`。
- Dart 辅助函数 `asString/asInt/asBool/asList/asMap` 定义于 `lib/models/model_parsing.dart`，经 `lib/models/music_models.dart` barrel 导出，music_api 各 part 文件共享。
- `Song.fromSearch`（`lib/models/song.dart:74`）是最通用的酷狗 JSON→Song 工厂（MixSongID/mixsongid/songid…、FileHash/hash…、SingerName/singername…、Image/sizable_cover…、时间字段多候选），`hash` 为空即不可播。
- UI 播放点击惯例（`lib/ui/pages/playback_history_page.dart:82-92`）：先 `openPlayerIfSameSong(context, player:, auth:, song:)`，否则 `player.playSong(song, queue: <全部可见歌曲>)`。
- `LoginPage` 构造：`LoginPage(auth: authController, api: musicApi)`（见 `lib/main.dart:552`）。
- 设置瓦片：`lib/ui/settings/playback_settings_section.dart:135-158` 的「播放统计」「播放历史」两个 `SettingsTile` 之间/之后插入，二者均无桌面门控（全平台可见）。

---

### Task 1: Rust 引擎暴露云端播放历史路由

**Files:**
- Modify: `rust/src/engine.rs`（"GET", "/user/vip/detail" 行之后）
- Modify: `rust/src/services/user.rs:69`（user_history 的属性）

**Interfaces:**
- Produces: 引擎路由 `("GET", "/user/playhistory")`，无参数，返回酷狗原始 JSON 字符串（经 api_response 提升语义）。Dart 侧 `_client.get('/user/playhistory')` 直接可用（Task 3 依赖此路径）。

- [ ] **Step 1: engine.rs 加路由**

在 `rust/src/engine.rs` 中找到这一行（约 703 行）：

```rust
            ("GET", "/user/vip/detail") => user::user_vip_detail(client, session).await,
```

紧随其后插入：

```rust
            ("GET", "/user/playhistory") => user::user_history(client, session).await,
```

- [ ] **Step 2: 摘掉 user_history 的 dead_code 标记**

`rust/src/services/user.rs` 中删除 `pub async fn user_history` 上方的 `#[allow(dead_code)]` 行（第 69 行，函数本体勿动）。其余函数（`user_listen` 等）的标记保留。

- [ ] **Step 3: cargo check 验证**

Run: `cd rust && cargo check`
Expected: `Finished \`dev\` profile ... in N.Ns`，无 error 无新 warning（dead_code 摘除后若编译器不再警告即正确）。

说明：本任务是已实现函数上的一行 dispatch 薄封装，无法离线单测真实响应（需登录态），真机验证归入 Task 4 的验收说明，不写 Rust 单测。

- [ ] **Step 4: Commit**

```bash
git add rust/src/engine.rs rust/src/services/user.rs
git commit -m "feat(timemachine): 引擎暴露云端播放历史只读路由 /user/playhistory"
```

---

### Task 2: 云端播放记录模型、容错解析与按日分组

**Files:**
- Create: `lib/models/cloud_play_history.dart`
- Modify: `lib/models/music_models.dart`（barrel 增加 export）
- Test: `test/models/cloud_play_history_test.dart`

**Interfaces:**
- Consumes: `Song.fromSearch(Map<String, dynamic>)`、`asString/asInt/asList/asMap`（model_parsing.dart）。
- Produces（Task 3/4 依赖，签名勿改）:
  - `class CloudPlayRecord { const CloudPlayRecord({required this.song, this.playedAt}); final Song song; final DateTime? playedAt; }`
  - `class CloudPlayDayGroup { const CloudPlayDayGroup({required this.label, required this.records}); final String label; final List<CloudPlayRecord> records; }`
  - `class CloudPlayHistory { const CloudPlayHistory({this.records = const []}); final List<CloudPlayRecord> records; factory CloudPlayHistory.fromJson(Object? raw); List<CloudPlayDayGroup> groupByDay({DateTime? now}); int get totalRecords; DateTime? get earliestPlayedAt; }`

- [ ] **Step 1: 写失败测试**

创建 `test/models/cloud_play_history_test.dart`（风格参照 `test/models/search_album_result_test.dart` 的字段契约测试；解析器的存在理由是响应形状未验证，测试就是形状契约的穷举）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

/// `CloudPlayHistory` 容错解析与按日分组的契约测试。
///
/// 背景：酷狗 `/playhistory/v1/get_songs` 的真实响应形状未经真机验证，
/// 解析器必须同时容忍「根即数组 / list / songs / data.list 嵌套」等
/// 常见承载方式，且任何未知形状都不抛异常、返回空。
void main() {
  group('CloudPlayHistory.fromJson 容错解析', () {
    test('根即记录数组：平铺歌曲字段 + 秒级时间戳', () {
      final history = CloudPlayHistory.fromJson([
        {
          'hash': 'abc123',
          'filename': '周杰伦 - 晴天',
          'singername': '周杰伦',
          'songname': '晴天',
          'time': 1729500000,
        },
      ]);

      expect(history.totalRecords, 1);
      expect(history.records.first.song.hash, 'abc123');
      expect(history.records.first.song.title, '晴天');
      expect(history.records.first.playedAt,
          DateTime.fromMillisecondsSinceEpoch(1729500000 * 1000));
    });

    test('list 键承载 + 记录内嵌 song 对象 + 毫秒时间戳', () {
      final history = CloudPlayHistory.fromJson({
        'status': 1,
        'list': [
          {
            'time': 1729500000123,
            'song': {
              'FileHash': 'hash9',
              'OriSongName': '七里香',
              'SingerName': '周杰伦',
              'MixSongID': 12345,
              'Image': 'https://imge.kugou.com/aa/{size}/x.jpg',
            },
          },
        ],
      });

      expect(history.totalRecords, 1);
      expect(history.records.first.song.hash, 'hash9');
      expect(history.records.first.song.title, '七里香');
      expect(history.records.first.playedAt!.millisecondsSinceEpoch,
          1729500000123);
    });

    test('data.list 一层嵌套承载', () {
      final history = CloudPlayHistory.fromJson({
        'status': 1,
        'data': {
          'list': [
            {'hash': 'h1', 'songname': '歌1', 'singername': '人1', 'time': 100},
          ],
        },
      });

      expect(history.totalRecords, 1);
    });

    test('时间字段多候选：ot/addtime/createtime 任一存在即可解析', () {
      final history = CloudPlayHistory.fromJson({
        'list': [
          {'hash': 'a', 'songname': 'A', 'ot': 1729500000},
          {'hash': 'b', 'songname': 'B', 'addtime': '1729600000'},
          {'hash': 'c', 'songname': 'C', 'createtime': 1729700000},
        ],
      });

      expect(history.records.length, 3);
      expect(history.records.every((r) => r.playedAt != null), isTrue);
    });

    test('无 hash 的脏记录被过滤，不影响其余记录', () {
      final history = CloudPlayHistory.fromJson({
        'list': [
          {'hash': '', 'songname': '脏数据'},
          {'hash': 'ok', 'songname': '正常', 'singername': '歌手'},
        ],
      });

      expect(history.totalRecords, 1);
      expect(history.records.first.song.title, '正常');
    });

    test('未知形状不抛异常：空 Map / 纯字符串 / 空数组 / 失败信封都返回空', () {
      expect(CloudPlayHistory.fromJson(const {}).totalRecords, 0);
      expect(CloudPlayHistory.fromJson('oops').totalRecords, 0);
      expect(CloudPlayHistory.fromJson(const []).totalRecords, 0);
      // 失败信封（status!=1）不在解析层抛错——那是 API 层的职责。
      expect(
        CloudPlayHistory.fromJson({'status': 0, 'error_code': 30195}).totalRecords,
        0,
      );
    });

    test('earliestPlayedAt 取所有记录中最早的非空时间', () {
      final history = CloudPlayHistory.fromJson({
        'list': [
          {'hash': 'a', 'songname': 'A', 'time': 1729900000},
          {'hash': 'b', 'songname': 'B', 'time': 1729500000},
          {'hash': 'c', 'songname': 'C'}, // 无时间
        ],
      });

      expect(
        history.earliestPlayedAt!.millisecondsSinceEpoch, 1729500000 * 1000);
    });
  });

  group('CloudPlayHistory.groupByDay 按日分组', () {
    CloudPlayRecord rec(String hash, int? ts) => CloudPlayRecord(
          song: Song(
            id: hash, title: 'T$hash', artist: '歌手', hash: hash,
          ),
          playedAt: ts == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(ts),
        );

    test('今天/昨天标签、组内按时间倒序、组间按日期倒序', () {
      final now = DateTime(2026, 10, 22, 20, 0);
      final todayNoon = DateTime(2026, 10, 22, 12, 0);
      final todayMorning = DateTime(2026, 10, 22, 8, 0);
      final yesterday = DateTime(2026, 10, 21, 10, 0);
      final history = CloudPlayHistory(records: [
        rec('a', yesterday.millisecondsSinceEpoch),
        rec('b', todayMorning.millisecondsSinceEpoch),
        rec('c', todayNoon.millisecondsSinceEpoch),
      ]);

      final groups = history.groupByDay(now: now);

      expect(groups.map((g) => g.label).toList(), ['今天', '昨天']);
      expect(groups.first.records.map((r) => r.song.hash).toList(),
          ['c', 'b']);
      expect(groups.last.records.single.song.hash, 'a');
    });

    test('跨年日期带年份，同年只显示 M月d日', () {
      final now = DateTime(2026, 10, 22);
      final history = CloudPlayHistory(records: [
        rec('x', DateTime(2024, 5, 1).millisecondsSinceEpoch),
        rec('y', DateTime(2026, 3, 8).millisecondsSinceEpoch),
      ]);

      final labels = history.groupByDay(now: now).map((g) => g.label).toList();
      expect(labels, ['2026年3月8日', '2024年5月1日']);
    });

    test('无时间戳的记录归入末尾「未知时间」组', () {
      final history = CloudPlayHistory(records: [
        rec('no-time', null),
        rec('timed', DateTime(2026, 10, 22).millisecondsSinceEpoch),
      ]);

      final groups = history.groupByDay(now: DateTime(2026, 10, 22));
      expect(groups.last.label, '未知时间');
      expect(groups.last.records.single.song.hash, 'no-time');
      expect(groups.first.label, '今天');
    });

    test('空记录返回空分组列表', () {
      expect(const CloudPlayHistory().groupByDay(), isEmpty);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/models/cloud_play_history_test.dart`
Expected: 编译错误（`cloud_play_history.dart` 不存在 / `CloudPlayHistory` 未定义）。

- [ ] **Step 3: 写实现**

创建 `lib/models/cloud_play_history.dart`：

```dart
import 'model_parsing.dart';
import 'song.dart';

/// 云端播放记录：酷狗账号级听歌历史中的一条。
class CloudPlayRecord {
  const CloudPlayRecord({required this.song, this.playedAt});

  final Song song;

  /// 服务端记录的播放时间；缺失时为 null（归入「未知时间」分组）。
  final DateTime? playedAt;
}

/// 按自然日聚合的一组云端播放记录。
class CloudPlayDayGroup {
  const CloudPlayDayGroup({required this.label, required this.records});

  /// 分组标题（今天 / 昨天 / M月d日 / yyyy年M月d日 / 未知时间）。
  final String label;
  final List<CloudPlayRecord> records;
}

/// 云端播放历史：酷狗服务端返回的账号听歌记录集合。
///
/// `/playhistory/v1/get_songs` 的真实响应形状未经真机验证，
/// [fromJson] 对承载结构做容错探测（根数组 / list / songs / data.list），
/// 任何无法识别的形状都返回空集合而不是抛异常。
class CloudPlayHistory {
  const CloudPlayHistory({this.records = const []});

  final List<CloudPlayRecord> records;

  factory CloudPlayHistory.fromJson(Object? raw) {
    final parsed = <CloudPlayRecord>[];
    for (final map in _recordMaps(raw)) {
      final record = _parseRecord(map);
      if (record != null) parsed.add(record);
    }
    return CloudPlayHistory(records: parsed);
  }

  int get totalRecords => records.length;

  /// 所有记录中最早的非空播放时间（页面摘要「最早可回到」用）。
  DateTime? get earliestPlayedAt {
    DateTime? earliest;
    for (final record in records) {
      final time = record.playedAt;
      if (time != null && (earliest == null || time.isBefore(earliest))) {
        earliest = time;
      }
    }
    return earliest;
  }

  /// 按自然日倒序分组；组内按播放时间倒序；无时间的记录归末尾组。
  List<CloudPlayDayGroup> groupByDay({DateTime? now}) {
    if (records.isEmpty) return const [];
    final nowResolved = now ?? DateTime.now();
    final today = DateTime(nowResolved.year, nowResolved.month, nowResolved.day);

    final buckets = <DateTime, List<CloudPlayRecord>>{};
    final unknown = <CloudPlayRecord>[];
    for (final record in records) {
      final time = record.playedAt;
      if (time == null) {
        unknown.add(record);
        continue;
      }
      final day = DateTime(time.year, time.month, time.day);
      buckets.putIfAbsent(day, () => []).add(record);
    }

    final days = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final day in days)
        CloudPlayDayGroup(
          label: _dayLabel(day, today),
          records: (buckets[day]!
                ..sort((a, b) => b.playedAt!.compareTo(a.playedAt!)))
              .toList(),
        ),
      if (unknown.isNotEmpty) CloudPlayDayGroup(label: '未知时间', records: unknown),
    ];
  }

  static String _dayLabel(DateTime day, DateTime today) {
    final diffDays = today.difference(day).inDays;
    if (diffDays == 0) return '今天';
    if (diffDays == 1) return '昨天';
    final yearPrefix = day.year == today.year ? '' : '${day.year}年';
    return '$yearPrefix${day.month}月${day.day}日';
  }

  /// 记录数组的候选承载键。真实形状未验证，按常见程度排列。
  static const _listKeys = ['list', 'songs', 'history', 'records'];

  static Iterable<Map<String, dynamic>> _recordMaps(Object? raw) {
    if (raw is List) {
      return raw.whereType<Map<String, dynamic>>();
    }
    final map = asMap(raw);
    if (map.isEmpty) return const [];
    for (final key in [..._listKeys, 'data']) {
      final value = map[key];
      if (value is List) return value.whereType<Map<String, dynamic>>();
    }
    // 一层嵌套：{data: {list: [...]}}
    final dataMap = asMap(map['data']);
    for (final key in _listKeys) {
      final value = dataMap[key];
      if (value is List) return value.whereType<Map<String, dynamic>>();
    }
    return const [];
  }

  static CloudPlayRecord? _parseRecord(Map<String, dynamic> map) {
    // 歌曲字段可能平铺在记录上，也可能嵌在 song / audio_info 下。
    final songMap = asMap(map['song']).isNotEmpty
        ? asMap(map['song'])
        : asMap(map['audio_info']).isNotEmpty
            ? asMap(map['audio_info'])
            : map;
    final song = Song.fromSearch(songMap);
    if (song.hash.isEmpty) return null;
    return CloudPlayRecord(song: song, playedAt: _parseTime(map, songMap));
  }

  static const _timeKeys = [
    'time', 'addtime', 'add_time', 'play_time', 'ot',
    'createtime', 'create_time', 'timestamp',
  ];

  static DateTime? _parseTime(
    Map<String, dynamic> record,
    Map<String, dynamic> song,
  ) {
    for (final source in [record, song]) {
      for (final key in _timeKeys) {
        final value = asInt(source[key]);
        if (value == null || value <= 0) continue;
        // 秒级（约 1e9）与毫秒级（约 1e12）统一折算成毫秒。
        return DateTime.fromMillisecondsSinceEpoch(
          value > 9999999999 ? value : value * 1000,
        );
      }
    }
    return null;
  }
}
```

在 `lib/models/music_models.dart` 的 export 列表末尾加：

```dart
export 'cloud_play_history.dart';
```

（若该 barrel 文件有排序惯例则按其字母序插入。）

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/models/cloud_play_history_test.dart`
Expected: 全部 PASS。

- [ ] **Step 5: flutter analyze**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/models/cloud_play_history.dart lib/models/music_models.dart test/models/cloud_play_history_test.dart
git commit -m "feat(timemachine): 云端播放记录模型与容错解析、按日分组"
```

---

### Task 3: MusicApi 拉取云端播放历史

**Files:**
- Modify: `lib/services/music_api_auth.dart`（mixin `_MusicApiAuth` 内，`addListeningTime` 方法之后）
- Test: `test/services/cloud_play_history_api_test.dart`

**Interfaces:**
- Consumes: Task 1 的引擎路由（`GET /user/playhistory`）、Task 2 的 `CloudPlayHistory.fromJson`。
- Produces（Task 4 依赖）: `Future<CloudPlayHistory> cloudPlayHistory()`——MusicApi 实例方法。

- [ ] **Step 1: 写失败测试**

创建 `test/services/cloud_play_history_api_test.dart`（假客户端模式参照 `test/rank_audio_all_test.dart`）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 假客户端：对 /user/playhistory 返回预置响应。
class _FakeHistoryClient implements ApiClientInterface {
  _FakeHistoryClient(this.response);

  final Object? response;
  Object? requestedPath;

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(String path,
      [Map<String, Object?> query = const {}]) async {
    requestedPath = path;
    return response;
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(String path,
      {Map<String, Object?> query = const {},
      Map<String, Object?>? body}) async {
    throw UnimplementedError();
  }

  @override
  void close() {}
}

void main() {
  group('MusicApi.cloudPlayHistory', () {
    test('请求 GET /user/playhistory 并解析成功响应', () async {
      final client = _FakeHistoryClient({
        'status': 1,
        'list': [
          {'hash': 'h1', 'songname': '晴天', 'singername': '周杰伦', 'time': 100},
        ],
      });
      final api = MusicApi(client);

      final history = await api.cloudPlayHistory();

      expect(client.requestedPath, '/user/playhistory');
      expect(history.totalRecords, 1);
      expect(history.records.first.song.title, '晴天');
    });

    test('根即数组的成功响应同样可解析', () async {
      final api = MusicApi(_FakeHistoryClient([
        {'hash': 'h2', 'songname': '七里香', 'singername': '周杰伦'},
      ]));

      expect((await api.cloudPlayHistory()).totalRecords, 1);
    });

    test('失败信封（status!=1）抛 ApiException 且带错误信息', () async {
      final api = MusicApi(_FakeHistoryClient({
        'status': 0,
        'error_code': 30195,
        'error': '请先登录',
      }));

      await expectLater(
        api.cloudPlayHistory(),
        throwsA(isA<Exception>()),
      );
    });

    test('status==200 的信封按成功处理', () async {
      final api = MusicApi(_FakeHistoryClient({
        'status': 200,
        'songs': [
          {'hash': 'h3', 'songname': '稻香', 'singername': '周杰伦'},
        ],
      }));

      expect((await api.cloudPlayHistory()).totalRecords, 1);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/services/cloud_play_history_api_test.dart`
Expected: 编译错误（`cloudPlayHistory` 方法未定义）。

- [ ] **Step 3: 写实现**

在 `lib/services/music_api_auth.dart` 的 `addListeningTime` 方法（约 130-132 行）之后插入：

```dart
  /// 拉取酷狗账号云端播放历史（「听歌时光机」数据源，只读）。
  ///
  /// 引擎对成功响应会把 data 提升为根并注入 status:1；失败时原样返回
  /// 带非 1/200 status 的原始信封，这里转成 ApiException 交给调用方展示。
  /// 响应的具体承载形状由 [CloudPlayHistory.fromJson] 容错处理。
  Future<CloudPlayHistory> cloudPlayHistory() async {
    final raw = await _client.get('/user/playhistory');
    final json = asMap(raw);
    final status = asInt(json['status']);
    if (json.isNotEmpty && status != null && status != 1 && status != 200) {
      throw ApiException('拉取云端播放历史失败${_failureSuffix(json)}');
    }
    return CloudPlayHistory.fromJson(raw);
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/services/cloud_play_history_api_test.dart`
Expected: 全部 PASS。

- [ ] **Step 5: flutter analyze + Commit**

Run: `flutter analyze` → `No issues found!`

```bash
git add lib/services/music_api_auth.dart test/services/cloud_play_history_api_test.dart
git commit -m "feat(timemachine): MusicApi 拉取云端播放历史并转译失败信封"
```

---

### Task 4: 听歌时光机页面与设置入口

**Files:**
- Create: `lib/ui/pages/time_machine_page.dart`
- Modify: `lib/ui/settings/playback_settings_section.dart`（「播放历史」瓦片之后）
- Test: `test/ui/pages/time_machine_page_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `api.cloudPlayHistory()`、Task 2 的 `CloudPlayHistory.groupByDay/earliestPlayedAt/totalRecords`；`AppSongRow(song:, player:, onTap:)`（lib/ui/widgets/app_song_row.dart）；`openPlayerIfSameSong(context, player:, auth:, song:)`（见 playback_history_page.dart 的 import 与用法）；`LoginPage(auth:, api:)`。
- Produces: `TimeMachinePage({required MusicApi api, required AuthController auth, required PlayerController player})`。

- [ ] **Step 1: 写失败的 widget 测试**

创建 `test/ui/pages/time_machine_page_test.dart`（Fake 模式参照 `test/controllers/player_auto_advance_test.dart` 的手写 Fake）：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/pages/time_machine_page.dart';

class _FakeClient implements ApiClientInterface {
  _FakeClient({this.response, this.error});
  final Object? response;
  final Object? error;
  String? requestedPath;

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(String path,
      [Map<String, Object?> query = const {}]) async {
    requestedPath = path;
    if (error != null) throw error!;
    return response;
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(String path,
      {Map<String, Object?> query = const {},
      Map<String, Object?>? body}) async {
    throw UnimplementedError();
  }

  @override
  void close() {}
}

class _FakeAuth extends Fake implements AuthController {
  _FakeAuth({required this.loggedIn});
  @override
  final bool loggedIn;
  @override
  bool get isLoggedIn => loggedIn;
}

class _FakePlayer extends Fake implements PlayerController {}

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('未登录时展示登录引导，不发请求', (tester) async {
    final client = _FakeClient(response: {'status': 1, 'list': <Object>[]});

    await tester.pumpWidget(_wrap(TimeMachinePage(
      api: MusicApi(client),
      auth: _FakeAuth(loggedIn: false),
      player: _FakePlayer(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('登录后查看你的听歌时光机'), findsOneWidget);
    expect(client.requestedPath, isNull);
  });

  testWidgets('已登录 + 空云端记录时展示空态文案', (tester) async {
    await tester.pumpWidget(_wrap(TimeMachinePage(
      api: MusicApi(_FakeClient(response: {'status': 1, 'list': <Object>[]})),
      auth: _FakeAuth(loggedIn: true),
      player: _FakePlayer(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('云端还没有听歌记录'), findsOneWidget);
  });

  testWidgets('已登录 + 请求失败时展示错误态与重试按钮', (tester) async {
    await tester.pumpWidget(_wrap(TimeMachinePage(
      api: MusicApi(_FakeClient(error: Exception('网络异常'))),
      auth: _FakeAuth(loggedIn: true),
      player: _FakePlayer(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/ui/pages/time_machine_page_test.dart`
Expected: 编译错误（`TimeMachinePage` 不存在）。

- [ ] **Step 3: 写页面实现**

创建 `lib/ui/pages/time_machine_page.dart`。结构对齐 `playback_stats_page.dart`（initState→_reload 存 Future + FutureBuilder 分支）与 `playback_history_page.dart`（行组件用 AppSongRow、播放走 openPlayerIfSameSong）：

```dart
import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../adaptive_layout.dart';
import '../widgets/app_song_row.dart';
import '../widgets/song_tap_handler.dart';
import 'login_page.dart';

/// 听歌时光机：酷狗账号云端播放历史的按日期回顾（只读拉取）。
///
/// 数据来自官方 App 同源的账号级听歌记录（issue #2 一期）；
/// 上报（把时音的播放写回云端）是二期，本页不含任何写操作。
class TimeMachinePage extends StatefulWidget {
  const TimeMachinePage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  @override
  State<TimeMachinePage> createState() => _TimeMachinePageState();
}

class _TimeMachinePageState extends State<TimeMachinePage> {
  Future<CloudPlayHistory>? _future;

  @override
  void initState() {
    super.initState();
    if (widget.auth.isLoggedIn) {
      _reload();
    }
  }

  void _reload() {
    setState(() {
      _future = widget.api.cloudPlayHistory();
    });
  }

  void _goLogin() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoginPage(auth: widget.auth, api: widget.api),
      ),
    );
  }

  void _play(CloudPlayRecord record, List<Song> queue) {
    if (openPlayerIfSameSong(
      context,
      player: widget.player,
      auth: widget.auth,
      song: record.song,
    )) {
      return;
    }
    widget.player.playSong(record.song, queue: queue);
  }

  String _formatDate(DateTime time) =>
      '${time.year}年${time.month}月${time.day}日';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌时光机'),
        actions: [
          if (_future != null)
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _reload,
            ),
        ],
      ),
      body: AdaptiveContentPadding(
        child: !widget.auth.isLoggedIn
            ? _LoginGuideView(onLogin: _goLogin)
            : FutureBuilder<CloudPlayHistory>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _ErrorView(message: '${snapshot.error}', onRetry: _reload);
                  }
                  final history = snapshot.data ?? const CloudPlayHistory();
                  if (history.totalRecords == 0) {
                    return const _EmptyView();
                  }
                  return _TimeMachineContent(
                    history: history,
                    formatDate: _formatDate,
                    onPlay: _play,
                  );
                },
              ),
      ),
    );
  }
}
```

同文件内补齐私有组件（视觉对齐 playback_stats_page 的卡片风格：`colorScheme.surfaceContainer` + 14 圆角）：

- `_LoginGuideView`：居中 `Icon(Icons.hourglass_top_rounded, size: 64, color: colorScheme.onSurfaceVariant)` + `Text('登录后查看你的听歌时光机')` + 副文案「登录酷狗账号后，可回顾云端同步的听歌记录」+ `FilledButton.tonalIcon(icon: Icon(Icons.login_rounded), label: Text('去登录'), onPressed: onLogin)`。注意：非 const 构造（带回调），调用处去掉 const。
- `_EmptyView`：居中 `Icon(Icons.cloud_off_outlined, size: 64, ...)` + `Text('云端还没有听歌记录')` + 副文案「用同一酷狗账号在官方 App 或时音听歌后，这里会出现你的听歌足迹」。
- `_ErrorView`：居中 `Icon(Icons.error_outline_rounded)` + message + `OutlinedButton.icon(icon: Icon(Icons.refresh_rounded), label: const Text('重试'), onPressed: onRetry)`。
- `_TimeMachineContent`：`ListView(padding: EdgeInsets.fromLTRB(16, 8, 16, 32))`，首项是摘要卡片（`共 N 条云端记录`，earliestPlayedAt 非空时追加 ` · 最早可回到 yyyy年M月d日`）；随后每组：`_GroupHeader`（label + `${records.length} 首`，样式对齐 stats 页 `_SectionHeader`：`colorScheme.onSurfaceVariant`、加粗小字）与每条记录的 `AppSongRow(song:, player:, onTap: () => onPlay(record, allSongs))`，其中 `allSongs` 为全部记录的 song 展开（保证随机队列完整）。AppSongRow 的 `subtitle` 传 record.playedAt 的 `HH:mm`（24 小时制，如 `14:05`；为 null 时不传 subtitle、保持默认歌手名）。

import 需要的真伪请以编译器为准修正（`AdaptiveContentPadding` 来自 `../adaptive_layout.dart`；`openPlayerIfSameSong` 的实际来源文件以 `playback_history_page.dart` 顶部 import 为准，照抄）。

- [ ] **Step 4: 设置分区加入口**

`lib/ui/settings/playback_settings_section.dart` 中「播放历史」`SettingsTile`（147-158 行）结束的 `),` 之后、其后的 `SettingsDivider()` 之前插入：

```dart
            SettingsTile(
              icon: Icons.hourglass_top_rounded,
              iconColor: const Color(0xFF00897B),
              title: '听歌时光机',
              subtitle: '云端听歌记录按日期回顾',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      TimeMachinePage(api: api, auth: auth, player: player),
                ),
              ),
            ),
```

并确认文件顶部已 import `time_machine_page.dart`（该文件同目录 `../pages/...` 的 import 风格照抄现有 PlaybackHistoryPage 的 import 行）。注意现有「播放历史」瓦片后面已有一个 `SettingsDivider()`（159 行），插入位置在该 divider 之前即可保持「瓦片-分隔线-瓦片」节奏。

- [ ] **Step 5: 跑测试与静态检查**

Run: `flutter test test/ui/pages/time_machine_page_test.dart`
Expected: 全部 PASS（若 `pumpAndSettle` 因页面动画超时，改用 `tester.pump(const Duration(seconds: 1))` 两次）。

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/ui/pages/time_machine_page.dart lib/ui/settings/playback_settings_section.dart test/ui/pages/time_machine_page_test.dart
git commit -m "feat(timemachine): 听歌时光机页面与设置入口"
```

---

### Task 5: 全量验证与收尾

**Files:**
- Modify: `update.md`（仓库根，变更记录；按文件内既有条目格式追加）

**Interfaces:**
- Consumes: Task 1-4 的全部产物。

- [ ] **Step 1: 全量验证**

Run: `flutter analyze`
Expected: `No issues found!`

Run: `flutter test`
Expected: 全绿（基线 1138 通过 + 本特性新增用例，1 跳过）。

Run: `cd rust && cargo check`
Expected: Finished，无 error。

- [ ] **Step 2: update.md 追加变更记录**

读 `update.md` 开头，按既有格式在对应版本段（或新起 `## 未发布` 段，以文件现状为准）追加一行功能描述：

```
- 听歌时光机：查看酷狗账号云端听歌记录，按日期分组回顾（issue #2，只读同步）
```

- [ ] **Step 3: Commit**

```bash
git add update.md
git commit -m "docs(timemachine): update.md 记录听歌时光机特性"
```

---

## 验收说明（真机项，代码合入后另行执行）

- 登录酷狗账号 → 设置 → 播放 → 听歌时光机：应看到云端记录按今天/昨天/日期分组。
- 若返回空：开启 `SHIYIN_DEBUG_LYRICS` 之外无现成网络日志时，用抓包或临时日志确认 `/playhistory/v1/get_songs` 真实形状，回填 `_listKeys`/`_timeKeys` 契约测试后修正解析器。
- 二期（本计划不做）：上报 `/playhistory/v1/upload_songs`（默认关闭的开关 + 小号灰度）。

## Self-Review 结论

- 覆盖检查：只读拉取（Task 1/3）、容错解析与分组（Task 2）、页面与入口（Task 4）、验证与变更记录（Task 5）——issue #2 一期诉求全覆盖；上报明确排除。
- 占位符检查：无 TBD/TODO；Task 4 的私有组件给了完整行为规格与视觉对齐基准（该文件私有组件样式逐字复刻 stats 页可由实现者直接照抄对应段落）。
- 类型一致性：`CloudPlayHistory/CloudPlayRecord/CloudPlayDayGroup`、`cloudPlayHistory()`、路由 `/user/playhistory` 在各任务间引用一致；测试中的构造调用与 Task 2 定义的签名一致（`Song(id:, title:, artist:, hash:)` 为 const 构造必需参数的最小集，与 song.dart 一致）。
