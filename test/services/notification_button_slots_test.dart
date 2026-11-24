import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/services/notification_button_slots.dart';

/// 通知栏左右槽位配置（issue #34）：解析、对调规则、落盘与进程内值的同步。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationButtonSlots.current.value = NotificationButtonSlots.defaults;
  });

  group('NotificationSlotAction.fromStored', () {
    test('合法值解析，缺失/脏值回退各自的默认', () {
      expect(
        NotificationSlotAction.fromStored('like', NotificationSlotAction.none),
        NotificationSlotAction.like,
      );
      expect(
        NotificationSlotAction.fromStored(
          'desktop_lyrics',
          NotificationSlotAction.none,
        ),
        NotificationSlotAction.desktopLyrics,
      );
      expect(
        NotificationSlotAction.fromStored(
          'playback_mode',
          NotificationSlotAction.none,
        ),
        NotificationSlotAction.playbackMode,
      );
      expect(
        NotificationSlotAction.fromStored('none', NotificationSlotAction.like),
        NotificationSlotAction.none,
      );
      // 缺失与脏值都不能把按钮锁成未知种类。
      expect(
        NotificationSlotAction.fromStored(null, NotificationSlotAction.like),
        NotificationSlotAction.like,
      );
      expect(
        NotificationSlotAction.fromStored('garbage', NotificationSlotAction.like),
        NotificationSlotAction.like,
      );
    });

    test('存储值互不相同（对调与去重都靠它判身份）', () {
      final stored = {
        for (final action in NotificationSlotAction.values) action.storedValue,
      };
      expect(stored, hasLength(NotificationSlotAction.values.length));
    });
  });

  group('resolve 对调规则', () {
    const slots = NotificationButtonSlots(
      left: NotificationSlotAction.like,
      right: NotificationSlotAction.desktopLyrics,
    );

    test('选另一侧正占用的按钮：两侧对调', () {
      final next = NotificationButtonSlots.resolve(
        slots,
        isLeft: true,
        action: NotificationSlotAction.desktopLyrics,
      );
      expect(next.left, NotificationSlotAction.desktopLyrics);
      expect(next.right, NotificationSlotAction.like);
    });

    test('选空闲按钮：只动被选的一侧', () {
      final next = NotificationButtonSlots.resolve(
        slots,
        isLeft: false,
        action: NotificationSlotAction.playbackMode,
      );
      expect(next.left, NotificationSlotAction.like);
      expect(next.right, NotificationSlotAction.playbackMode);
    });

    test('「不显示」可两侧同时选，不算撞车', () {
      final next = NotificationButtonSlots.resolve(
        slots,
        isLeft: false,
        action: NotificationSlotAction.none,
      );
      expect(next.left, NotificationSlotAction.like);
      expect(next.right, NotificationSlotAction.none);

      final both = NotificationButtonSlots.resolve(
        next,
        isLeft: true,
        action: NotificationSlotAction.none,
      );
      expect(
        both,
        const NotificationButtonSlots(
          left: NotificationSlotAction.none,
          right: NotificationSlotAction.none,
        ),
      );
    });

    test('另一侧是「不显示」时撞车对调：另一侧接过本侧原来的按钮', () {
      final next = NotificationButtonSlots.resolve(
        const NotificationButtonSlots(
          left: NotificationSlotAction.like,
          right: NotificationSlotAction.none,
        ),
        isLeft: false,
        action: NotificationSlotAction.like,
      );
      expect(next.left, NotificationSlotAction.none);
      expect(next.right, NotificationSlotAction.like);
    });

    test('重选当前值不变（原实例返回）', () {
      expect(
        NotificationButtonSlots.resolve(
          slots,
          isLeft: true,
          action: NotificationSlotAction.like,
        ),
        same(slots),
      );
    });
  });

  group('load', () {
    test('prefs 没有记录时沿用默认（红心在左、词在右）', () async {
      await NotificationButtonSlots.load();
      expect(NotificationButtonSlots.current.value, NotificationButtonSlots.defaults);
    });

    test('读回上次保存的两侧配置，脏值按各自的默认回退', () async {
      SharedPreferences.setMockInitialValues({
        NotificationButtonSlots.leftKey: 'playback_mode',
        NotificationButtonSlots.rightKey: 'desktop_lyrics',
      });
      await NotificationButtonSlots.load();
      expect(
        NotificationButtonSlots.current.value,
        const NotificationButtonSlots(
          left: NotificationSlotAction.playbackMode,
          right: NotificationSlotAction.desktopLyrics,
        ),
      );

      SharedPreferences.setMockInitialValues({
        NotificationButtonSlots.leftKey: 'garbage',
        NotificationButtonSlots.rightKey: 'playback_mode',
      });
      await NotificationButtonSlots.load();
      expect(
        NotificationButtonSlots.current.value,
        const NotificationButtonSlots(
          left: NotificationSlotAction.like,
          right: NotificationSlotAction.playbackMode,
        ),
      );
    });
  });

  group('save', () {
    test('两侧都落盘，且进程内值同步更新并通知监听方', () async {
      var notified = 0;
      NotificationButtonSlots.current.addListener(() => notified++);

      const next = NotificationButtonSlots(
        left: NotificationSlotAction.desktopLyrics,
        right: NotificationSlotAction.playbackMode,
      );
      await NotificationButtonSlots.save(next);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(NotificationButtonSlots.leftKey), 'desktop_lyrics');
      expect(prefs.getString(NotificationButtonSlots.rightKey), 'playback_mode');
      expect(NotificationButtonSlots.current.value, next);
      expect(notified, 1);
    });

    test('对调后的另一侧也落盘：重新 load 不会读回「两侧同一个按钮」', () async {
      const before = NotificationButtonSlots(
        left: NotificationSlotAction.like,
        right: NotificationSlotAction.desktopLyrics,
      );
      NotificationButtonSlots.current.value = before;

      final swapped = NotificationButtonSlots.resolve(
        before,
        isLeft: true,
        action: NotificationSlotAction.desktopLyrics,
      );
      await NotificationButtonSlots.save(swapped);

      NotificationButtonSlots.current.value = NotificationButtonSlots.defaults;
      await NotificationButtonSlots.load();
      expect(NotificationButtonSlots.current.value, swapped);
      expect(NotificationButtonSlots.current.value.left,
          isNot(NotificationButtonSlots.current.value.right));
    });

    test('值没变时不重复通知（避免无谓地重广播通知按钮）', () async {
      var notified = 0;
      NotificationButtonSlots.current.addListener(() => notified++);
      await NotificationButtonSlots.save(NotificationButtonSlots.defaults);
      expect(notified, 0);
    });
  });
}
