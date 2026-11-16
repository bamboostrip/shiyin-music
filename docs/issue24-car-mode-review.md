# issue #24：车机模式「自己关掉」与左侧面板偏窄——根因定案与修复

日期：2026-11-16
来源：<https://github.com/bamboostrip/shiyin-music/issues/24>
用户设备：**Flyme Auto 2.3 / Android 11（API 30）**，品牌 `GEELYGALAXY / SiEngine`，
型号 `se1000_p171_slave_car`，屏幕 **2560×1600**，应用窗口 **2560×1440**（设备信息页截图）。

---

## 一、结论

| 问题 | 根因 | 状态 |
|---|---|---|
| 车机模式「有时候自己变回关闭」 | **不是 Flyme 不认车机**：Flyme Auto 明确声明了 `FEATURE_AUTOMOTIVE`（日志里 `isAutomotiveDevice=true`）。真正原因是 **audio_service 在 Activity attach 之前就执行了 Dart 入口**，`MainActivity` 里注册的 `shiyin_music/device` 通道当时还不存在 → 车机检测抛 `MissingPluginException` → 判成「不是车机」；而**自动判定结果从不落盘**，于是每次冷启动都重新赌一次，赌输车机模式就显示为关闭 | ✅ 已修 |
| 左侧面板窄、封面/按钮小 | 面板宽度写死 `320/380`，与屏幕多宽无关：1707 逻辑宽（2560×1600 / dpr≈1.5）上只占 22%，2560 上只有 15% | ✅ 已修 |

**关键认知**：`car_mode_enabled` 只有用户手动拨开关时才会写盘。用户这台设备是
`FEATURE_AUTOMOTIVE=true` 的车机，首次启动本该自动开启并「记住」，但因为判定没跑出来，
默认值退回关闭，而且这个「关闭」**也没写盘**——于是下一次启动又从头判定一次。
用户看到的"时好时坏"完全取决于那一次启动通道有没有就绪。

---

## 二、证据链（issue #22 里用户贴的日志）

对同一台车机的 9 次启动做对比，规律非常干净：

| 启动时间 | `carModeEnabled` | `isAutomotiveDevice` | 自定义通道 `MissingPluginException` |
|---|---|---|---|
| 11-11 12:51 | **false** | **false** | ✅ 有（deep_link / local_music / SuperLyric） |
| 11-11 14:06 | true | true | ❌ 无 |
| 11-11 15:08 / 15:40 / 16:18 / 17:04 | true | true | ❌ 无 |
| 11-12 17:13 | **false** | **false** | ✅ 有（同上三条） |
| 11-12 18:02 / 11-13 15:48 | true | true | ❌ 无 |

「车机模式是关闭的」的那两次启动，**恰好**是 `shiyin_music/*` 自定义通道全部抛
`MissingPluginException` 的两次：

```
2026-11-11T12:51:55.860 [INFO] [SYNOTIF] 通知渠道定向：channelId=...playback_phone
                                     carModeEnabled=false isAutomotiveDevice=false
2026-11-11T12:51:55.981 [ERROR] [SuperLyric] registerPublisher: MissingPluginException
2026-11-11T12:51:55.993 [ERROR] [DeepLink] 获取冷启动链接失败（忽略）: MissingPluginException(
                                     No implementation found for method getInitialLink on channel shiyin_music/deep_link)
2026-11-11T12:51:55.994 [ERROR] Error checking audio permission: MissingPluginException(
                                     No implementation found for method hasPermission on channel shiyin_music/local_music)
```

同一会话稍后（17:21）`registerPublisher -> false`——说明 Activity 之后 attach 了、
通道补注册成功，但**启动时那一次检测已经永久错过了**。

### 机制（audio_service 0.18.19）

```java
// AudioServiceActivity.java
@Override
public FlutterEngine provideFlutterEngine(Context context) {
    return AudioServicePlugin.getFlutterEngine(context);   // ← 内部已 executeDartEntrypoint()
}

// AudioServicePlugin.java:70-113
flutterEngine = new FlutterEngine(context.getApplicationContext());
...
flutterEngine.getDartExecutor().executeDartEntrypoint(DartEntrypoint.createDefault()); // Dart 先跑
FlutterEngineCache.getInstance().put(flutterEngineId, flutterEngine);
return flutterEngine;   // 之后 FlutterActivity 才会调用 configureFlutterEngine 注册自定义通道
```

所以：**Dart 入口与 `configureFlutterEngine` 是竞争关系**。车机 SoC 偏慢、
或进程由音频服务先拉起来时，Dart 常常抢在前面 → 所有启动期的自定义通道调用失败。
这不只影响车机模式，同一批日志里还连带丢掉**冷启动 DeepLink**、**本地音乐权限检查**、
**SuperLyric 注册**——这也是「Flyme 车机问题特别多」观感的一部分成因。

---

## 三、已实施的修复

### 1. 检测「问不出来」不再等同于「不是车机」

`lib/services/device_info_service.dart`：`Future<bool> isAutomotive()` → `Future<bool?>`
（`null` = 通道未就绪/超时/抛错），并加 800ms 超时。

### 2. 自动判定结果落盘 + 分离「用户选择」与「自动判定」

`lib/controllers/theme_controller.dart`：

- 老键 `theme.car_mode_enabled` 语义不变（**用户显式选择**，存在即优先）；
- 新键 `theme.car_mode_auto_resolved` 记录**自动判定结果**，判定成功即落盘；
- 生效值 = `显式选择 ?? 自动判定 ?? 关闭`；
- `detectAutomotive` 未拿到结果时置 `automotiveDetectionPending`，**不落盘、不判死**。

这样：判定过一次是车机 → 之后任何一次启动都不会因为通道没就绪而回退，
用户手动关掉也永远优先于自动判定。

### 3. 首帧后 / 回前台补判

- `main()` 在 `runApp` 之后 `unawaited(recheckAutomotiveIfPending())`（**不阻塞启动**）；
- `_ShiyinAppState.didChangeAppLifecycleState(resumed)` 再补一次；
- 补判成功 → 落盘 + `notifyListeners()` → 界面自动切到车机布局，用户不用再手动开。

### 4. 写盘失败不再静默

`setCarModeEnabled` 改为 `Future<bool>`，失败重试一次，仍失败则
`设置 → 个性化` 弹「车机模式设置未能保存，重启后可能恢复原状」。

### 5. 诊断补齐

- 启动日志新增一行：
  `[CAR] 车机模式启动判定：carMode=… explicit=… auto=… automotive=… pending=…`
- `AppLogService` 诊断头新增 `Screen : 2560x1440 @1.50x → 1707x960 dp`
  （issue #24 排查时正是缺这一行，只能让用户另拍设备信息页）。

### 6. 左侧面板：按比例 + 内部等比放大

`lib/ui/widgets/car_left_player_panel.dart`：

```text
panelWidth = clamp(min(窗口宽 × 0.33, 可用高 × 0.62), 320, 780)
scale      = clamp(min(panelWidth / 380, 可用高 / 720), 0.92, 2.0)
textScale  = min(scale, 1.45)              // 封面/按钮全额放大，文字封顶 1.45
封面上限   = min(面板内宽, 可用高 × 0.40)   // 旧值：固定 280
```

面板内 padding、控制条高度/圆角、播放键/按钮/图标、歌名/副标题/品牌行/时间字号、
间距、进度条粗细全部乘 `scale`（字号乘 `textScale`）。

**改造前后对照（逻辑像素）**：

| 窗口 | 面板宽（旧 → 新） | 面板占比 | 封面（旧 → 新） | 封面占宽 | 播放键 | 歌名字号 |
|---|---|---|---|---|---|---|
| 1024×600 | 380 → 338 | 37% → 33% | 260 → 240 | 23% | 64 → 59 | 18 → 16.6 |
| **1280×720** | 380 → 422 | 29.7% → **33%** | 280 → 288 | 21.9% → 22.5% | 64 | 18 |
| **1707×960**（用户设备 dpr≈1.5） | 380 → **563** | 22% → **33%** | 280 → **384** | 16.4% → **22.5%** | 64 → **85** | 18 → **24** |
| 2048×1152（若 dpr≈1.25） | 380 → 676 | 18.6% → 33% | 280 → 461 | 22.5% | 64 → 102 | 18 → 26.1 |
| 2560×1440（若 dpr≈1.0） | 380 → 780 | 14.8% → 30.5% | 280 → 576 | 22.5% | 64 → 128 | 18 → 26.1 |
| 1280×480（矮横屏） | 380 → 320 | 29.7% → 25% | 192 → 192 | 15% | 68 → 63 | 18 → 16.6 |
| 2560×720（32:9 超宽矮屏） | 380 → 446 | 14.8% → 17.4% | 280 → 288 | 11.2% | 64 | 18 |

用户提到的参考是 QQ 音乐车机版：面板约占屏宽 **1/3**、封面约占 **22.5%**——
上表 1280/1707/2048/2560 四行都是这两个数，与 dpr 无关（比例式设计的好处）。

---

## 四、新增测试

- `test/controllers/theme_controller_car_mode_persistence_test.dart`
  - 车机首次安装默认开启且落盘
  - **通道未就绪 → 未知、不落盘 → 补判成功后自动开启**（并断言确实 `notifyListeners`）
  - 已落盘判定不因下次检测失败而回退
  - 用户显式选择优先于自动判定（不会被自动结果翻盘）
  - **老用户手动开过（老键=true）+ 检测失败：保持开启**
  - 桌面形态恒关闭、非待判时补判为空操作
  - **递增重试：通道晚几次才就绪也能补判成功**
  - **补判链不会并发叠加（首帧与回前台同时触发）**
- `test/ui/widgets/car_left_player_panel_test.dart`
  - 面板宽度按比例（1280→422 / 1707→563），不再是固定 380
  - 小屏 320 下限、超宽屏收口
  - 封面随屏幕放大且不超出面板
  - 矮横屏 1280×480 不溢出
  - **1707×960 + 系统字号 1.3 不溢出**（封面放大后最容易溢出的一档）

`flutter analyze` 无问题；`flutter test` 全量 **1936 passed / 1 skipped**。

---

## 五、遗留与后续

1. **同一类通道竞态的其他受害者**：冷启动 `shiyin://` DeepLink、本地音乐权限检查、
   SuperLyric 注册在「Dart 抢先」的那次启动里同样会失败。建议后续给自定义通道调用
   抽一层「等通道就绪」的重试助手，一并收口（本次只修车机判定，避免扩大改动面）。
2. **补判窗口（0 / 0.4 / 0.8 / 1.6 / 3.2 / 6.4 秒，共约 12 秒）**：引擎由音频服务
   在**没有 Activity** 时先跑起来（车机开机自启/后台续播）时，通道要等用户真正打开
   界面才注册；这种情形下 `resumed` 未必回调（引擎启动时生命周期已是 resumed，状态
   没变不会通知 observer），所以用递增重试覆盖「界面晚挂上来」。仍失败的下次启动读
   prefs 里的落盘结果；回前台时也会再起一条补判链（带 in-flight 保护，不叠加）。
3. **通知渠道仍是启动时定向**：补判成功的那一次会话里，车机模式已切过去，但通知渠道
   仍按启动时的判定选了手机渠道；下次启动即恢复正常。属可接受的一过性代价。
4. **竖屏车机**：`横屏 && carModeEnabled` 的门槛未动，竖屏车机仍走手机布局——
   需要独立的竖屏车机布局，另行排期。
5. **非 AAOS 车机**（不声明 `FEATURE_AUTOMOTIVE` 的国产定制机）仍默认关闭，
   需用户手动开启一次；是否加多信号识别（`UiModeManager` / `ro.build.characteristics`）
   需权衡「手机放车充都会误判」的代价，暂不动。

---

## 六、复查：本次改动自身的风险点（已逐项核对）

| # | 风险点 | 结论 |
|---|---|---|
| 1 | `ThemeController` 取值顺序把「用户显式选择」写成了可空值，可能被自动判定覆盖 | 显式选择存在时 `_applyAutomotiveResult` 不写 `_carModeAutoResolved`，且生效值 `explicit ?? auto ?? false`；老键 `theme.car_mode_enabled` 语义完全不变，升级零迁移 |
| 2 | 首次安装把「通道没就绪」误判成 false 并落盘，导致永久判成手机 | 只有 `bool` 结果才落盘；`null` 保持 pending，不写 `theme.car_mode_auto_resolved`（有用例锁定 `containsKey == false`） |
| 3 | 检测成功但界面不刷新 | 补判成功且状态有变化时调用 `notifyListeners()`；用例断言 listener 被调用 |
| 3b | 无 Activity 的引擎启动后，用户打开界面时 `resumed` 可能不回调（生命周期状态没变） | 补判改为递增重试（0/0.4/0.8/1.6/3.2/6.4s）+ 回前台再起一条链；`_recheckInFlight` 防止并发叠加（有用例） |
| 4 | 桌面/手机误开车机布局 | 桌面 `carModeEnabled` 恒 false（原门控保留）；手机检测为 false → 落盘 false，行为与改造前一致 |
| 5 | 封面尺寸链用 `clamp` 但上下界是推导值，极端窗口会抛 `ArgumentError` | 已改成等价的 `min/max` 组合：最坏只是封面偏小，不会抛异常 |
| 6 | 封面放大后 + 系统大字号导致 Column 溢出 | `fixedContentHeight` 随 scale 同步放大；新增 1707×960 × textScaler 1.3 用例；1280×480/1024×600/985×554 逐档验算仍有余量 |
| 7 | 面板变宽挤压右侧内容区，触发网格断点变化 | 1280×720 内容区 857（仍 2 列，与改造前 899 同档）；1024×600 内容区 685（从 1 列变 2 列，属改善）；1707×960 内容区 1143（仍 3 列） |
| 8 | 32:9 超宽矮屏面板过宽、封面被压扁 | 增加「可用高 × 0.62」收口 + `scale` 同时受高约束，2560×720 下封面回到 288 而不是 24 |
| 9 | `dart format` 带来的无关重排 | 仅 `main.dart` 回退为最小 diff；`car_left_player_panel.dart` 改动面大，顺带统一了格式 |
| 10 | 未做真机/整包验证 | `flutter analyze` + 全量单测通过；**建议打一个测试包在 Flyme 车机上验一次启动时序**（本次唯一无法用单测覆盖的部分） |
