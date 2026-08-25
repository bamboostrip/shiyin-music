import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/network_monitor.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';

void main() {
  testWidgets('网络恢复后 RetryableNetworkImage 更换 key 重建以重试加载', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RetryableNetworkImage(
            url: 'http://example.com/a.jpg',
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('retry-0')), findsOneWidget);

    NetworkMonitor.instance.debugSimulateRestored();
    await tester.pump();

    expect(find.byKey(const ValueKey('retry-0')), findsNothing);
    expect(find.byKey(const ValueKey('retry-1')), findsOneWidget);
  });

  testWidgets('Artwork 网络封面走 RetryableNetworkImage（断网失败后可自动重试）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: Artwork(url: 'http://example.com/a.jpg', size: 64)),
      ),
    );
    expect(find.byType(RetryableNetworkImage), findsOneWidget);
  });
}
