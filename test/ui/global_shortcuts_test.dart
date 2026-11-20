import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/ui/global_shortcuts.dart';
import 'package:shiyin_music/ui/keyboard_shortcuts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalShortcutController.instance.debugReset();
  });

  group('GlobalShortcutController（issue #31 全局热键改键）', () {
    test('默认表：QQ 音乐式 Ctrl+Alt 系低冲突组合，覆盖五个动作', () {
      final controller = GlobalShortcutController.instance;
      expect(
        controller.bindingsOf(GlobalShortcutAction.playPause),
        const [
          KeyBinding(LogicalKeyboardKey.keyP, control: true, alt: true),
        ],
      );
      expect(
        controller.bindingsOf(GlobalShortcutAction.previousTrack),
        const [
          KeyBinding(LogicalKeyboardKey.arrowLeft, control: true, alt: true),
        ],
      );
      expect(
        controller.bindingsOf(GlobalShortcutAction.nextTrack),
        const [
          KeyBinding(LogicalKeyboardKey.arrowRight, control: true, alt: true),
        ],
      );
      expect(
        controller.bindingsOf(GlobalShortcutAction.volumeUp),
        const [
          KeyBinding(LogicalKeyboardKey.arrowUp, control: true, alt: true),
        ],
      );
      expect(
        controller.bindingsOf(GlobalShortcutAction.volumeDown),
        const [
          KeyBinding(LogicalKeyboardKey.arrowDown, control: true, alt: true),
        ],
      );
      // 全表无重复组合。
      final seen = <String>{};
      for (final action in GlobalShortcutAction.values) {
        for (final binding in controller.bindingsOf(action)) {
          expect(seen.add(binding.encode()), isTrue,
              reason: '${action.label} 的 ${binding.label} 重复');
        }
      }
    });

    test('总开关默认开启；切换后持久化，重启保持', () async {
      final controller = GlobalShortcutController.instance;
      expect(controller.enabled, isTrue, reason: 'QQ 音乐式默认开启');

      await controller.setEnabled(false);
      expect(controller.enabled, isFalse);

      controller.debugReset();
      await controller.load();
      expect(controller.enabled, isFalse);
    });

    test('改键成功并写盘', () async {
      final controller = GlobalShortcutController.instance;
      const binding = KeyBinding(LogicalKeyboardKey.f9, control: true);
      expect(
        await controller.setBinding(GlobalShortcutAction.playPause, binding),
        isTrue,
      );
      expect(
        controller.bindingsOf(GlobalShortcutAction.playPause),
        [binding],
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(GlobalShortcutController.bindingsPrefsKey),
          contains(binding.encode()));
    });

    test('保留规则：Ctrl/Alt 都不参与的一律拒绝（拦系统打字/被系统占用）', () async {
      final controller = GlobalShortcutController.instance;

      // 裸键：会拦截全系统该键的输入。
      expect(
        globalReservedBindingReason(const KeyBinding(LogicalKeyboardKey.keyP)),
        isNotNull,
      );
      // 仅 Shift：Shift+字母是输入大写，会拦截打字。
      expect(
        globalReservedBindingReason(
          const KeyBinding(LogicalKeyboardKey.keyP, shift: true),
        ),
        isNotNull,
      );
      // 仅 Win/Meta：组合大多被系统占用，注册了也收不到。
      expect(
        globalReservedBindingReason(
          const KeyBinding(LogicalKeyboardKey.keyP, meta: true),
        ),
        isNotNull,
      );
      expect(
        globalReservedBindingReason(
          const KeyBinding(LogicalKeyboardKey.keyP, shift: true, meta: true),
        ),
        isNotNull,
      );

      // Ctrl 或 Alt 任一参与即可。
      expect(
        globalReservedBindingReason(
          const KeyBinding(LogicalKeyboardKey.keyP, control: true),
        ),
        isNull,
      );
      expect(
        globalReservedBindingReason(
          const KeyBinding(LogicalKeyboardKey.keyP, alt: true),
        ),
        isNull,
      );
      expect(
        globalReservedBindingReason(
          const KeyBinding(LogicalKeyboardKey.f8, shift: true, control: true),
        ),
        isNull,
      );

      // 被拒的组合 setBinding 返回 false 且键位不变。
      expect(
        await controller.setBinding(
          GlobalShortcutAction.playPause,
          const KeyBinding(LogicalKeyboardKey.keyP),
        ),
        isFalse,
      );
      expect(
        controller.bindingsOf(GlobalShortcutAction.playPause),
        defaultGlobalBindingsFor(GlobalShortcutAction.playPause),
      );
    });

    test('抢占同一组合：被抢动作置「未设置」，不回落默认键', () async {
      final controller = GlobalShortcutController.instance;
      // Ctrl+Alt+↑ 原属「音量+」，改给「播放/暂停」。
      const binding = KeyBinding(
        LogicalKeyboardKey.arrowUp,
        control: true,
        alt: true,
      );
      expect(
        await controller.setBinding(GlobalShortcutAction.playPause, binding),
        isTrue,
      );
      expect(
        controller.bindingsOf(GlobalShortcutAction.volumeUp),
        isEmpty,
        reason: '被抢后不能回落默认键，否则两条记录共用一键',
      );
    });

    test('「未设置」持久化：重启读取后不会被默认键补回来', () async {
      final controller = GlobalShortcutController.instance;
      // 把 Ctrl+Alt+↑ 抢给播放/暂停，音量+ 变「未设置」。
      await controller.setBinding(
        GlobalShortcutAction.playPause,
        const KeyBinding(LogicalKeyboardKey.arrowUp, control: true, alt: true),
      );
      expect(
        controller.bindingsOf(GlobalShortcutAction.volumeUp),
        isEmpty,
      );

      controller.debugReset();
      await controller.load();
      expect(
        controller.bindingsOf(GlobalShortcutAction.volumeUp),
        isEmpty,
      );
      expect(
        controller.bindingsOf(GlobalShortcutAction.playPause),
        const [
          KeyBinding(LogicalKeyboardKey.arrowUp, control: true, alt: true),
        ],
      );
    });

    test('整串配置是坏 JSON/非对象时回退默认表且开关保持默认', () async {
      for (final raw in ['{oops', '[1,2]', '"配置"', 'null']) {
        SharedPreferences.setMockInitialValues({
          GlobalShortcutController.bindingsPrefsKey: raw,
        });
        GlobalShortcutController.instance.debugReset();
        await GlobalShortcutController.instance.load();

        for (final action in GlobalShortcutAction.values) {
          expect(
            GlobalShortcutController.instance.bindingsOf(action),
            defaultGlobalBindingsFor(action),
            reason: '$action ← prefs = $raw',
          );
        }
        expect(GlobalShortcutController.instance.enabled, isTrue,
            reason: 'bindings 脏数据不影响开关 ← $raw');
      }
    });

    test('单条记录脏数据跳过；同一组合多处出现先到先得', () async {
      // 用真实 KeyBinding 生成编码，避免手写 flags/keyId 出错。
      const stolen = KeyBinding(
        LogicalKeyboardKey.keyP,
        control: true,
        alt: true,
      );
      SharedPreferences.setMockInitialValues({
        GlobalShortcutController.bindingsPrefsKey: jsonEncode({
          'playPause': ['nope', stolen.encode()], // 脏 + 正常
          'nextTrack': [stolen.encode()], // 与 playPause 撞车
        }),
      });
      final controller = GlobalShortcutController.instance;
      controller.debugReset();
      await controller.load();

      expect(
        controller.bindingsOf(GlobalShortcutAction.playPause),
        const [
          KeyBinding(LogicalKeyboardKey.keyP, control: true, alt: true),
        ],
      );
      expect(controller.bindingsOf(GlobalShortcutAction.nextTrack), isEmpty);
    });

    test('恢复全部默认', () async {
      final controller = GlobalShortcutController.instance;
      await controller.setBinding(
        GlobalShortcutAction.playPause,
        const KeyBinding(LogicalKeyboardKey.f9, control: true),
      );
      await controller.setEnabled(false);
      await controller.resetAll();
      expect(
        controller.bindingsOf(GlobalShortcutAction.playPause),
        defaultGlobalBindingsFor(GlobalShortcutAction.playPause),
      );
      // 恢复默认只还原键位，不动总开关（开关是用户对「要不要全局」的表态）。
      expect(controller.enabled, isFalse);
    });
  });
}
