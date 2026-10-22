# 音效页卡片化改版设计（卡片为主、调线深层化）

日期：2026-10-22
分支：feat/audio-effects-profiles（在 issue #1 音效特性之上迭代）
背景：现音效页（手机/车机）主界面是「启用开关 + 曲线 + 10 根频段推子」，预设卡片藏在「预设」按钮的底部弹层里；车机横屏左栏仍是推子、右栏才是档案快捷卡。但多数用户只需要选现成效果，手动调线是少数派需求。本次把层级倒转：主界面即卡片选择，手动调线下沉到推入的深层页。

## 用户已拍板的决策

1. 保留顶部「音效｜增强」双 tab：音效 tab 放卡片网格，增强 tab 维持现状。
2. 关闭状态用「关闭」卡片：音效段第一张卡，点击关 EQ+低音+环绕三件套，全关时该卡选中；点任何效果卡/预设卡自动开启 EQ（即点即响）。

## 主页面

- AppBar 只留 ✕ 关闭，去掉「保存」按钮——卡片即点即生效，无保存语义。
- 顶部胶囊 tab 不变（`_EffectTabs`：音效｜增强）。
- 音效 tab 变为可滚动的卡片网格，复用现有卡片语言（`_SelectableCard` 主题色描边 + 对勾角标）：
  - **音效段**：「⏻ 关闭」卡 + 6 张音效档案卡（`_ProfileCard`，图标+名称+描述）。点选即应用、不关页。
  - **均衡器预设段**：16 张预设卡（`_PresetCard`，名称+迷你曲线）+ 末尾「✎ 自定义均衡器」入口卡——实时预览当前曲线，presetName=「自定义」时选中。
- 列数自适应：竖屏/窄屏 2 列；宽屏（≥600，平板/车机横屏/桌面）3 列。
- 底部弹层预设选择器（`_showPresetPicker`）整体删除。

## 深层页（自定义均衡器）

- 从「自定义」入口卡推入，内容即现 `_EqualizerPanel` 主体：启用开关（快速 A/B 用）、曲线预览、频段推子、重置。
- 去掉「预设」按钮（预设已上移主界面）；重置保留单按钮。
- 推入最近 Navigator（与主页面同语义，车机仍只占内容区）。

## 车机横屏

- 取消「左推子 + 右 340px 档案快捷栏」双栏（`_ProfileQuickPane`/`_ProfileQuickCard` 删除）——卡片网格本身就是快捷选择，横屏整幅铺开按宽度自适应列数。

## 控制器行为

- `applyEqualizerPreset`：应用前 `equalizerEnabled = true`（现只在已开启时生效，卡片化后点卡必须即点即响）；持久化含 enabled 位。
- 新增 `disableAllAudioEffects()`：一次性关 EQ + 低音 + 环绕，单次 notify，供「关闭」卡调用。
- 手动调 band → presetName=「自定义」语义不变；档案应用（`applyAudioEffectProfile` 已自动开 EQ）不变。

## 范围与不做

- 改：`lib/ui/widgets/audio_effects_sheet.dart`（主体重构）、`lib/controllers/player_controller.effects.dart`（上述两点）、`test/ui/widgets/audio_effects_page_test.dart`（重写断言）。
- 不动：预设/档案数据层（`audio_effect_presets.dart`）、增强面板、桌面 mpv af 链、Android 原生通道、五处入口调用点。
- 平台不支持时的 `_UnsupportedView` 占位保持不变。
