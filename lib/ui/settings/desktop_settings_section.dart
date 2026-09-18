import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/desktop_system_integration.dart';
import '../../services/download_service.dart';
import '../desktop/desktop_window.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 设置页「桌面」分节（仅桌面形态：托盘关闭行为 + 下载位置 + 窗口重置）。
class DesktopSettingsSection extends StatelessWidget {
  const DesktopSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '桌面'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            const CloseToTraySwitch(),
            SettingsDivider(),
            const AutoStartSwitch(),
            SettingsDivider(),
            const DownloadLocationSettings(),
            SettingsDivider(),
            SettingsTile(
              icon: Icons.crop_square_rounded,
              iconColor: const Color(0xFF7CB342),
              title: '重置窗口',
              subtitle: '恢复默认窗口大小并居中',
              onTap: () => unawaited(DesktopWindow.resetToDefault()),
            ),
          ],
        ),
        // 与下一节（缓存）的间距：放在门控内，
        // 避免移动端桌面块被跳过时间距 20→40 翻倍。
        const SizedBox(height: 20),
      ],
    );
  }
}

/// "关闭时最小化到托盘"开关（桌面形态专属）。
///
/// settings_page 整页为 StatelessWidget，为避免整页改造，
/// 该开关独立成小组件，自行读写 prefs 键
/// [DesktopWindow.kCloseToTrayPrefKey]（默认 true）。
class CloseToTraySwitch extends StatefulWidget {
  const CloseToTraySwitch({super.key});

  @override
  State<CloseToTraySwitch> createState() => _CloseToTraySwitchState();
}

class _CloseToTraySwitchState extends State<CloseToTraySwitch> {
  /// 默认开启，与关闭行为默认值一致，prefs 读取完成后覆盖。
  bool _closeToTray = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _closeToTray = DesktopWindow.closeToTrayEnabled(prefs);
    });
  }

  Future<void> _onChanged(bool value) async {
    setState(() => _closeToTray = value);
    final prefs = await SharedPreferences.getInstance();
    await DesktopWindow.setCloseToTray(prefs, value);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchTile(
      icon: Icons.window_rounded,
      iconColor: const Color(0xFF00B0FF),
      title: '关闭时最小化到托盘',
      subtitle: '点关闭按钮时隐藏到系统托盘，音乐不断',
      value: _closeToTray,
      onChanged: (value) => unawaited(_onChanged(value)),
    );
  }
}

/// "开机自启"开关（桌面形态专属）。
///
/// 与 [CloseToTraySwitch] 同模式：独立小组件避免整页改 Stateful。
/// 切换即 register/unregister（[autoStartManager]，可注入测试 fake）；
/// 失败或注册表实际状态与预期不符时回滚 UI 并提示，
/// 保证开关始终反映 OS 真实状态。
class AutoStartSwitch extends StatefulWidget {
  const AutoStartSwitch({super.key});

  @override
  State<AutoStartSwitch> createState() => _AutoStartSwitchState();
}

class _AutoStartSwitchState extends State<AutoStartSwitch> {
  /// 默认关；OS 实际状态读取完成后覆盖。
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await autoStartManager.isEnabled();
      if (!mounted) return;
      setState(() => _enabled = enabled);
    } on Exception {
      // 读取失败保持默认关（与开关初值一致），不影响页面其余功能。
    }
  }

  Future<void> _onChanged(bool value) async {
    // 乐观更新：立即反馈点击。
    setState(() => _enabled = value);
    try {
      await autoStartManager.setEnabled(value);
      // 以 OS 实际状态为准（如注册表写入被组策略拦截时 enable 静默失败）。
      final actual = await autoStartManager.isEnabled();
      if (!mounted) return;
      if (actual != value) {
        setState(() => _enabled = actual);
        Toast.error('设置开机自启失败');
      }
    } on Exception {
      if (!mounted) return;
      setState(() => _enabled = !value);
      Toast.error('设置开机自启失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchTile(
      icon: Icons.rocket_launch_rounded,
      iconColor: const Color(0xFF3949AB),
      title: '开机自启',
      subtitle: '登录系统时自动启动时音',
      value: _enabled,
      onChanged: (value) => unawaited(_onChanged(value)),
    );
  }
}

/// 「下载位置」（桌面形态专属）：file_picker 选目录写入
/// [DownloadService.downloadDirOverrideKey]，[DownloadService.downloadDir]
/// 在桌面分支优先使用；设置后只影响新下载，已有下载的索引是绝对路径
/// 仍有效，且下次对账会按「以文件为准」语义搬入新目录。
///
/// 与 [CloseToTraySwitch] 同模式：独立小组件自管状态，避免整页改
/// Stateful。设了自定义位置时追加「恢复默认」一行。
class DownloadLocationSettings extends StatefulWidget {
  const DownloadLocationSettings({super.key});

  @override
  State<DownloadLocationSettings> createState() =>
      _DownloadLocationSettingsState();
}

class _DownloadLocationSettingsState extends State<DownloadLocationSettings> {
  /// null = 未设置自定义（跟随系统默认）。
  String? _custom;

  /// 当前实际生效的下载目录（解析失败时为 null，配合 [_loaded] 区分
  /// 「还在读」与「读不到」）。
  String? _effectivePath;
  bool _loaded = false;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final custom = await DownloadService.customDownloadDirOverride();
    String? effective = custom;
    try {
      effective = (await DownloadService().downloadDir()).path;
    } catch (e) {
      // 目录解析失败（自定义位置所在卷未挂载等）：显示不可用态，
      // 用户仍可在此改选或恢复默认。
      debugPrint('[设置] 解析下载位置失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _custom = custom;
      _effectivePath = effective;
      _loaded = true;
    });
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      Toast.info('请选择下载文件夹...');
      String? directory;
      try {
        directory = await FilePicker.getDirectoryPath(
          dialogTitle: '选择下载位置',
          initialDirectory: _effectivePath,
          lockParentWindow: true,
        );
      } catch (e) {
        // file_picker 的 Windows COM 弹窗偶发 WindowsException（上游
        // 长期存在的线程/初始化类 issue，无稳定复现路径）：降级到
        // PowerShell 的 WinForms FolderBrowserDialog——弹窗机制完全
        // 独立，不受影响；取消返回 null 与主路径语义一致。
        debugPrint('[设置] 文件夹选择器异常，降级 WinForms 弹窗: $e');
        directory = await _pickDirectoryFallback(_effectivePath);
      }
      if (directory == null) return;
      // 先探测可写再保存：选到不可写目录（权限不足/只读介质）时当场报错，
      // 而不是存下来等下载时才失败。
      try {
        await DownloadService.ensureWritableDir(directory);
      } catch (e) {
        debugPrint('[设置] 下载位置不可写: $e');
        Toast.error('$e');
        return;
      }
      await DownloadService.setCustomDownloadDir(directory);
      Toast.success('下载位置已更新，之后下载的歌曲将保存到该文件夹');
      await _load();
    } catch (e) {
      debugPrint('[设置] 设置下载位置失败: $e');
      Toast.error('设置下载位置失败：$e');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// file_picker 失败时的兜底：PowerShell 跑 WinForms FolderBrowserDialog，
  /// stdout 回传所选路径；用户取消返回 null，PowerShell 异常原样抛出。
  Future<String?> _pickDirectoryFallback(String? initialDirectory) async {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-STA',
        '-EncodedCommand',
        encodePowerShellScript(
          buildFolderBrowserScript(initialDirectory),
        ),
      ],
    );
    if (result.exitCode != 0) {
      throw StateError(
        'PowerShell exit ${result.exitCode}: '
        '${(result.stderr as String).trim()}',
      );
    }
    final picked = (result.stdout as String).trim();
    return picked.isEmpty ? null : picked;
  }

  Future<void> _reset() async {
    await DownloadService.setCustomDownloadDir(null);
    Toast.success('已恢复默认下载位置（系统下载目录）');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final effective = _effectivePath;
    final subtitle = !_loaded
        ? '正在读取当前下载位置...'
        : switch (effective) {
            null => '当前下载位置不可用',
            _ => '${_custom == null ? '默认' : '自定义'} · $effective',
          };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTile(
          icon: Icons.folder_rounded,
          iconColor: const Color(0xFF00897B),
          title: '下载位置',
          subtitle: subtitle,
          loading: _picking,
          onTap: _pick,
        ),
        if (_custom != null) ...[
          SettingsDivider(),
          SettingsTile(
            icon: Icons.restart_alt_rounded,
            iconColor: const Color(0xFF8D6E63),
            title: '恢复默认下载位置',
            subtitle: '回到系统下载目录',
            onTap: _reset,
          ),
        ],
      ],
    );
  }
}

/// 兜底弹窗的 PowerShell 脚本（WinForms FolderBrowserDialog）。
///
/// [initialDirectory] 里的 `'` 转义为 `''`（PS 单引号字符串规则）。
@visibleForTesting
String buildFolderBrowserScript(String? initialDirectory) {
  final setInitial = initialDirectory == null
      ? ''
      : "\$dlg.SelectedPath = '${initialDirectory.replaceAll("'", "''")}'\n";
  return '''
Add-Type -AssemblyName System.Windows.Forms
\$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
\$dlg.Description = '选择下载位置'
\$dlg.ShowNewFolderButton = \$true
${setInitial}if (\$dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output \$dlg.SelectedPath
}
''';
}

/// 编码 PowerShell 脚本为 `-EncodedCommand` 要求的 Base64(UTF-16LE)。
///
/// 用 Base64 传脚本的动机与 explorer /select 修复相同：Dart Process 的
/// argv 重组与 powershell.exe 的命令行解析对引号/反斜杠的规则不一致，
/// 编码后参数是纯 Base64 字符，从根上绕开全部转义问题。
@visibleForTesting
String encodePowerShellScript(String script) {
  final utf16le = Uint8List.fromList(
    script.codeUnits.expand((u) => [u & 0xFF, (u >> 8) & 0xFF]).toList(),
  );
  return base64Encode(utf16le);
}
