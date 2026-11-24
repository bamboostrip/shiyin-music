import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通知栏自定义按钮的种类（issue #34）。
///
/// 系统媒体卡片只有两个自定义槽位：Android 13+ 的上一首/播放/下一首之外只剩
/// 第 4、5 格；Android 12 及以下（经 audio_service 本地补丁）通知一行同样放
/// 不下更多。所以「循环播放」与「随机播放」不做成两个键，合并为一个「播放
/// 模式」键：每点一次在 歌单循环 → 随机播放 → 单曲循环 之间轮换，图标跟随
/// 当前模式，与应用内那个模式按钮同义。
enum NotificationSlotAction {
  none('none', '不显示'),
  like('like', '收藏'),
  desktopLyrics('desktop_lyrics', '桌面歌词'),
  playbackMode('playback_mode', '播放模式');

  const NotificationSlotAction(this.storedValue, this.label);

  /// prefs 存储值。
  final String storedValue;

  /// 设置项展示名。
  final String label;

  /// prefs 存储值 → 种类；缺失/脏值回退 [fallback]（与下载命名模板同策略：
  /// 手改/旧数据不能把按钮锁死成未知值）。
  static NotificationSlotAction fromStored(String? stored, NotificationSlotAction fallback) =>
      values.firstWhere(
        (action) => action.storedValue == stored,
        orElse: () => fallback,
      );
}

/// 通知栏左右两个自定义槽位当前各放什么按钮。
class NotificationButtonSlots {
  const NotificationButtonSlots({required this.left, required this.right});

  /// 默认：红心在左、桌面歌词在右（与本功能出现前的通知一致）。
  static const defaults = NotificationButtonSlots(
    left: NotificationSlotAction.like,
    right: NotificationSlotAction.desktopLyrics,
  );

  static const leftKey = 'settings.notification_button_left';
  static const rightKey = 'settings.notification_button_right';

  /// 左侧槽位（标准三键之前）。
  final NotificationSlotAction left;

  /// 右侧槽位（标准三键之后）。
  final NotificationSlotAction right;

  /// 进程内当前值。
  ///
  /// 通知按钮的桥接闭包每次构建按钮都读它；设置页写入后先更新这里，监听方
  /// （main.dart）据此立刻重广播通知，不必等下一个播放事件。
  static final ValueNotifier<NotificationButtonSlots> current =
      ValueNotifier<NotificationButtonSlots>(defaults);

  /// 启动时从 prefs 读出上次的选择；读失败保持默认（只是按钮摆法，不该
  /// 因为 prefs 异常影响启动）。
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      current.value = NotificationButtonSlots(
        left: NotificationSlotAction.fromStored(
          prefs.getString(leftKey),
          defaults.left,
        ),
        right: NotificationSlotAction.fromStored(
          prefs.getString(rightKey),
          defaults.right,
        ),
      );
    } catch (error) {
      debugPrint('[设置] 读取通知栏按钮配置失败，沿用默认: $error');
    }
  }

  /// 落盘新的槽位组合并更新 [current]。
  ///
  /// 写 prefs 失败时不改 [current] 并把异常抛给调用方提示——否则界面显示
  /// 的新按钮与下次启动后的实际值不一致。
  static Future<void> save(NotificationButtonSlots slots) async {
    final prefs = await SharedPreferences.getInstance();
    // 两侧都写：撞车对调时另一侧也换了按钮，只写被选的那一侧会让下次启动
    // 读回「两侧同一个按钮」。
    await prefs.setString(leftKey, slots.left.storedValue);
    await prefs.setString(rightKey, slots.right.storedValue);
    // 先落盘再更新进程内值。
    if (current.value != slots) current.value = slots;
  }

  /// 纯函数：把 [action] 放进 [isLeft] 那一侧。
  ///
  /// 同一个按钮出现两次没有意义：选中的种类正被另一侧占用时两侧对调——
  /// 另一侧接过这一侧原来的按钮。「不显示」可以两侧同时选，不算撞车。
  static NotificationButtonSlots resolve(
    NotificationButtonSlots slots, {
    required bool isLeft,
    required NotificationSlotAction action,
  }) {
    if (isLeft) {
      if (action == slots.left) return slots;
      final right = action != NotificationSlotAction.none && action == slots.right
          ? slots.left
          : slots.right;
      return NotificationButtonSlots(left: action, right: right);
    }
    if (action == slots.right) return slots;
    final left = action != NotificationSlotAction.none && action == slots.left
        ? slots.right
        : slots.left;
    return NotificationButtonSlots(left: left, right: action);
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationButtonSlots &&
      other.left == left &&
      other.right == right;

  @override
  int get hashCode => Object.hash(left, right);

  @override
  String toString() => 'NotificationButtonSlots(left: $left, right: $right)';
}
