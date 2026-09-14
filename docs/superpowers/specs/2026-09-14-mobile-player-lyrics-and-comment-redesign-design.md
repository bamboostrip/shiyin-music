# 移动端播放界面与歌词展示改版设计文档

本文档定义了移动端播放界面（海报页与歌词页）的重构方案，重点对齐 PC 端评论图标与角标规范，并将移动端歌词页全面重构为 QQ 音乐风格（逐字卡拉OK高亮、滑动中线准星定位与时间跳转播放、底部独立开关栏）。

---

## 1. 目标与范围

1. **评论按钮与角标对齐**：
   - 提取通用的 `PlayerCommentButton` 组件，包含 PC 端同款自绘 `CommentBubbleIcon`（圆角气泡 + 内部双点 + 底部尾巴 + 右上缺口）以及格式化评论数角标（`<1000` 原样展示，`1000~9999` 显示 `999+`，`>=10000` 显示 `xxw+`，会话级缓存）。
   - 在**海报页操作栏（`PosterActionRail`）**与**歌词页底部左侧**应用该组件。
2. **移动端原生逐字高亮歌词流**：
   - 替代现有的封闭三方库 `flutter_lyric`，构建专属的移动端原生触控歌词列表 `MobileLyricList`。
   - 采用 `KaraokeLinePainter` 实现 KRC 逐字（Syllable-level）平滑裁剪染色高亮；无逐字数据时平滑退化为整行加亮。
   - 播放中当前句放大（~28px, `FontWeight.w900`），未播行淡化（~20px, `FontWeight.w700`, `alpha: 0.35`）。
3. **滑动中线定位与快速跳转播放**：
   - 用户触控滑动时，暂停视口自动跟随。
   - 实时计算距离视口黄金对焦中线（~38%~42% 高度）最近的行，该行色彩加重（纯白加粗）。
   - 在该行右侧呈现 QQ 音乐同款时间胶囊 `[ ▶ mm:ss ]` 与居中对齐参考线。
   - 点击时间胶囊或歌词行立即跳转（Seek）并恢复播放。
   - 用户停止滑动 3.5 秒后，胶囊淡出，视口平滑滚回当前播放位置。
4. **QQ 音乐风格底部控制栏**：
   - 位于歌词页底部，包含：
     - 左侧：`PlayerCommentButton`（评论图标 + 动态数字）。
     - 右侧按钮组：
       - `[词]`：轻量弹出字号调节浮窗（取代旧版常驻的 `A-` / `A+` 按钮）。
       - `[译 on/off]`：独立开关中文翻译（有翻译数据时展示，状态小角标显示 on/off）。
       - `[音 on/off]`：独立开关罗马音/拼音（有音译数据时展示，状态小角标显示 on/off）。
       - 圆形【播放 / 暂停】按钮（带播放状态图标与触觉反馈）。
   - 持久化配置：歌词字号缩放比例、翻译默认开关、拼音默认开关本地保存。

---

## 2. 架构与组件设计

### 2.1 评论按钮组件化 (`lib/ui/player/player_comment_button.dart`)
- 从 `lib/ui/desktop/desktop_player_bar.dart` 中提炼独立的 `PlayerCommentButton`。
- 入参：`PlayerController player`、`Song song`、`Color iconColor`、`double size`（默认 20.0）、`ValueChanged<String>? onOpenComment`。
- 逻辑：
  - 读取或通过 `player.api.musicComments` 异步拉取首屏评论数，写入内存缓存 `_commentCountCache`。
  - 使用 `CommentBubbleIcon` 绘制气泡，有数字时展示右上角小角标。
  - 点击弹出 `CommentPage`（若为网易云/无评论则置灰）。

### 2.2 移动端触控歌词列表 (`lib/ui/player/mobile_lyric_list.dart`)
- 替代 `LyricViewport` 内部对 `flutter_lyric` 的调用。
- **状态管理**：
  - `_activeLyricIndex`：由 `player.positionListenable` 驱动更新。
  - `_userHolding`：标记用户是否正在拖动或滑动歌词。
  - `_focusedIndex`：滑动期间距离基准线最近的歌词行索引。
  - `_resumeTimer`：3.5 秒防抖定时器，超时后重置 `_userHolding` 并滚回当前行。
- **排版与逐字绘制**：
  - 使用 `ListView.builder` + `ScrollController`。
  - 活跃行使用 `LyricText`（内部由 `KaraokeLinePainter` 按 `position` 裁剪绘制高亮文字）。
  - 若 `showTranslation` 为 true 且该行包含 `translation`，在主文字下方渲染副文本。
  - 若 `showRomanization` 为 true 且该行包含 `romanization`，在主文字下方渲染音译文本。
- **准星与时间胶囊**：
  - 在当前视口 `targetY = viewportHeight * 0.40` 处浮动展示。
  - 当 `_userHolding` 时，计算 `_focusedIndex` 对应的行，在右侧渲染 `SeekPointerButton(timeText: formatDuration(line.time), onTap: ...)`。

### 2.3 歌词页底部操作栏 (`LyricBottomBar`)
- 组件结构：
  ```
  Padding(
    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: Row(
      children: [
        PlayerCommentButton(player: player, song: song),
        Spacer(),
        LyricPillButton(label: '词', onTap: _showFontSizeSheet),
        if (hasTranslation)
          LyricTogglePill(label: '译', isOn: showTranslation, onToggle: ...),
        if (hasRomanization)
          LyricTogglePill(label: '音', isOn: showRomanization, onToggle: ...),
        const SizedBox(width: 8),
        RoundPlayPauseButton(player: player),
      ],
    ),
  )
  ```
- `LyricTogglePill`：宽度自适应胶囊，文字右上角绘制小字体 `on` 或 `off`，激活态边框与文字微高亮。

---

## 3. 测试与验证策略

1. **单元/组件测试**：
   - 测试 `PlayerCommentButton` 评论数缓存与格式化逻辑。
   - 测试 `LyricTogglePill` 的状态切换与无音源/无翻译时的显隐。
   - 测试 `MobileLyricList` 在播放位置推进时的逐字高亮与活跃行计算。
   - 测试用户拖动期间自动跟随暂停、中线准星定位与 3.5s 恢复计时器。
2. **手工/UI 验证**：
   - 验证海报页评论按钮与歌词页评论按钮正常拉取并展示数字。
   - 验证有 KRC 歌词的歌曲在移动端正常逐字高亮。
   - 验证滑动歌词时中线对齐、右侧时间胶囊出现且点击可准确跳转播放。
   - 验证 `[译]` 和 `[音]` 独立开关及字号调整功能。
