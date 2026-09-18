import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/app_dialog.dart';

/// 创建歌单输入弹窗的键盘回归测试。
///
/// Material `Dialog` 内部已按 `viewInsets + insetPadding` 避让键盘
/// （见 SDK `material/dialog.dart`），`showDialog` 的 builder 应直接返回
/// `AppDialogShell`（与删除确认弹窗同写法）。外层再包
/// `AnimatedPadding(bottom: viewInsets)` 会双倍吃掉垂直空间：实测键盘弹起
/// 时内容 Column 约束被压到 `0<=h<=62`，溢出约 89px——M3 卡片默认不裁剪，
/// 取消/创建按钮就完整画到了白卡外面（键盘抬起必现、不抬没事）。
void main() {
  const physicalSize = Size(1200, 2670);
  const pixelRatio = 3.0;
  const keyboardBottom = 1100.0;

  Future<void> pumpDialog(WidgetTester tester) async {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = pixelRatio;
    // 模拟键盘弹起（物理像素）。
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardBottom);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showDialog<String>(
                    context: context,
                    barrierDismissible: false,
                    barrierColor: AppDialogStyle.barrierColor(),
                    // 与 _showCreatePlaylistDialog 修后写法一致：裸壳，
                    // 无外层 AnimatedPadding。
                    builder: (_) => AppDialogShell(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AppDialogTitle('创建歌单'),
                          const SizedBox(height: 16),
                          const SizedBox(height: 48),
                          const SizedBox(height: 20),
                          AppDialogPillActions(
                            confirmText: '创建',
                            confirmEnabled: false,
                            onCancel: () {},
                            onConfirm: () {},
                          ),
                        ],
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // 卡片本体：标题最近的 Material 祖先（药丸按钮自带透明 Material，
  // 标题的 Material 祖先才是白卡）。
  Finder cardFinder() => find.ancestor(
    of: find.text('创建歌单'),
    matching: find.byType(Material),
  );

  testWidgets('键盘弹起时卡片贴着键盘上方剩余空间居中，不过度浮空', (tester) async {
    await pumpDialog(tester);

    final cardRect = tester.getRect(cardFinder().first);
    final keyboardTop = (physicalSize.height - keyboardBottom) / pixelRatio;

    // 单倍避让：卡片底部与键盘顶保持合理距离（居中于剩余空间）；
    // 双倍顶起时底部会高出键盘顶约一个键盘高度。
    expect(cardRect.bottom, greaterThan(keyboardTop - 250));
    // 卡片不被键盘遮挡（含 Dialog 自身 24 垂直 inset）。
    expect(cardRect.bottom, lessThanOrEqualTo(keyboardTop - 20));
  });

  testWidgets('键盘弹起时双药丸按钮仍在卡片内、无 Column 溢出', (tester) async {
    await pumpDialog(tester);

    // pumpAndSettle 无溢出报错即已证明约束充足；再断言几何包含。
    final cardRect = tester.getRect(cardFinder().first);
    final cancelRect = tester.getRect(find.text('取消'));
    final confirmRect = tester.getRect(find.text('创建'));

    expect(cancelRect.top, greaterThanOrEqualTo(cardRect.top));
    expect(cancelRect.bottom, lessThanOrEqualTo(cardRect.bottom));
    expect(confirmRect.top, greaterThanOrEqualTo(cardRect.top));
    expect(confirmRect.bottom, lessThanOrEqualTo(cardRect.bottom));
  });
}
