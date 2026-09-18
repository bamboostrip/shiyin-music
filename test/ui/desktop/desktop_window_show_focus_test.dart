import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/desktop/desktop_window.dart';

void main() {
  group('DesktopWindow.showAndFocus（恢复并置前唯一实现）', () {
    test('最小化时顺序为 restore → show → focus', () async {
      final calls = <String>[];
      await DesktopWindow.showAndFocus(
        isMinimized: () async {
          calls.add('isMinimized');
          return true;
        },
        restore: () async => calls.add('restore'),
        show: () async => calls.add('show'),
        focus: () async => calls.add('focus'),
      );
      expect(calls, ['isMinimized', 'restore', 'show', 'focus']);
    });

    test('非最小化（含托盘隐藏/后台）时跳过 restore，直接 show → focus', () async {
      final calls = <String>[];
      await DesktopWindow.showAndFocus(
        isMinimized: () async {
          calls.add('isMinimized');
          return false;
        },
        restore: () async => calls.add('restore'),
        show: () async => calls.add('show'),
        focus: () async => calls.add('focus'),
      );
      expect(calls, ['isMinimized', 'show', 'focus']);
    });

    test('窗口操作失败时不抛出（无害激活）', () async {
      await DesktopWindow.showAndFocus(
        isMinimized: () async => false,
        show: () async => throw Exception('window gone'),
        focus: () async => fail('show 失败后不应继续 focus'),
      );
      // 能执行到这里即永不抛出成立。
    });
  });
}
