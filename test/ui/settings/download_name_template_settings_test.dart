import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/ui/settings/download_name_template_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('初始渲染默认模板副标题', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DownloadNameTemplateSettings())),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('歌手-歌名（示例'), findsOneWidget);
  });

  testWidgets('已设置的模板在进入时正确回显', (tester) async {
    SharedPreferences.setMockInitialValues({
      DownloadService.downloadNameTemplateKey: 'title-artist',
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DownloadNameTemplateSettings())),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('歌名-歌手（示例'), findsOneWidget);
  });

  testWidgets('选择「歌名-歌手」写入 prefs 并更新副标题', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DownloadNameTemplateSettings())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('下载文件名'));
    await tester.pumpAndSettle();
    // 弹窗里点「歌名-歌手」选项（title 精确匹配，避开副标题里的字样）。
    await tester.tap(
      find.widgetWithText(RadioListTile<DownloadNameTemplate>, '歌名-歌手'),
    );
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(DownloadService.downloadNameTemplateKey),
      'title-artist',
    );
    expect(find.textContaining('歌名-歌手（示例'), findsOneWidget);
  });
}
