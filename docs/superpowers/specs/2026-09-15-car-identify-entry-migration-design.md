# 车机听歌识曲入口调整设计规范 (Car Identify Entry Migration)

## 1. 概述与背景
车机（Car Mode）环境下，用户主要操作为触控交互。在先前的设计中，车机首页顶栏的搜索胶囊同时内置了「搜索」与「听歌识曲」两个触控区域，由于两者物理距离极近，用户在车机端点击搜索时极易误触听歌识曲。
此外，车机端听歌识曲实际使用频次相对搜索较低，因此将听歌识曲从车机首页顶栏移除，转移至车机端搜索页顶栏作为独立功能入口，既能保持功能完整，又能彻底避免驾驶与日常使用时的误触。

## 2. 交互与布局改造规范

### 2.1 车机首页顶栏 (`lib/ui/pages/app_shell.dart`)
- **组件目标**：`_buildCarTopNavBar` 中的搜索胶囊按钮。
- **调整内容**：
  - 彻底移除胶囊右侧的竖向分割条（`Container(width: 1, height: 18...)`）与 `Icons.graphic_eq_rounded` 听歌识曲按钮。
  - 将整个外层 `Container` 包装为纯粹的搜索点击区域，点击直接进入 `SearchPage`。
  - 保持 46px 高度与 23px 圆角（深色与浅色下的背景与描边样式不变），内边距调整为左右各 20px 对称居中，仅保留 `Icons.search_rounded` 图标与「搜索」文案。

### 2.2 车机搜索页顶栏 (`lib/ui/pages/search_page.dart`)
- **组件目标**：`_buildCarSearchHeader`。
- **布局顺序**：
  ```text
  [ < 返回按钮 (IconButton) ]
  [ 搜索输入框 (Expanded, 46px 高) ]
  [ 🎵 识曲按钮 (46px 高胶囊, if isSupported) ]
  [ 搜索按钮 (46px 高胶囊) ]
  ```
- **按钮样式与规范**：
  - 使用 `FilledButton.tonalIcon`，高度固定 46px，圆角为 23px，与相邻的「搜索」按钮及搜索框等高对齐。
  - 间距：搜索框与识曲按钮之间间距为 12px，识曲按钮与搜索按钮之间间距为 10px。
  - 图标采用 `Icons.graphic_eq_rounded`，文字采用「识曲」（字体粗体 15-16px）。
  - 点击响应：绑定现有的 `_openIdentify(context)` 方法，内部已包含 `IdentifyService.tryConsumeEntry()` 双击防抖与识别页打开逻辑。
  - 平台兼容：通过 `if (IdentifyService.isSupported)` 进行守卫，不支持录音采集的平台自动不渲染该按钮。

## 3. 自动化测试保障 (`test/ui/widgets/identify_entries_test.dart`)
1. **车机首页顶栏测试**：
   - 验证车机模式下的首页导航栏只包含「搜索」，不包含 `Icons.graphic_eq_rounded`。
2. **车机搜索页测试**：
   - 模拟车机模式（横屏且 `carModeEnabled = true`），验证 `SearchPage` 顶栏存在「识曲」按钮（`Icons.graphic_eq_rounded` 与文字「识曲」）。
   - 验证点击该按钮触发识别流程或防抖处理。
3. **回归验证**：
   - 确保手机端搜索页、品牌 Logo 入口，以及 PC 桌面端顶栏识曲入口的测试全部保持通过。
