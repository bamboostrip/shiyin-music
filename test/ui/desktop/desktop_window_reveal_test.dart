// 首帧后显示主窗的顺序（实测出来的两个 Windows 坑）：
// 1) SC_MAXIMIZE 对隐藏窗口是空操作 → 必须等窗口可见后再 maximize；
// 2) 原生 runner 在首帧「真正呈现」时才 Show，晚于 Dart post-frame 回调 →
//    先等它一下，等不到再手动 show 兜底（否则可能显示空白客户区）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/desktop/desktop_window.dart';

void main() {
  test('未最大化：等可见后 show + focus，不调 maximize', () async {
    final calls = <String>[];
    var visible = false;

    await DesktopWindow.revealWithOps(
      maximized: false,
      isVisible: () async => visible,
      isMaximized: () async => false,
      show: () async {
        calls.add('show');
        visible = true;
      },
      focus: () async => calls.add('focus'),
      maximize: () async => calls.add('maximize'),
      poll: Duration.zero,
      maxPolls: 3,
    );

    expect(calls, ['show', 'focus']);
  });

  test('原生首帧已显示：不重复 show，只抢焦点', () async {
    final calls = <String>[];

    await DesktopWindow.revealWithOps(
      maximized: false,
      isVisible: () async => true,
      isMaximized: () async => false,
      show: () async => calls.add('show'),
      focus: () async => calls.add('focus'),
      maximize: () async => calls.add('maximize'),
      poll: Duration.zero,
      maxPolls: 3,
    );

    expect(calls, ['focus']);
  });

  test('最大化记忆：窗口可见后再 maximize，并等到真正生效', () async {
    final calls = <String>[];
    var visible = false;
    var maximized = false;

    await DesktopWindow.revealWithOps(
      maximized: true,
      isVisible: () async => visible,
      isMaximized: () async => maximized,
      show: () async {
        calls.add('show');
        visible = true;
      },
      focus: () async => calls.add('focus'),
      maximize: () async {
        calls.add('maximize');
        maximized = true;
      },
      poll: Duration.zero,
      maxPolls: 3,
    );

    expect(calls, ['show', 'focus', 'maximize']);
  });

  test('最大化迟迟不生效：有界返回，不阻塞启动', () async {
    var polls = 0;

    await DesktopWindow.revealWithOps(
      maximized: true,
      isVisible: () async => true,
      isMaximized: () async {
        polls++;
        return false;
      },
      show: () async {},
      focus: () async {},
      maximize: () async {},
      poll: Duration.zero,
      maxPolls: 2,
    );

    expect(polls, lessThanOrEqualTo(2));
  });

  test('始终不可见：show 兜底，仍抢焦点，但不做无效 maximize', () async {
    final calls = <String>[];

    await DesktopWindow.revealWithOps(
      maximized: true,
      isVisible: () async => false,
      isMaximized: () async => false,
      show: () async => calls.add('show'),
      focus: () async => calls.add('focus'),
      maximize: () async => calls.add('maximize'),
      poll: Duration.zero,
      maxPolls: 2,
    );

    expect(calls, ['show', 'focus']);
  });
}
