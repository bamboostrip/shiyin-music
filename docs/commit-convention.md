# 提交信息规范

> 本规范约束 `main` 分支所有提交（含 AI 助手生成的提交）。
> 目标就是截图里 `08cc01d` 那样：首行一句话讲清一件事，正文一条 bullet 讲清一个改动。

---

## 一、标准格式

```text
<type>(<scope>): <一句话，只讲一件事>

- 改了什么 + 为什么，各自一条 bullet
- 第二个改动另起一条
- 测试/验证结论单独一条
```

对照实例（`fix(car): 识曲页推入内容区导航，保留左侧常驻播放面板`）：

```text
fix(car): 识曲页推入内容区导航，保留左侧常驻播放面板

- 车机横屏下识曲页此前推到根 Navigator 全屏展示，盖住左侧 CarLeftPlayerPanel
- 与桌面端模式一致改为推入内容区 Navigator，仅占右侧内容区
- 手机竖屏仍全屏路由，由调度层按运行形态自动切换
- Android 返回键经 PopScope 先 pop 内层导航，可正常从识曲页返回搜索页
```

## 二、首行规则

1. **只讲一件事**：禁止用 `+`、`、`、`与` 在首行堆多个改动。
   `创建歌单键盘错位+播放历史顶栏穿透与清空弹窗统一` 就是反例——这是两次提交。
2. **30 字以内**，中文陈述句，不加句号。
3. `type(scope)` 小写英文，冒号后一个空格，格式为 `type(scope): 中文`。

## 三、正文规则

1. **bullet 列表，每条一个改动**，`- ` 开头，不写散文段落。
2. 每条 = **改了什么 + 为什么**（一句话讲完）。根因分析压缩成一条，不写小作文；
   冗长的排查过程属于聊天记录，不属于提交信息。
3. 测试与验证结论单独成条（如 `相关套件 174 条全过`、`需重装 APK 真机验证桌面歌词`）。
4. 无正文可写的纯单行修改（如 `fix(ci): Linux deb 运行期依赖补 libnotify4`），
   允许省略正文；但凡首行讲不全，就必须写 bullets，不要把解释塞进首行。

## 四、一事一提交

- 不相关的两个修复（即使同一天做）必须分两次提交，各自走一遍"首行 + bullets"。
- 同一页面的同类 UI 收敛（如顶栏背景 + 同页弹窗换肤）可合一，但首行只讲主题，
  两个改动分 bullet 写清。

## 五、`type` / `scope` 取值

`type`（按本仓库实际使用）：

| type | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | 缺陷修复 |
| `perf` | 性能优化 |
| `refactor` | 重构（无行为变化） |
| `test` | 只动测试 |
| `style` | 纯样式/排版 |
| `docs` | 只动文档 |
| `chore` | 构建/依赖/杂项 |
| `release` | 发版提交 |

`scope`（按模块，已出现过的值优先复用，不够再新建）：

`car` `dialog` `notification` `player` `desktop` `lyrics`（桌面歌词）
`search` `settings` `ui` `playlist` `like` `loudness` `ci`
`automotive` `update` `widget(s)` `song-row` `tray` …

## 六、反例改写

`a1b2a31` 原首行把两件事拼在一起，应该拆成两笔：

```text
fix(dialog): 创建歌单 dialog 去掉双倍键盘避让

- showDialog 外层 AnimatedPadding 与 Dialog 内部 viewInsets 避让重复，双倍吃掉垂直空间
- 键盘弹起时内容约束被压到 0<=h<=62，按钮溢出画到白卡外，删掉外层包裹
- 补键盘回归测试 test/ui/pages/create_playlist_dialog_keyboard_test.dart
```

```text
fix(history): 播放历史顶栏穿透修复，清空弹窗统一语言

- SliverAppBar 无背景色（全局 AppBarTheme 透明），歌曲上滑从标题下透出，加 surface 背景
- 清空确认迁到 AppDialogShell + 双药丸，与歌单删除/已下载清空同语言
```

## 七、给 AI 助手的检查清单

生成 `git commit -m` 之前逐条确认：

1. 首行有没有 `+` / `、`连接的第二个改动？有就拆。
2. 首行超 30 字？超就把细节下放到 bullets。
3. 正文是不是散文段落？是就改写成 `- ` bullets。
4. bullets 里有没有测试/验证结论？没有就补。
