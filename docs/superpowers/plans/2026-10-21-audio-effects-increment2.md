# 音效增量 2：预设扩容调优 + 卡片列表 + 车机适配

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户真机反馈三点——预设少、曲线听感一般、选择入口体验差且车机没适配。本轮：预设 12→16 并按公开曲风调音指引重调曲线；音效档案 4→6（3D丽音/纯净人声/现场演唱会/深夜舒缓命名对齐酷狗习惯）；预设选择从列表弹层改为卡片网格；音效页做车机横屏适配（推入内容区 + 横屏双栏）。

**Architecture:** 数据层抽到独立文件（模型类 + 两张 const 表），PlayerController 用 export 保持既有引用不变；UI 仍是单文件 audio_effects_sheet.dart 内改弹层为卡片网格；车机适配复刻 search_page._openIdentify 的内容区推入模式。

**Tech Stack:** Flutter/Dart，无新依赖。

## Global Constraints

- 分支 `feat/audio-effects-profiles` 继续；不 push、不动版本号/CI。
- 提交信息遵循 `docs/commit-convention.md`；注释中文讲为什么。
- 每任务收尾：`flutter analyze` 无新增 + `flutter test` 全绿。
- 曲线与描述全部本仓自写：参考公开曲风调音指引（知乎/漫步者社区/一加社区等通用 dB 建议），**禁止**拷贝 GPL 仓库（V4A/JamesDSP/EasyEffects-Presets）的文件或逐字参数。
- Android 行为门控不变（桌面仅 Linux）；本轮不碰 vendored 包。

---

### Task 1: 预设/档案扩容与曲线调优（数据层）

**Files:**
- Create: `lib/models/audio_effect_presets.dart`（模型类 + const 数据表）
- Modify: `lib/controllers/player_controller.dart`（删除原类内定义，export 新文件的类，静态常量改为引用新表）
- Test: `test/controllers/audio_effect_profiles_test.dart`（数量断言 16/6，曲线完整性沿用）

**Interfaces:**
- Produces: `AudioEffectPreset`/`AudioEffectProfile` 类与新表；`PlayerController.equalizerPresets`（16 项）/`PlayerController.audioEffectProfiles`（6 项）签名不变，既有消费方零改动。

数据（毫贝尔，10 段 31..16k；调法注释写在每条曲线上，注明依据的公开指引要点）：

```dart
// 预设 16：平直/流行/摇滚/人声/低音/古典/电子/舞曲/爵士/金属/民谣/嘻哈/乡村/蓝调/R&B/柔和
kEqualizerPresets = [
  平直: 0×10
  流行: [0,100,250,350,300,150,100,150,250,250]       // 中频温和+轻V，人声不糊
  摇滚: [400,300,100,-150,-200,-100,200,400,450,450]  // 两端抬、中段让位，冲击力
  人声: [-250,-150,0,250,450,500,350,150,0,-150]      // 500-4k 主导，压低频避轰头
  低音: [800,700,500,250,0,-100,-150,-200,-250,-300]  // 低频主导、高频收
  古典: [300,250,150,0,0,0,100,200,250,300]           // 近平直+两端空气感
  电子: [650,500,150,-100,-150,0,300,500,600,700]     // 深低音+亮高频
  舞曲: [500,400,150,0,-150,-300,-150,150,350,450]    // 低频推、中频挖
  爵士: [250,200,100,0,100,150,100,150,250,250]       // 整体轻抬，中频乐器细节
  金属: [450,300,50,-200,-250,-150,150,350,450,500]   // 激进V，失真吉他线条
  民谣: [100,150,250,300,250,150,100,100,150,200]     // 中频木吉他/人声温润
  嘻哈: [650,550,300,50,-100,-100,100,250,400,450]    // 808 低频+高频咬字
  乡村: [200,250,200,50,-50,0,150,250,300,250]        // 中高频亮，班卓/人声
  蓝调: [200,250,150,50,100,200,250,250,200,150]      // 中频厚，吉他滑音
  R&B: [550,450,200,0,-100,-50,150,300,350,300]       // 低频氛围+人声区轻抬
  柔和: [0,0,50,100,200,250,200,100,-50,-150]         // 轻中频，压高频久听不累
]

// 档案 6（酷狗习惯命名；surround/bass 强度 0..1）
kAudioEffectProfiles = [
  全景环绕: desc 声场展宽+轻低音，空间感拉满; eq [200,150,50,0,-50,0,100,200,250,200]; bass 0.3; surround 0.85
  3D丽音: desc 均衡声场，细节通透氛围感; eq [150,100,50,0,100,100,50,100,150,150]; bass 0.2; surround 0.6
  超重低音: desc 低频大幅增强，节奏冲击力; eq [900,800,600,250,0,-100,-150,-200,-150,-100]; bass 0.95
  纯净人声: desc 中频突出，人声干净靠前; eq [-200,-100,50,250,450,550,400,150,0,-100]
  现场演唱会: desc 环绕声场还原现场氛围; eq [300,200,80,-80,-150,0,200,300,350,300]; bass 0.35; surround 0.6
  深夜舒缓: desc 压低高频，夜间久听不累; eq [-100,0,100,200,250,150,50,-50,-150,-300]; bass 0.15
]
```

注意：旧名「清澈人声→纯净人声」「现场氛围→现场演唱会」属改名；持久化按名字串匹配，旧存量名会自然落到非选中态（无迁移必要，不加代码）。

- [ ] 建模型文件（含类与两张表、调法注释）→ player_controller.dart 改为 `export '../models/audio_effect_presets.dart' show AudioEffectPreset, AudioEffectProfile;` 并删除原类定义，静态常量改引用 → 测试更新数量断言（16/6）→ analyze/test 全绿 → 提交 `feat(effects): 扩容音效预设与档案并按曲风指引重调曲线`。

### Task 2: 预设选择改卡片网格

**Files:**
- Modify: `lib/ui/widgets/audio_effects_sheet.dart`（`_showPresetPicker` 重做为卡片网格弹层）
- Test: `test/ui/widgets/audio_effects_page_test.dart`（对齐卡片选择器）

设计要点：弹层内两段——「音效」6 张档案卡（图标+名称+一行描述，2 列网格）、「均衡器预设」16 张紧凑卡（名称+10 段迷你曲线预览 CustomPaint，2 列或 3 列自适应宽）；选中卡主题色描边+角标；点选即应用并关弹层。卡片高度约 88-108，`GridView` 用 `shrinkWrap`+`NeverScrollableScrollPhysics` 嵌入外层 `ListView`，弹层整体可滚。迷你曲线 painter 画 10 点折线（正增益上行/负增益下行，中线基准），复用既有色语言。

- [ ] 实现 → 对齐/补 UI 测试（档案卡点选、预设卡点选、选中态角标）→ analyze/test 全绿 → 提交 `feat(effects): 预设选择改为卡片网格并附曲线预览`。

### Task 3: 车机横屏适配

**Files:**
- Modify: `lib/ui/widgets/audio_effects_sheet.dart`（页面横屏双栏布局；入口函数支持内容区推入）
- Modify: `lib/ui/player/landscape_player.dart`（音效入口改走内容区推入，复刻 `lib/ui/pages/search_page.dart:335-357` 的 `_openIdentify` 模式：`size.width > size.height && ThemeController.instance.carModeEnabled` → `rootNavigator: false` + `fullscreenDialog: false`）
- Test: `test/ui/widgets/audio_effects_page_test.dart`（横屏布局用例，参照 `test/ui/widgets/song_action_sheets_test.dart` 的形态切换测试做法）

设计要点：`AudioEffectsPage` body 在 `width > height` 时改双栏 `Row`——左栏 tabs+当前面板内容（Expanded），右栏固定宽（约 300-360）档案卡片纵列（车机主屏触达最常用的音效一击即达）；竖屏维持现有单栏。SystemUiOverlayStyle 与返回逻辑不动。其余入口（poster_player/player_top_bar/设置页）是竖屏/桌面场景，本轮不改。

- [ ] 实现 → 横屏/竖屏两个 UI 测试 → analyze/test 全绿 → 提交 `feat(effects): 音效页适配车机横屏双栏与内容区推入`。

### Task 4: 收尾

- [ ] `flutter analyze` + `flutter test` + `:app:compileImpellerDebugKotlin` 三门全绿 → 终审（一支子代理审 A..C 全部 diff）→ 修复 → clean 构建 impeller release arm64 测试 APK（`flutter build apk --release --target-platform android-arm64 --flavor impeller --dart-define=APP_RENDERER=impeller --dart-define=APP_ABI=arm64`，E 盘路径的 build_apk.bat 本机不可用）→ 汇报 APK 路径与听感测试点。
