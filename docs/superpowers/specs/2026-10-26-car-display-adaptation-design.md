# 车机显示微调（issue #4 适配版）

日期：2026-10-26
分支：`feat/car-display-adaptation`（自 main）
来源：https://github.com/bamboostrip/shiyin-music/issues/4

## 背景与问题

车机屏幕碎片化是既定事实，现有「车机模式」只做了布局分支（横屏左侧播放面板 +
顶栏）与固定 1.12 倍文字，无法覆盖：

1. **分辨率 / DPI 差异**：同一套 UI 在 1024×600 低分屏与 1920×720 高分屏上，
   一个偏大、一个偏小。上游同类反馈（kgka_Music_hl#128）已确认这是普遍痛点。
2. **悬浮状态栏 / 底部悬浮条**：后装车机的状态栏多由 launcher / 第三方 SystemUI
   以独立窗口悬浮绘制，不属于本应用窗口的 `WindowInsets`，Flutter
   `MediaQuery.padding` 为 0，但内容实际被压住；原生也没有跨窗口查询 API
   （本项目 `MainActivity` 的车机判定只认 `FEATURE_AUTOMOTIVE`，国产定制 AOSP
   车机通常不声明该 feature）。**手动留白是这种情况唯一的通用解**。
3. **触控目标偏小**：车机观看/操作距离远，固定尺寸按钮点按容错低，而现有
   「字体大小」只放大文字、不放大控件，也不能让网格重排。
4. **既有双计隐患**：车机顶栏手动加了 `paddingOf.top` 让出状态栏，其下内容页
   的 `SafeArea` 会再消费一次 top padding（车机 inset 常为 0，长期未暴露）。

## 目标

1. 车机模式内提供**界面缩放** 5 档（0.8 / 0.9 / 1.0 / 1.15 / 1.3）：收缩/放大
   的是布局视口本身，网格列数、控件与文字一起变化（不是拉伸，也不是只放大字）。
2. 提供**顶部 / 底部安全留白** 0–100 dp，按截图/目测高度手动给悬浮栏让位。
3. 提供「恢复默认车机显示」；所有参数默认中性（1.0 / 0 / 0），老用户升级无感。
4. **普通用户与桌面端零影响**：仅 `carModeEnabled`（桌面恒 false）且参数非默认
   时才介入；关闭车机模式或默认参数时 widget 树与改造前完全一致。

## 非目标（本分支刻意不做）

- **不锁横屏**：用户明确自有车机可横竖屏切换，锁横屏会伤竖屏用户；现有
  `applyOrientations` 的「允许旋转」语义保持不变。
- **不做沉浸式全屏**：只能隐藏 SystemUI 系统条，对 launcher 悬浮条无效；且与
  播放页三处无条件 `edgeToEdge` 冲突，需要统一系统 UI 同步器，单独评估。
- **不做 60%–160% 连续滑杆**：60% 时 48dp 触控目标只剩 28.8dp、正文 6–8sp，
  不合规且难用；连续拖动会每帧触发全树 relayout，车机 SoC 掉帧。档位化同时
  保证每一档都可做回归。
- **不重做断点体系**（留待后续，见「已知取舍」）。

## 方案

### 1. `ThemeController`（lib/controllers/theme_controller.dart）

- 新增 SharedPreferences 键：`theme.car_display_scale` / `theme.car_margin_top` /
  `theme.car_margin_bottom`。
- `carDisplayScaleOptions = [0.8, 0.9, 1.0, 1.15, 1.3]`，默认 1.0；
  `carMarginMax = 100`。
- `load()`：缩放走白名单（非法值回落 1.0），留白 `clamp(0, 100)`（防手改
  prefs 把界面调坏）。
- getter 做桌面门控（与既有 `carModeEnabled` 同款）：桌面恒 1.0 / 0 / 0，
  移动端残留值不劫持 PC 布局。
- `setCarDisplayScale` / `setCarMarginTop` / `setCarMarginBottom` /
  `resetCarDisplay` / `hasCustomCarDisplay`。

### 2. `CarDisplayViewport`（lib/ui/car_display_viewport.dart，核心）

**虚拟 MediaQuery 折算**（`s` = 缩放，`mt/mb` = 物理留白）：

```text
size          = (W/s, (H - mt - mb)/s)
devicePixelRatio = realDpr * s          // 保证 size × dpr = 物理像素
viewPadding   = (max(0, realViewPadding - margins)) / s
viewInsets    = (max(0, realViewInsets  - margins)) / s   // 键盘同样折算
padding       = max(0, viewPadding - viewInsets)         // 保持框架不变量
textScaler    = 原值（不乘缩放）
```

**渲染结构**：自定义 `RenderProxyBox`：

- `performLayout`：自身 `size = 父约束`（整屏）、child 用 `BoxConstraints.tight`
  按虚拟尺寸布局；
- `paint`：`pushTransform(translate(0, mt) × scale)`，`filterQuality` 保持 null
  （重绘而非位图采样，放大不糊）；
- `hitTestChildren`：`addWithPaintTransform`（框架自动逆变换）；
- `applyPaintTransform`：前向矩阵，保证 `localToGlobal` / 语义 / 焦点一致。

**为什么不能直接 `Transform.scale` + `SizedBox`**：`RenderBox.hitTest` 先过父级
bounds 检查，普通写法在 >100% 时放大后的溢出区会「看得见点不到」，<100% 时
`SizedBox` 又被父约束夹回整屏、列数不重排。本结构自身尺寸恒为整屏，规避该问题。

**启用策略**：`CarDisplayViewport.maybe(enabled, scale, top, bottom, child)`——
未启用或参数全默认时直接返回 child，不引入任何额外层级。

### 3. 接线（lib/main.dart）

`MaterialApp.builder` 中，在既有全局 `textScaler`（字体档位）之后、`_AppBackground`
（全屏背景）之内挂 `CarDisplayViewport.maybe`：背景图/主题底色仍铺满整屏，
只有内容让位与缩放；`enabled` 传 `_theme.carModeEnabled`（桌面恒 false）。

### 4. 车机顶栏双计修复（lib/ui/pages/app_shell.dart）

车机分支顶栏之下的内容区包 `MediaQuery.removePadding(removeTop: true)`：顶栏已
手动消费 `paddingOf.top`，内层 `SafeArea` 不应再消费一次。系统 inset = 0 时行为
不变；inset > 0 时不再多出一整条空白。

### 5. 设置 UI（lib/ui/settings/car_display_settings_section.dart）

「设置 → 车机显示」分节（仅移动形态 + 车机模式开启时出现，紧跟「个性化」）：

- **界面缩放**：底部弹窗 5 档单选（先 `pop` 再 apply，避免弹窗自身随缩放跳变）；
- **顶部 / 底部安全留白**：底部弹窗内 `Slider(0–100, divisions: 20)`，拖动只改
  本地值、`onChangeEnd` 才提交（避免拖动期间全树 relayout 卡顿），右侧实时 `NN dp`；
- **恢复默认车机显示**：默认态置灰，非默认时 `resetCarDisplay()` + Toast。

## 已知取舍与风险

1. **断点悬崖**：首页网格/横轨（840）、触屏侧栏（720）、`isUltraWide`（1150/600）
   等绝对阈值按虚拟宽度判断，极端档位（如 1024 宽 > 121.9% 时）可能切换布局
   模式。档位离散已把影响限制为「切换档位瞬间」；彻底解决需把这些阈值改为按
   物理基准宽度判断，属后续独立改动。
2. **文本输入**：`EditableText` 选区/候选栏混用虚拟 `MediaQuery` 与真实
   `View.of()` 数据，极端缩放下光标/候选栏可能偏移；车机通常无输入法，手机启用
   车机模式时需真机回归。
3. **封面解码**：封面按逻辑尺寸算解码档，130% 时理论上有轻微欠采样；如需可在
   解码尺寸上乘缩放，涉及车机图片缓存上限，暂不做。
4. **字体档位与缩放正交**：物理字号 = 系统字号 × 字体档位 × 车机文字倍数(1.12)
   × 缩放（几何变换自然产生），不做二次乘法进 `textScaler`。
5. **系统 inset 与留白叠加**：总让位 = `max(系统 inset, 手动留白)`（留白用于
   系统不上报悬浮栏的设备），不会双计。

## 测试

- `test/ui/widgets/car_display_viewport_test.dart`：虚拟 MediaQuery 折算、
  inset 扣减、默认恒等、虚拟尺寸布局、**放大后整屏可命中**、留白区不命中、
  `maybe` 未启用不加层级。
- `test/controllers/theme_controller_car_display_test.dart`：默认中性值、
  白名单/钳制、持久化与恢复默认、非法 prefs 回落、桌面门控。
- `test/ui/pages/car_display_integration_test.dart`：真实 `AppShell` 车机横屏 +
  1.3 倍 + 上下留白渲染无 FlutterError；档位切换重建不崩；车机模式关闭时视口不介入。
- `test/ui/settings/car_display_settings_section_test.dart`：分节瓦片、缩放选择、
  滑杆松手写入、恢复默认；两个既有 `_FakeTheme` 补全接口。

验证命令：

```text
flutter analyze
flutter test
```

## 真机验证清单

1. 车机横屏进入车机模式，设置 → 车机显示：5 档缩放逐档切换，文字/按钮/网格
   列数同步变化，无溢出、无「看得见点不到」。
2. 悬浮状态栏被压住时把顶部留白调到 20–60 dp，顶栏按钮完全露出；底部同理。
3. 留白与系统 inset 同时存在（手机/平板横屏）时不出现双倍空白。
4. 全屏播放页 / 歌词页在 130% 下控制按钮完整可见、可点。
5. 设置页自身在 80% 与 130% 下仍可操作，「恢复默认车机显示」可用。
6. 关闭车机模式后所有页面恢复原样（普通用户路径）。
7. 搜索/重命名等输入场景（若车机有输入法）候选栏与文字位置正常。
8. PC 桌面端行为完全不变（车机显示分节不出现）。
