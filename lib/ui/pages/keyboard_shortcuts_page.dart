import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../keyboard_shortcuts.dart';
import '../widgets/toast.dart';

/// 设置 →「键盘快捷键」（仅桌面形态，issue #31）。
///
/// 之前快捷键只写在更新日志/说明里，PC 设置页没有任何入口，用户既看不到
/// 现有键位、也没法改。本页给出完整清单并支持逐项改键：
///
/// - 播放类动作（7 项）可改，立即生效并写盘（[ShortcutController]）；
/// - 侧栏/搜索/打开播放页等骨架级按键为固定组合，只作展示；
/// - 系统级全局热键（窗口失焦也响应）需原生注册，本版本未接入，页面明示。
class KeyboardShortcutsPage extends StatefulWidget {
  const KeyboardShortcutsPage({super.key});

  @override
  State<KeyboardShortcutsPage> createState() => _KeyboardShortcutsPageState();
}

class _KeyboardShortcutsPageState extends State<KeyboardShortcutsPage> {
  @override
  void initState() {
    super.initState();
    // 正常已由 main 启动时 load；直接从深层路由进来时兜底一次（幂等）。
    unawaited(ShortcutController.instance.load());
  }

  Future<void> _edit(AppShortcutAction action) async {
    final controller = ShortcutController.instance;
    final binding = await showDialog<KeyBinding>(
      context: context,
      builder: (_) => _KeyCaptureDialog(action: action),
    );
    if (binding == null || !mounted) return;
    final stolenFrom = controller.conflictOf(binding, ignore: action);
    final applied = await controller.setBinding(action, binding);
    if (!mounted) return;
    if (!applied) {
      Toast.error(reservedBindingReason(binding) ?? '该组合不可用');
      return;
    }
    Toast.success(
      stolenFrom == null
          ? '${action.label} 已改为 ${binding.label}'
          : '${action.label} 已改为 ${binding.label}；「${stolenFrom.label}」'
                '现在未设置，请再给它指定一个键',
    );
  }

  Future<void> _resetAll() async {
    // 一键抹掉全部自定义键位且不可撤销，先确认一次。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复默认快捷键？'),
        content: const Text('所有自定义键位都会回到默认值，且无法撤销。'),
        actions: [
          TextButton(
            key: const ValueKey('shortcut_reset_cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('shortcut_reset_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ShortcutController.instance.resetAll();
    if (!mounted) return;
    Toast.success('已恢复默认快捷键');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

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
          title: const Text('键盘快捷键'),
          actions: [
            TextButton(
              key: const ValueKey('shortcut_reset_all'),
              onPressed: _resetAll,
              child: const Text('恢复默认'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: AnimatedBuilder(
          animation: ShortcutController.instance,
          builder: (context, _) {
            final controller = ShortcutController.instance;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _InfoBanner(
                  color: colorScheme.primary,
                  background: colorScheme.primaryContainer.withValues(
                    alpha: .35,
                  ),
                  text:
                      '快捷键在窗口内生效（输入框打字时自动让位）。'
                      '点右侧「修改」后按下新的组合即可换键，改完立即生效；'
                      '若该组合原本属于别的动作，原动作会显示「未设置」，'
                      '再给它指定一个键或点「恢复默认」即可。'
                      '系统级全局热键（窗口失焦/最小化也能控制播放）需要原生'
                      '热键注册，当前版本尚未支持。',
                ),
                const SizedBox(height: 20),
                const _SectionTitle('播放控制'),
                const SizedBox(height: 8),
                _Card(
                  children: [
                    for (final action in AppShortcutAction.values) ...[
                      if (action != AppShortcutAction.values.first)
                        const Divider(height: 1),
                      _ShortcutRow(
                        action: action,
                        bindings: controller.bindingsOf(action),
                        changed: !_sameBindings(
                          controller.bindingsOf(action),
                          defaultBindingsFor(action),
                        ),
                        onEdit: () => _edit(action),
                        onReset: () =>
                            ShortcutController.instance.resetAction(action),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 20),
                const _SectionTitle('固定快捷键'),
                const SizedBox(height: 8),
                _Card(
                  children: const [
                    _FixedShortcutRow(
                      label: '搜索',
                      hint: '打开全局搜索',
                      keys: 'Ctrl + F',
                    ),
                    Divider(height: 1),
                    _FixedShortcutRow(
                      label: '切换侧栏分区',
                      hint: '首页 / 排行榜 / 电台 / 我的音乐 / 已下载 / 设置',
                      keys: 'Ctrl + 1 ~ 6',
                    ),
                    Divider(height: 1),
                    _FixedShortcutRow(
                      label: '打开播放页',
                      hint: '回车打开当前歌曲的播放页',
                      keys: '回车',
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.action,
    required this.bindings,
    required this.changed,
    required this.onEdit,
    required this.onReset,
  });

  final AppShortcutAction action;
  final List<KeyBinding> bindings;

  /// 当前键位是否已被改过（含「未设置」）：改过的行才提供单行恢复入口。
  final bool changed;
  final VoidCallback onEdit;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          action.label,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          action.hint,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );

    // 用 Wrap 而不是 Row：宽版一行放下，窄窗（桌面最小 360）时键位标签
    // 自身就接近行宽，Wrap 会把「恢复/修改」折到下一行而不是溢出。
    final controls = Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.end,
      children: [
        if (bindings.isEmpty)
          const _KeyChip(label: '未设置', warning: true)
        else
          for (var index = 0; index < bindings.length; index++)
            _KeyChip(
              key: ValueKey('shortcut_chip_${action.name}_$index'),
              label: bindings[index].label,
            ),
        if (changed)
          IconButton(
            key: ValueKey('shortcut_reset_${action.name}'),
            tooltip: '恢复默认键位',
            onPressed: onReset,
            icon: const Icon(Icons.settings_backup_restore_rounded, size: 18),
          ),
        TextButton(
          key: ValueKey('shortcut_edit_${action.name}'),
          onPressed: onEdit,
          child: const Text('修改'),
        ),
      ],
    );

    return Padding(
      key: ValueKey('shortcut_row_${action.name}'),
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      // 桌面窗口最小 360 宽：键位 + 恢复 + 修改 横排会超出，窄窗改两行
      // （说明在上、键位与操作在下），避免 RenderFlex 溢出。
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [info, const SizedBox(height: 6), controls],
            );
          }
          return Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 12),
              controls,
            ],
          );
        },
      ),
    );
  }
}

class _FixedShortcutRow extends StatelessWidget {
  const _FixedShortcutRow({
    required this.label,
    required this.hint,
    required this.keys,
  });

  final String label;
  final String hint;
  final String keys;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _KeyChip(label: keys),
        ],
      ),
    );
  }
}

class _KeyChip extends StatelessWidget {
  const _KeyChip({super.key, required this.label, this.warning = false});

  final String label;

  /// 未设置/冲突态：用错误色，避免「空着」被当成已生效。
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = warning ? colorScheme.error : colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: warning ? colorScheme.error : colorScheme.outlineVariant,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: foreground,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.text,
    required this.color,
    required this.background,
  });

  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.keyboard_rounded, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 录制新键位的对话框：按下任意「修饰键 + 主键」组合，Esc 取消。
class _KeyCaptureDialog extends StatefulWidget {
  const _KeyCaptureDialog({required this.action});

  final AppShortcutAction action;

  @override
  State<_KeyCaptureDialog> createState() => _KeyCaptureDialogState();
}

class _KeyCaptureDialogState extends State<_KeyCaptureDialog> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'shortcut-capture');
  KeyBinding? _candidate;
  AppShortcutAction? _conflict;
  String? _reservedReason;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // 只认按下：KeyUp/Repeat 都会在同一次按键里重复回调。
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    // 纯修饰键不构成一次绑定：等主键按下来再收。
    if (isModifierKey(key)) return KeyEventResult.handled;

    final keyboard = HardwareKeyboard.instance;
    final binding = KeyBinding(
      key,
      control: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    setState(() {
      _candidate = binding;
      _reservedReason = reservedBindingReason(binding);
      _conflict = reservedBindingReason(binding) == null
          ? ShortcutController.instance.conflictOf(
              binding,
              ignore: widget.action,
            )
          : null;
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final candidate = _candidate;
    final conflict = _conflict;

    return AlertDialog(
      title: Text('修改「${widget.action.label}」'),
      content: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              key: const ValueKey('shortcut_capture_area'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 22),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.keyboard_rounded,
                    color: colorScheme.primary,
                    size: 22,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    candidate?.label ?? '请按下新的按键组合',
                    key: const ValueKey('shortcut_capture_label'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _reservedReason ??
                  (conflict == null
                      ? '组合里含 Ctrl / Shift / Alt / Win 可避免与输入冲突。Esc 取消。'
                      : '「${conflict.label}」正在使用该组合，保存后它会被置为未设置。'),
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                color: _reservedReason == null && conflict == null
                    ? colorScheme.onSurfaceVariant
                    : colorScheme.error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('shortcut_capture_save'),
          onPressed: candidate == null || _reservedReason != null
              ? null
              : () => Navigator.of(context).pop(candidate),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 两组键位是否等价（顺序敏感；[KeyBinding] 已实现值相等）。
bool _sameBindings(List<KeyBinding> a, List<KeyBinding> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
