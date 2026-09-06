# 拆分大文件重构计划(行为保持)

日期: 2026-09-06
分支: feature/pc-desktop-adaptation(沿用前几轮约定,直接按任务提交)
基线: flutter analyze 0 issues + flutter test 全绿(执行前已验证,见账本)

## 背景与目标

项目约 6 万行源码,存在多个 1300–3400 行的大文件,且最大的几个正是 git 改动
热点(近 200 次提交: player_controller 36 次、player_page 28 次、
settings_page 23 次)。本计划把大文件拆成可维护的小文件,**严格行为保持**:
只做搬移与机械重组,不改任何运行时逻辑。

## 全局约束(每个任务都必须遵守)

1. **行为保持**: 禁止修改任何运行时逻辑;禁止顺手重命名公开 API、改算法、
   改参数。允许的改动仅限: 类/函数在文件间移动、为跨文件可见性去除下划线
   (项目是 app 无外部消费者,包内改名安全)、新增 import/export 语句、
   dart format 格式化触碰过的文件。
2. **禁止 `part`/`part of` 用于 Task 1/2/3/4 的文件拆分**(这些是独立单元的
   搬移,用独立文件 + import/export)。唯一例外是 Task 5 的单类内部拆分
   (见 Task 5 说明,part 在该场景是唯一真正行为保持的方案)。
3. **验证命令**: 每个任务完成后必须 `flutter analyze`(0 issues)且
   `flutter test`(全绿)后才允许提交。基线 47 个测试文件,数量不许减少;
   允许因私有类去下划线而微调个别测试的引用(若测试引用了私有符号)。
4. **导入风格**: 与项目现状一致(相对导入,如 `import '../models/song.dart'`)。
5. **提交**: 每个任务至少一个独立 commit,message 用
   `refactor(<scope>): <中文描述>` 风格,与仓库历史一致。
6. **缓存文件**: `*.g.dart`、`frb_generated*` 等生成文件一律不碰。

## Task 1: music_models.dart 按领域拆分(barrel export 兼容)

现状: `lib/models/music_models.dart` 2645 行、约 70 个类横跨所有领域;
Song 一个类 530 行、含 9 个 fromXxx 解析工厂;文件内还有私有顶层解析辅助
函数(如 asString、parseArtists 等,拆分前先盘点)。

要求:
- 拆到 `lib/models/` 下的领域文件,建议分组(按实际类归属微调):
  - `song.dart`: SongSource、Song、LyricLine、LyricWord、SongClimax、PlayUrl 等
  - `playlist.dart`: PlaylistSummary、PlaylistDetail、SongPage、ArtistRef、
    ArtistDetail、ArtistAlbum、DailyRecommend 等
  - `user_vip.dart`: LoginSession、PhoneLoginResult、MobileLoginAccount、
    UserProfile、各 Vip 类、QrCodeInfo、QrCheckResult 等
  - `fm.dart`: FmStation、FmClassGroup、FmSongPage、FmImage
  - `comment.dart`: 全部 Comment* 与 MusicComment* 类
  - `search_rank.dart`: Search*、RankCategory、RankSongPage
  - `cloud_drive.dart`: CloudDrive*
  - `netease_external.dart`: NetEase*、ExternalPlaylistParseResult、
    VipRequiredException 等无处安放的杂项可集中到一个 `common.dart`
- 私有顶层辅助函数(asString 等)若跨领域共用: 移入 `model_parsing.dart`
  并去下划线公开(包内使用);仅单领域使用的随领域文件走。
- `music_models.dart` 保留为 **barrel 文件**: 只含对上述全部新文件的
  `export` 语句。这样全项目 60+ 处 `import 'models/music_models.dart'`
  调用点零改动。
- 不改任何类成员、不改任何解析逻辑,纯移动 + 去下划线 + 加 import/export。

## Task 2: music_api.dart 按域拆 extension

现状: `lib/services/music_api.dart` 1684 行,单个 MusicApi 类 56 个方法,
外加 `_ParsedLyricVariants`/`_TimedLyricVariant` 两个文件级私有类。

要求:
- 先盘点类内私有 HTTP/解析基础设施(如 _getJson/_postJson 类方法)。
- 域方法(登录/歌曲 URL/歌单/排行/搜索/云盘/评论等)搬为同文件或独立文件的
  `extension MusicApiXxx on MusicApi`。注意: extension 无法访问类私有成员,
  因此被跨文件 extension 使用的私有成员需去下划线(或集中到
  `music_api_http.dart` 之类的内部基建文件并公开);仅保留壳类最小状态。
- `_ParsedLyricVariants` 等解析辅助类随歌词方法走,去下划线(若跨文件)。
- 调用点语法不变(extension 方法与实例方法在调用点写法一致)。
- 拆分粒度建议 4–7 个域文件,单文件目标 ≤500 行。

## Task 3: settings_page.dart 按分节拆 widget

现状: `lib/ui/pages/settings_page.dart` 1499 行、23 次改动/200 提交。

要求:
- 盘点文件内私有 widget 与分节(播放设置/下载/桌面/响度均衡/关于等),
  搬到 `lib/ui/settings/` 下的分节文件;类去下划线(跨文件后)。
- settings_page.dart 保留页面骨架与导航逻辑。
- 纯搬移: 构造参数显式化,不改任何 build 逻辑、状态管理、回调实现。

## Task 4: player_page.dart 按播放模式拆 widget

现状: `lib/ui/pages/player_page.dart` 3395 行、约 40 个顶层类、28 次改动。
文件内已是清晰的子树边界: 横屏布局(_Landscape*)、海报模式(_Poster*)、
歌词模式(_LyricPlayerPage/_LyricViewport/_DesktopLyricList/_LyricText/
_KaraokeLinePainter)、控制条(_Progress/_Controls/_SeekPointerButton)、
装饰件(_ArtworkBackground/_MarqueeSingleLine 等)。

要求:
- 搬到 `lib/ui/player/` 下按模式分文件(如 landscape_player.dart、
  poster_player.dart、lyric_views.dart、karaoke_painter.dart、
  player_controls.dart、player_backdrops.dart);类去下划线。
- player_page.dart 保留 PlayerPage、_PlayerPageState、_PlayerBody 与
  模式路由逻辑。
- 与 Task 3 同规则: 纯搬移,构造参数显式化。注意各子树从 State 取状态
  的路径(构造参数或回调),保持传参关系不变。

## Task 5: player_controller.dart 提取纯逻辑 + part 拆分

现状: `lib/controllers/player_controller.dart` 2671 行、单个
PlayerController extends ChangeNotifier、约 176 个成员/方法、全项目改动
次数第一。成员间共享大量私有可变状态,mixin 方案需改 176 个成员可见性
(行为风险高),因此本任务采用两级策略:

1. **优先提取无状态纯逻辑**: 盘点方法中的纯函数/独立算法(如歌词定位/
   队列洗牌/进度换算等,只依赖入参不碰 this 可变状态的逻辑),提取为
   独立顶层函数或 helper 类放到独立文件,配单元测试(先写测试再搬,
   用测试锁定行为)。可安全提取的目标包括与 `test/shuffle_queue_test.dart`
   等现有测试对应的逻辑。
2. **剩余状态管理用 part 拆分**: PlayerController 类声明与字段留在
   `player_controller.dart`,方法体按职责分到
   `player_controller.lyrics.dart`、`player_controller.queue.dart`、
   `player_controller.effects.dart`、`player_controller.playback.dart` 等
   part 文件(同一库内,私有成员互访零改动,行为 100% 保持)。这是本计划
   唯一允许 part 的场景,理由: 单类内部拆分在 Dart 里 part 是唯一不改
   可见性的机械方案。
- part 文件头部写明"这是 PlayerController 的职责分片,成员见主文件"。
- 不改任何字段、方法签名与逻辑;提取纯逻辑时保持算法逐字符等价
  (测试锁定)。

## 执行顺序与理由

Task 1(models,最独立、收益直接)→ Task 2(api,机械)→
Task 3(settings_page,先在较小页面上验证"页面拆分"模式)→
Task 4(player_page,同模式套用到最大页面)→ Task 5(controller,
最需要判断力,放最后)→ 最终全分支 code review。

## 最终验收

- flutter analyze 0 issues;flutter test 全绿(数量 ≥ 基线)。
- 全分支 diff 审查: 无逻辑改动混入;各文件行数显著下降
  (music_models ≤50 行 barrel;music_api 壳类 ≤400 行;
  各页面主文件 ≤1200 行;player_controller 主文件 ≤800 行)。
- 账本(.superpowers/sdd/progress.md)记录 Round 5 各任务与 Minor 项。

## 执行偏差(实际采用)

- **Task 2**: 计划写 extension 拆分;实际 extension 静态派发会破坏 ~12 个
  `implements MusicApi` Fake 测试(desktop_rank_detail_test 实验实证 4/4
  失败后回退),改为领域 mixin + part 文件(方法保持真实实例成员,动态派发
  与 Fake 兼容),经任务审查验证等价。
- **Task 5**: 计划写"方法体按职责分到 part 文件";Dart 类体不能跨编译单元,
  不可编译,改用 Task 2 同型方案(基类 `_PlayerControllerBase` + 6 职责
  mixin),经任务审查验证等价。
