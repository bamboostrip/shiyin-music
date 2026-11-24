import 'package:flutter/material.dart';

import '../../services/notification_button_slots.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 「通知栏按钮」设置项（设置 → 播放设置 → 后台与网络，仅 Android 非车机）。
///
/// 通知栏的媒体通知中间固定是 上一首 / 播放 / 下一首，两侧各有一个自定义
/// 槽位（系统只给两个），这里决定各放什么（issue #34）。弹窗里可以先摆、
/// 带预览，点「确定」才落盘。
///
/// 两侧不能放同一个按钮：选中的种类正被另一侧占用时自动对调，见
/// [NotificationButtonSlots.resolve]。
class NotificationButtonsSettings extends StatefulWidget {
  const NotificationButtonsSettings({super.key});

  @override
  State<NotificationButtonsSettings> createState() =>
      _NotificationButtonsSettingsState();
}

class _NotificationButtonsSettingsState
    extends State<NotificationButtonsSettings> {
  /// 正在写入设置：忽略重复点击，并在瓦片图标位转圈（对齐下载音质项）。
  bool _saving = false;

  Future<void> _pick() async {
    if (_saving) return;
    var slots = NotificationButtonSlots.current.value;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('通知栏按钮'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('中间固定是 上一首 / 播放 / 下一首，两侧各放一个；选另一侧正占用的按钮会自动对调'),
                const SizedBox(height: 12),
                _NotificationPreview(slots: slots),
                const SizedBox(height: 12),
                // 两组并排：高度只有竖排的一半（横屏/小屏不滚动就能看完），
                // 而且「左侧」就摆在预览的左边，不用再解释指的是哪边。
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _slotGroup(
                        title: '左侧',
                        selected: slots.left,
                        select: (action) => setDialogState(
                          () => slots = NotificationButtonSlots.resolve(
                            slots,
                            isLeft: true,
                            action: action,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _slotGroup(
                        title: '右侧',
                        selected: slots.right,
                        select: (action) => setDialogState(
                          () => slots = NotificationButtonSlots.resolve(
                            slots,
                            isLeft: false,
                            action: action,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    if (slots == NotificationButtonSlots.current.value) return;

    setState(() => _saving = true);
    try {
      await NotificationButtonSlots.save(slots);
      debugPrint('[设置] 通知栏按钮已更新: $slots');
    } catch (error) {
      // 写 prefs 失败时通知与下次启动都还是旧按钮：必须提示，不能让界面
      // 显示一个没生效的配置。
      debugPrint('[设置] 保存通知栏按钮失败: $error');
      if (mounted) Toast.error('保存通知栏按钮设置失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _slotGroup({
    required String title,
    required NotificationSlotAction selected,
    required ValueChanged<NotificationSlotAction> select,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 2),
          child: Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        RadioGroup<NotificationSlotAction>(
          groupValue: selected,
          onChanged: (value) {
            if (value != null) select(value);
          },
          // 单栏只有 100px 出头：去掉列表项留白、标签用小一号字才放得下。
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in NotificationSlotAction.values)
                RadioListTile<NotificationSlotAction>(
                  value: action,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    action.label,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NotificationButtonSlots>(
      valueListenable: NotificationButtonSlots.current,
      builder: (context, slots, _) => SettingsTile(
        icon: Icons.notifications_rounded,
        iconColor: const Color(0xFFEF6C00),
        title: '通知栏按钮',
        subtitle: '左侧：${slots.left.label} · 右侧：${slots.right.label}',
        loading: _saving,
        onTap: _pick,
      ),
    );
  }
}

/// 弹窗顶部的实时预览：按最终布局摆出五个位置，一眼看懂「左 / 右」指哪边。
class _NotificationPreview extends StatelessWidget {
  const _NotificationPreview({required this.slots});

  final NotificationButtonSlots slots;

  static IconData _iconOf(NotificationSlotAction action) => switch (action) {
        NotificationSlotAction.like => Icons.favorite_outline_rounded,
        NotificationSlotAction.desktopLyrics => Icons.lyrics_outlined,
        NotificationSlotAction.playbackMode => Icons.repeat_rounded,
        // 「不显示」留一个占位，保证三键始终居中。
        NotificationSlotAction.none => Icons.remove_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget slot(NotificationSlotAction action) {
      final dimmed = action == NotificationSlotAction.none;
      return Expanded(
        child: Icon(
          _iconOf(action),
          size: 22,
          color: dimmed
              ? colorScheme.outlineVariant
              : colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          slot(slots.left),
          const Expanded(
            child: Icon(Icons.skip_previous_rounded, size: 26),
          ),
          Expanded(
            child: Icon(
              Icons.play_circle_fill_rounded,
              size: 34,
              color: colorScheme.primary,
            ),
          ),
          const Expanded(
            child: Icon(Icons.skip_next_rounded, size: 26),
          ),
          slot(slots.right),
        ],
      ),
    );
  }
}
