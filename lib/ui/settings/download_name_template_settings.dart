import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/download_service.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 「下载文件名」设置项（设置 → 存储与下载）。
///
/// 只决定**新下载**的命名顺序模板（[DownloadNameTemplate]）；已下载文件
/// 不改名。直接读写 prefs、不经 [DownloadController]：模板不进控制器状态，
/// 真正的消费方（DownloadService）在任务执行时自行读取。
class DownloadNameTemplateSettings extends StatefulWidget {
  const DownloadNameTemplateSettings({super.key});

  @override
  State<DownloadNameTemplateSettings> createState() =>
      _DownloadNameTemplateSettingsState();
}

class _DownloadNameTemplateSettingsState
    extends State<DownloadNameTemplateSettings> {
  /// 正在写入设置：忽略重复点击，并在瓦片图标位转圈（对齐下载音质项）。
  bool _saving = false;

  DownloadNameTemplate _template = DownloadNameTemplate.artistTitle;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final template = await DownloadService.loadNameTemplate();
    if (!mounted) return;
    setState(() => _template = template);
  }

  /// 瓦片副标题：模板名 + 示例文件名，一眼看懂各模板的差别。
  String get _subtitle => '${_template.label}（示例：${_template.example}）';

  Future<void> _selectTemplate() async {
    if (_saving) return;
    final selected = await showDialog<DownloadNameTemplate>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载文件名'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RadioGroup<DownloadNameTemplate>(
                groupValue: _template,
                onChanged: (value) {
                  if (value == null) return;
                  Navigator.of(dialogContext).pop(value);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final template in DownloadNameTemplate.values)
                      RadioListTile<DownloadNameTemplate>(
                        value: template,
                        title: Text(template.label),
                        subtitle: Text(
                          '示例：${template.example}'
                          '${template == DownloadNameTemplate.artistTitle ? '（默认）' : ''}',
                        ),
                      ),
                  ],
                ),
              ),
              // 生效范围对四个模板都一样：列在选项外提示一次，不在每条里重复。
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text('仅对新下载生效，已下载文件不改名'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted || selected == _template) return;
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        DownloadService.downloadNameTemplateKey,
        DownloadService.storedNameTemplateValue(selected),
      );
      if (!mounted) return;
      setState(() => _template = selected);
      debugPrint('[设置] 下载文件名模板已更新: ${selected.storedValue}');
    } catch (error) {
      // 写 prefs 失败（存储异常/平台通道异常）时已选模板不会生效，必须
      // 明确提示并对齐到原值，否则用户下次下载才发现命名没变。
      debugPrint('[设置] 保存下载文件名模板失败: $error');
      if (mounted) Toast.error('保存下载文件名设置失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      icon: Icons.drive_file_rename_outline_rounded,
      iconColor: const Color(0xFF00897B),
      title: '下载文件名',
      subtitle: _subtitle,
      loading: _saving,
      onTap: _selectTemplate,
    );
  }
}
