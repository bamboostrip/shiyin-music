import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/android_storage_access.dart';
import '../../services/download_service.dart';
import '../form_factor.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 「下载位置」设置项（Android / 桌面共用）。
///
/// 选中目录写入 [DownloadService.downloadDirOverrideKey]，
/// [DownloadService.downloadDir] 在该平台优先使用；设置后只影响新下载，
/// 已有下载的索引是绝对路径仍有效，且下次对账会按「以文件为准」语义
/// 搬入新目录。
///
/// 平台差异：
/// - 桌面：file_picker 直接给绝对路径，探测可写后保存；
/// - Android：file_picker 选系统公共文件夹只返回路径、不携带 SAF 授权，
///   公共目录的按路径写入需要「所有文件访问」——探测失败时引导用户去
///   系统设置授权后重试；Android 10 没有该开关，给出明确说明；
/// - iOS 等未适配平台不展示本项（见 `download_settings_section.dart`）。
///
/// 与桌面分节的托盘开关同模式：独立小组件自管状态，避免整页改
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

  /// 配置了自定义目录但当前没生效时的可读原因（权限/目录不可写等），
  /// 用于把「不能用」变成可操作的提示，而不是干巴巴一句不可用。
  String? _unavailableReason;
  bool _loaded = false;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final custom = await DownloadService.customDownloadDirOverride();
    String? effective;
    try {
      effective = (await DownloadService().downloadDir()).path;
    } catch (e) {
      // 目录解析失败（自定义位置所在卷未挂载、权限被回收等）：显示不可用态，
      // 用户仍可在此改选或恢复默认。不能回填 custom 冒充生效目录。
      debugPrint('[设置] 解析下载位置失败: $e');
    }
    String? reason;
    if (custom != null && effective != custom) {
      reason = await _diagnoseUnavailable(custom);
    }
    if (!mounted) return;
    setState(() {
      _custom = custom;
      _effectivePath = effective;
      _unavailableReason = reason;
      _loaded = true;
    });
  }

  /// 诊断「自定义目录配置了却没生效」的具体原因（仅展示与日志，不修改设置）。
  Future<String> _diagnoseUnavailable(String custom) async {
    if (!Platform.isAndroid) return '目录无法访问（可能在已拔出的磁盘/共享盘上）';
    final status = await AndroidStorageAccess.status();
    debugPrint(
      '[设置] 自定义下载目录未生效：sdk=${status.sdkInt} '
      'granted=${status.granted} canRequest=${status.canRequest} path=$custom',
    );
    if (!status.granted) {
      return status.canRequest
          ? '未授予「所有文件访问」权限，点此重新授权'
          : '当前系统（Android 10）不支持写入系统文件夹';
    }
    try {
      await DownloadService.ensureWritableDir(custom);
      // 探测能过说明只是上一次解析瞬时时序问题：下次下载会重新生效。
      return '目录可写，重新进入本页可刷新状态';
    } catch (error) {
      debugPrint('[设置] 自定义下载目录探测失败: $error');
      return '目录不可写（云盘/网络位置或已被删除）';
    }
  }

  /// 默认下载位置的用户可读称呼（Android 是应用专属目录，桌面是系统下载目录）。
  String get _defaultLocationLabel =>
      Platform.isAndroid ? '应用专属目录' : '系统下载目录';

  Future<void> _pick() async {
    final custom = _custom;
    // 已配置但没生效：先尝试修复（补齐授权 / 重建目录），而不是让用户
    // 重新选一遍、或者以为设置丢了。
    if (custom != null && _effectivePath != custom) {
      await _repair(custom);
      return;
    }
    await _chooseFolder();
  }

  /// 修复已配置但未生效的自定义目录，成功后刷新状态。
  Future<void> _repair(String custom) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      if (await _ensureWritable(custom)) {
        Toast.success('下载位置已恢复');
      } else {
        Toast.error('该文件夹仍不可用，请重新选择下载位置');
      }
      await _load();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _chooseFolder() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      Toast.info('请选择下载文件夹...');
      String? directory;
      try {
        directory = await FilePicker.getDirectoryPath(
          dialogTitle: '选择下载位置',
          initialDirectory: isDesktopPlatform ? _effectivePath : null,
          lockParentWindow: true,
        );
      } catch (e) {
        // file_picker 的 Windows COM 弹窗偶发 WindowsException（上游
        // 长期存在的线程/初始化类 issue，无稳定复现路径）：降级到
        // PowerShell 的 WinForms FolderBrowserDialog——弹窗机制完全
        // 独立，不受影响；取消返回 null 与主路径语义一致。
        if (!Platform.isWindows) rethrow;
        debugPrint('[设置] 文件夹选择器异常，降级 WinForms 弹窗: $e');
        directory = await _pickDirectoryFallback(_effectivePath);
      }
      if (directory == null) return;
      // 先探测可写再保存：选到不可写目录（权限不足/只读介质）时当场报错，
      // 而不是存下来等下载时才失败。Android 公共目录还需「所有文件访问」，
      // 探测失败时引导授权后重试。
      if (!await _ensureWritable(directory)) return;
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

  /// 探测目录可写；Android 公共目录失败时引导「所有文件访问」授权后重试。
  Future<bool> _ensureWritable(String directory) async {
    try {
      await DownloadService.ensureWritableDir(directory);
      return true;
    } catch (error) {
      debugPrint('[设置] 下载位置不可写: $error');
      if (!Platform.isAndroid) {
        Toast.error('$error');
        return false;
      }
    }
    return _retryWithAndroidPermission(directory);
  }

  /// Android：权限不足导致不可写时的授权引导。
  ///
  /// - 已有「所有文件访问」仍写不进去（卷离线/只读介质）：直接报错；
  /// - Android 10 及没有该开关的 ROM：明确说明不支持，保留默认目录；
  /// - 其余情况：说明用途 → 拉起系统设置 → 返回后按真实状态重试探测。
  Future<bool> _retryWithAndroidPermission(String directory) async {
    final status = await AndroidStorageAccess.status();
    if (!mounted) return false;
    if (status.granted) {
      Toast.error('该文件夹不可写，换一个位置试试');
      return false;
    }
    if (!status.supported) {
      await _showNotice(
        title: '当前系统不支持自定义文件夹',
        message: 'Android 10 不允许应用写入系统公共文件夹，歌曲会继续保存在'
            '应用专属目录。升级到 Android 11 及以上后可改选系统文件夹。',
      );
      return false;
    }
    // Android 11+ 是「所有文件访问」，Android 9 及以下是传统「存储」权限。
    final needsAllFiles = status.sdkInt >= 30;
    final confirmed = await _confirmPermissionDialog(needsAllFiles);
    if (!confirmed || !mounted) return false;
    Toast.info(
      needsAllFiles ? '请在弹出的设置页开启「所有文件访问」' : '请允许时音访问存储',
    );
    final granted = await AndroidStorageAccess.requestAccess().timeout(
      const Duration(minutes: 3),
      onTimeout: () => false,
    );
    if (!mounted) return false;
    if (!granted) {
      Toast.error(
        needsAllFiles
            ? '未获得「所有文件访问」权限，下载位置未更改'
            : '未获得存储权限，下载位置未更改',
      );
      return false;
    }
    try {
      await DownloadService.ensureWritableDir(directory);
      return true;
    } catch (error) {
      debugPrint('[设置] 授权后仍不可写: $error');
      Toast.error('该文件夹不可写（云盘、网络位置不支持），换一个位置试试');
      return false;
    }
  }

  Future<bool> _confirmPermissionDialog(bool needsAllFiles) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(needsAllFiles ? '需要「所有文件访问」权限' : '需要存储权限'),
        content: Text(
          needsAllFiles
              ? '把歌曲保存到系统文件夹（如「音乐」「下载」）需要授予时音'
                  '「所有文件访问」权限。\n\n'
                  '授权后只会把下载的歌曲写入你选择的文件夹，不会读取其他文件；'
                  '也可以随时在系统设置里关闭。'
              : '把歌曲保存到系统文件夹需要授予时音存储权限。\n\n'
                  '授权后只会把下载的歌曲写入你选择的文件夹。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _showNotice({
    required String title,
    required String message,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _reset() async {
    await DownloadService.setCustomDownloadDir(null);
    Toast.success('已恢复默认下载位置（$_defaultLocationLabel）');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final effective = _effectivePath;
    final custom = _custom;
    final customActive = custom != null && effective == custom;
    final subtitle = !_loaded
        ? '正在读取当前下载位置...'
        : switch (effective) {
            null => '当前下载位置不可用',
            _ when custom == null => '默认 · $effective',
            _ when customActive => '自定义 · $effective',
            _ =>
              '自定义目录不可用：${_unavailableReason ?? '未知原因'}'
                  '\n目标：$custom\n暂用默认：$effective',
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
        if (custom != null && !customActive) ...[
          SettingsDivider(),
          // 已配置但未生效时给「修复」与「重新选」两条路，避免用户以为
          // 必须先去系统设置里翻权限。
          SettingsTile(
            icon: Icons.build_circle_outlined,
            iconColor: const Color(0xFF7B1FA2),
            title: '修复下载位置',
            subtitle: '重新授权并检测所选文件夹',
            onTap: () => unawaited(_repair(custom)),
          ),
          SettingsDivider(),
          SettingsTile(
            icon: Icons.drive_file_move_rounded,
            iconColor: const Color(0xFF1E88E5),
            title: '重新选择下载位置',
            subtitle: '当前文件夹不可用，改选其他文件夹',
            onTap: () => unawaited(_chooseFolder()),
          ),
        ],
        if (custom != null) ...[
          SettingsDivider(),
          SettingsTile(
            icon: Icons.restart_alt_rounded,
            iconColor: const Color(0xFF8D6E63),
            title: '恢复默认下载位置',
            subtitle: '回到$_defaultLocationLabel',
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
