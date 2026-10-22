import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/player_controller.dart';
import 'app_dialog.dart';

/// 打开「自定义音效」页。
///
/// 一律推入调用点最近的 Navigator：手机竖屏入口（挂在根 Navigator 的
/// 播放页）整屏展示；车机横屏/桌面的入口本身就挂在内容区 Navigator 上
/// （播放页/设置页），音效页自然只占内容区，常驻面板不被盖住。
Future<void> showAudioEffectsSheet({
  required BuildContext context,
  required PlayerController player,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => AudioEffectsPage(player: player)),
  );
}

class AudioEffectsPage extends StatefulWidget {
  const AudioEffectsPage({super.key, required this.player});

  final PlayerController player;

  @override
  State<AudioEffectsPage> createState() => _AudioEffectsPageState();
}

class _AudioEffectsPageState extends State<AudioEffectsPage> {
  var _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final player = widget.player;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.dark
            : Brightness.light,
      ),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
          title: const Text('自定义音效'),
        ),
        body: AnimatedBuilder(
          animation: player,
          builder: (context, _) {
            if (!player.isAudioEffectsSupported) {
              return _UnsupportedView(colorScheme: colorScheme);
            }

            // 主界面即卡片选择（音效档案 + 均衡器预设 + 自定义入口），
            // 手动调线在「自定义」卡推入的深层页；增强保持第二 tab。
            return Column(
              children: [
                _EffectTabs(index: _tabIndex, onChanged: _setTab),
                Expanded(
                  child: _tabIndex == 0
                      ? _EffectsCardPanel(player: player)
                      : _EnhancePanel(player: player),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _setTab(int value) {
    setState(() => _tabIndex = value);
  }
}

/// 顶部胶囊分段切换（音效/增强）：44 高整圆角胶囊，选中项为悬浮白丸 +
/// 主题色字，与搜索胶囊/药丸按钮同语言。
class _EffectTabs extends StatelessWidget {
  const _EffectTabs({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labels = ['音效', '增强'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Container(
        height: 44,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: isDark
              ? colorScheme.surfaceContainerHighest
              : const Color(0xFFF1F2F5),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            for (final entry in labels.indexed)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(entry.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: entry.$1 == index
                          ? (isDark
                                ? colorScheme.surfaceContainerLowest
                                : Colors.white)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(19),
                      boxShadow: entry.$1 == index
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      entry.$2,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: entry.$1 == index
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 音效 tab 主面板：卡片网格直选（酷狗式）。上段「关闭」+ 音效档案
/// 组合卡，下段带迷你曲线的均衡器预设卡 + 末尾「自定义」入口卡；点选
/// 即应用不关页。窄屏 2 列，宽屏（平板/车机横屏/桌面）3 列。
class _EffectsCardPanel extends StatelessWidget {
  const _EffectsCardPanel({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final crossAxisCount = MediaQuery.sizeOf(context).width >= 600 ? 3 : 2;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _sectionTitle(Theme.of(context), '音效'),
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 104,
          ),
          children: [
            _OffCard(
              selected: _isAllEffectsOff(player),
              onTap: player.disableAllAudioEffects,
            ),
            for (final profile in PlayerController.audioEffectProfiles)
              _ProfileCard(
                profile: profile,
                selected: player.equalizerEnabled &&
                    player.equalizerPresetName == profile.name,
                onTap: () => player.applyAudioEffectProfile(profile),
              ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(Theme.of(context), '均衡器预设'),
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            // 名称行实际高约 20，92 给非默认字号留防溢出余量。
            mainAxisExtent: 92,
          ),
          children: [
            for (final preset in PlayerController.equalizerPresets)
              _PresetCard(
                preset: preset,
                selected: player.equalizerEnabled &&
                    player.equalizerPresetName == preset.name,
                onTap: () => player.applyEqualizerPreset(preset),
              ),
            _CustomEqCard(
              selected: player.equalizerEnabled &&
                  player.equalizerPresetName == '自定义',
              levels: player.equalizerLevels,
              onTap: () => _openEqualizerEditor(context),
            ),
          ],
        ),
      ],
    );
  }

  /// 三件全关才让「关闭」卡选中：环绕不支持的平台（Windows）开关不
  /// 渲染，残留持久化 true 不参与判定。
  bool _isAllEffectsOff(PlayerController player) {
    final surroundOff =
        !(player.surroundEnabled && player.isSurroundSupported);
    return !player.equalizerEnabled &&
        !player.bassBoostEnabled &&
        surroundOff;
  }

  /// 推入最近 Navigator：与音效页自身同语义（车机上编辑页仍只占内容
  /// 区，常驻面板不被盖住）。
  void _openEqualizerEditor(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _EqualizerEditorPage(player: player),
      ),
    );
  }
}

/// 深层「自定义均衡器」页：主界面卡片化后手动调线下沉至此。预设选择
/// 在主界面卡片网格，这里只留启用开关（快速 A/B）、曲线预览、频段推子
/// 与重置。
class _EqualizerEditorPage extends StatelessWidget {
  const _EqualizerEditorPage({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('自定义均衡器')),
      body: AnimatedBuilder(
        animation: player,
        builder: (context, _) => _EqualizerPanel(player: player),
      ),
    );
  }
}

Widget _sectionTitle(ThemeData theme, String text) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
    child: Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
    ),
  );
}

/// 档案卡图标按名字映射（档案表在 models 层，不掺 UI 字段）；改名或
/// 新增档案时回退通用图形，避免空图标。
const _profileIcons = <String, IconData>{
  '全景环绕': Icons.surround_sound_rounded,
  '3D丽音': Icons.auto_awesome_rounded,
  '超重低音': Icons.speaker_rounded,
  '纯净人声': Icons.record_voice_over_rounded,
  '现场演唱会': Icons.stadium_rounded,
  '深夜舒缓': Icons.bedtime_rounded,
};

/// 选中态卡片外壳：与 _EffectTabs 同语言的浅底 + 14 圆角，选中时主题色
/// 描边并在右上角叠一枚对勾角标。Semantics(selected/button) 让读屏把
/// 整张卡播报为可选中按钮并带出选中态。
class _SelectableCard extends StatelessWidget {
  const _SelectableCard({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: isDark
            ? colorScheme.surfaceContainerHighest
            : const Color(0xFFF1F2F5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            width: 1.6,
            color: selected ? colorScheme.primary : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: child,
              ),
              if (selected)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    key: const ValueKey('effect-selected-badge'),
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      // 只圆内侧左下角；靠卡片外的一角由 Material 圆角裁掉。
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(13),
                      ),
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: colorScheme.onPrimary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「关闭」卡：一键停用 EQ/低音/环绕三件套（全关时选中）。停用只关
/// 开关不抹记忆，重新点效果卡即恢复——与档案卡同排版（图标+名+描述）。
class _OffCard extends StatelessWidget {
  const _OffCard({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SelectableCard(
      selected: selected,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.power_settings_new_rounded,
            size: 26,
            color: colorScheme.primary,
          ),
          const SizedBox(height: 8),
          Text(
            '关闭',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            '停用全部音效',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final AudioEffectProfile profile;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SelectableCard(
      selected: selected,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _profileIcons[profile.name] ?? Icons.graphic_eq_rounded,
            size: 26,
            color: colorScheme.primary,
          ),
          const SizedBox(height: 8),
          Text(
            profile.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            profile.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「自定义均衡器」入口卡：预设卡同排版（名 + 当前曲线实时预览），点入
/// 推入手动调线页。手动改过频段（presetName=「自定义」）后回主界面带
/// 对勾选中。
class _CustomEqCard extends StatelessWidget {
  const _CustomEqCard({
    required this.selected,
    required this.levels,
    required this.onTap,
  });

  final bool selected;
  final List<int> levels;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SelectableCard(
      selected: selected,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 16, color: colorScheme.primary),
              const SizedBox(width: 5),
              Text(
                '自定义',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            width: double.infinity,
            child: CustomPaint(
              painter: _PresetCurvePainter(
                colorScheme: colorScheme,
                levels: levels,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final AudioEffectPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SelectableCard(
      selected: selected,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            preset.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            width: double.infinity,
            child: CustomPaint(
              painter: _PresetCurvePainter(
                colorScheme: colorScheme,
                levels: preset.levels,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EqualizerPanel extends StatelessWidget {
  const _EqualizerPanel({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final config = player.equalizerConfig;
    final minDb = config.minMillibels / 100;
    final maxDb = config.maxMillibels / 100;

    return Column(
      children: [
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: const Text('启用均衡器'),
          subtitle: Text(
            player.equalizerEnabled ? player.equalizerPresetName : '关闭',
          ),
          value: player.equalizerEnabled,
          onChanged: player.setEqualizerEnabled,
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 64,
          child: CustomPaint(
            painter: _EqualizerCurvePainter(
              colorScheme: colorScheme,
              levels: player.equalizerLevels,
              min: config.minMillibels,
              max: config.maxMillibels,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 56,
                child: Padding(
                  padding: const EdgeInsets.only(top: 26, bottom: 44),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '+${maxDb.round()}dB',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '0dB',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${minDb.round()}dB',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(4, 4, 22, 18),
                  child: Row(
                    children: [
                      for (
                        var index = 0;
                        index < config.bands.length &&
                            index < player.equalizerLevels.length;
                        index++
                      )
                        _EqualizerBandSlider(
                          label: _frequencyLabel(config.bands[index].centerHz),
                          value: player.equalizerLevels[index],
                          min: config.minMillibels,
                          max: config.maxMillibels,
                          enabled: player.equalizerEnabled,
                          onChanged: (value) => player.setEqualizerBandLevel(
                            index,
                            value,
                            persist: false,
                          ),
                          onChangeEnd: (value) =>
                              player.setEqualizerBandLevel(index, value),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          // 与确认弹窗同语言的浅底药丸（46 高整圆角）：重置=回到平直。
          child: AppPillButton(
            label: '重置',
            foreground: isDark
                ? colorScheme.onSurface
                : const Color(0xFF1A1D24),
            background: isDark
                ? colorScheme.surfaceContainerHighest
                : const Color(0xFFF4F5F7),
            onTap: player.resetEqualizer,
          ),
        ),
      ],
    );
  }
}

class _EqualizerBandSlider extends StatelessWidget {
  const _EqualizerBandSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dbValue = value / 100;
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          SizedBox(
            height: 24,
            child: Text(
              dbValue == 0 ? '0' : dbValue.toStringAsFixed(1),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: enabled
                    ? colorScheme.onSurface
                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 10,
                    disabledThumbRadius: 10,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 18,
                  ),
                  activeTrackColor: colorScheme.primary,
                  inactiveTrackColor: colorScheme.outlineVariant,
                  thumbColor: enabled
                      ? colorScheme.primary
                      : colorScheme.outlineVariant,
                ),
                child: Slider(
                  value: value.toDouble(),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  onChanged: enabled ? (next) => onChanged(next.round()) : null,
                  onChangeEnd: enabled
                      ? (next) => onChangeEnd(next.round())
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: enabled
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EnhancePanel extends StatelessWidget {
  const _EnhancePanel({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bassPercent = (player.bassBoostStrength * 100).round();
    final surroundPercent = (player.surroundStrength * 100).round();
    final surroundEnabled = player.surroundEnabled;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.speaker_rounded, color: colorScheme.primary),
          title: const Text('低音增强'),
          subtitle: Text(player.bassBoostEnabled ? 'Bass $bassPercent%' : '关闭'),
          value: player.bassBoostEnabled,
          onChanged: player.setBassBoostEnabled,
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Text('Bass'),
            Expanded(
              child: Slider(
                value: player.bassBoostStrength,
                onChanged: player.bassBoostEnabled
                    ? (value) =>
                          player.setBassBoostStrength(value, persist: false)
                    : null,
                onChangeEnd: player.bassBoostEnabled
                    ? player.setBassBoostStrength
                    : null,
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '$bassPercent%',
                textAlign: TextAlign.end,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        // 环绕依赖平台滤镜支持（Windows 的 audio-only libmpv 无可用
        // 展宽滤镜），不可用时整块隐藏而非留死控件。
        if (player.isSurroundSupported) ...[
          const SizedBox(height: 26),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              Icons.surround_sound_rounded,
              color: colorScheme.primary,
            ),
            title: const Text('全景环绕'),
            subtitle: Text(surroundEnabled ? '环绕 $surroundPercent%' : '关闭'),
            value: surroundEnabled,
            onChanged: player.setSurroundEnabled,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Text('环绕'),
              Expanded(
                child: Slider(
                  value: player.surroundStrength,
                  onChanged: surroundEnabled
                      ? (value) =>
                            player.setSurroundStrength(value, persist: false)
                      : null,
                  onChangeEnd: surroundEnabled
                      ? player.setSurroundStrength
                      : null,
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '$surroundPercent%',
                  textAlign: TextAlign.end,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _EqualizerCurvePainter extends CustomPainter {
  const _EqualizerCurvePainter({
    required this.colorScheme,
    required this.levels,
    required this.min,
    required this.max,
  });

  final ColorScheme colorScheme;
  final List<int> levels;
  final int min;
  final int max;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: .56)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final zeroY = _levelToY(0, size.height);
    final zeroPaint = Paint()
      ..color = colorScheme.primary.withValues(alpha: .62)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), zeroPaint);

    if (levels.isEmpty) {
      return;
    }

    final linePaint = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var index = 0; index < levels.length; index++) {
      final x = levels.length == 1
          ? size.width / 2
          : size.width * index / (levels.length - 1);
      final y = _levelToY(levels[index], size.height);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  double _levelToY(int level, double height) {
    final span = (max - min).abs();
    if (span == 0) {
      return height / 2;
    }
    final normalized = ((level - min) / span).clamp(0.0, 1.0);
    return height * (1 - normalized);
  }

  @override
  bool shouldRepaint(covariant _EqualizerCurvePainter oldDelegate) {
    return oldDelegate.levels != levels ||
        oldDelegate.min != min ||
        oldDelegate.max != max ||
        oldDelegate.colorScheme != colorScheme;
  }
}

/// 预设卡迷你曲线：10 点折线，中线为 0dB 基准、正增益向上负增益向下。
/// 40 高内若按全局 dB 标定，摆幅只剩几个像素，故按卡内峰值归一化放大
/// 形状差异（全 0 的「平直」即贴中线）；配色沿用主曲线的主题色折线。
class _PresetCurvePainter extends CustomPainter {
  const _PresetCurvePainter({required this.colorScheme, required this.levels});

  final ColorScheme colorScheme;
  final List<int> levels;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final basePaint = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: .56)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), basePaint);

    var peak = 0;
    for (final level in levels) {
      if (level.abs() > peak) {
        peak = level.abs();
      }
    }
    // 峰值下限 1 防除零，全 0 曲线回落到中线。
    final scale = peak < 1 ? 1 : peak;

    final linePaint = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var index = 0; index < levels.length; index++) {
      final x = levels.length == 1
          ? size.width / 2
          : size.width * index / (levels.length - 1);
      final y = midY - (levels[index] / scale) * (midY - 2);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _PresetCurvePainter oldDelegate) {
    return oldDelegate.levels != levels ||
        oldDelegate.colorScheme != colorScheme;
  }
}

class _UnsupportedView extends StatelessWidget {
  const _UnsupportedView({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 42,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 14),
            Text(
              '当前平台暂不支持音效调节',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              'Android 与 Linux（系统 libmpv）播放时可使用均衡器、音效与'
              '低音增强。Windows 将随后续播放内核升级开放。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _frequencyLabel(int hz) {
  if (hz >= 1000) {
    final khz = hz / 1000;
    return khz == khz.roundToDouble()
        ? '${khz.round()}k'
        : '${khz.toStringAsFixed(1)}k';
  }
  return '$hz';
}
