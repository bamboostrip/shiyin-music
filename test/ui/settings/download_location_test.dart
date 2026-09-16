import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/settings/desktop_settings_section.dart';

/// 「下载位置」file_picker 失败时的 PowerShell WinForms 兜底：
/// 脚本构造与 -EncodedCommand 编码的确定性。
void main() {
  group('buildFolderBrowserScript', () {
    test('含初始目录时设置 SelectedPath，路径原样保留', () {
      final script = buildFolderBrowserScript(
        r'D:\SyncUp\Downloads\shiyin_downloads',
      );
      expect(
        script,
        contains(
          r"$dlg.SelectedPath = 'D:\SyncUp\Downloads\shiyin_downloads'",
        ),
      );
      expect(script, contains('FolderBrowserDialog'));
      // 取消时不输出：stdout 为空即 null。
      expect(script, contains('DialogResult]::OK'));
    });

    test('无初始目录时不设置 SelectedPath', () {
      final script = buildFolderBrowserScript(null);
      expect(script, isNot(contains('SelectedPath =')));
    });

    test("路径含单引号时转义为 '' 防止 PS 字符串提前闭合", () {
      final script = buildFolderBrowserScript(r"D:\Hank's Music");
      expect(script, contains(r"$dlg.SelectedPath = 'D:\Hank''s Music'"));
    });
  });

  group('encodePowerShellScript', () {
    test('输出为 Base64 的 UTF-16LE，可无损还原', () {
      const script = "Write-Output '/select,\"D:\\a b\\周杰伦.mp3\"'";
      final encoded = encodePowerShellScript(script);

      // Base64 还原出 UTF-16LE 字节，再按 UTF-16LE 解回原字符串。
      final bytes = base64Decode(encoded);
      final units = <int>[];
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        units.add(bytes[i] | (bytes[i + 1] << 8));
      }
      expect(String.fromCharCodes(units), script);
    });
  });
}
