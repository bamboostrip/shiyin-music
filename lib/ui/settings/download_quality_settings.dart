import 'package:flutter/material.dart';

import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 「下载音质」设置项（设置 → 下载）。
///
/// 与「播放」分节的「默认音质」是两件事：那边决定**在线播放**取哪一档，
/// 这里只决定**下载**落哪一档，所以多一个「跟随播放音质」选项（默认）。
/// 默认跟随等价于加本设置前的版本，老用户升级后无感；选了固定档位后，
/// 播放音质怎么改都不再影响下载。
///
/// 生效档位由 [DownloadController.resolveDownloadQuality] 在控制器内部
/// 解析，11 处下载入口继续传 `player.audioQuality`，本组件只管写入设置。
class DownloadQualitySettings extends StatefulWidget {
  const DownloadQualitySettings({
    super.key,
    required this.downloads,
    required this.player,
  });

  final DownloadController downloads;

  /// 只用来显示「跟随」态下的当前播放音质。
  final PlayerController player;

  @override
  State<DownloadQualitySettings> createState() =>
      _DownloadQualitySettingsState();
}

class _DownloadQualitySettingsState extends State<DownloadQualitySettings> {
  /// 正在写入设置：忽略重复点击，并在瓦片图标位转圈。
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 必须监听 controller：[DownloadController.initialize] 在首帧之后才
    // 异步读 prefs，不监听的话进设置页看到的是「跟随」旧值，用户会以为
    // 自己设置的档位丢了。
    widget.downloads.addListener(_handleChanged);
    // 副标题里的「当前 X」取自播放音质：播放页改了默认音质后回到设置页，
    // 这里要立刻是新的档位。
    widget.player.addListener(_handleChanged);
  }

  @override
  void didUpdateWidget(covariant DownloadQualitySettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 控制器实例被换掉（整页重建时新建了 controller）时换绑监听，否则
    // 新 controller 的通知收不到、旧 controller 的通知会打到已失效状态。
    if (!identical(oldWidget.downloads, widget.downloads)) {
      oldWidget.downloads.removeListener(_handleChanged);
      widget.downloads.addListener(_handleChanged);
    }
    if (!identical(oldWidget.player, widget.player)) {
      oldWidget.player.removeListener(_handleChanged);
      widget.player.addListener(_handleChanged);
    }
  }

  @override
  void dispose() {
    widget.downloads.removeListener(_handleChanged);
    widget.player.removeListener(_handleChanged);
    super.dispose();
  }

  void _handleChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 当前生效设置的用户可读说明。
  ///
  /// 跟随态直接报出当前档位，用户不用再去播放分节对照「默认音质」；固定
  /// 档位用「音质名（徽标）」，与已下载列表的音质徽标文案保持一致。
  String get _subtitle {
    final override = widget.downloads.downloadQualityOverride;
    if (override == null) {
      return '跟随播放音质（当前 ${widget.player.audioQuality.badge}）';
    }
    return '${override.label}（${override.badge}）';
  }

  Future<void> _selectQuality() async {
    if (_saving) return;
    final current = widget.downloads.downloadQualityOverride;
    final playback = widget.player.audioQuality;
    final choices = <_QualityChoice>[
      _QualityChoice(
        quality: null,
        title: '跟随播放音质',
        subtitle: '当前：${playback.label}（${playback.badge}）；'
            '播放音质变了下载也跟着变',
      ),
      const _QualityChoice(
        quality: AudioQuality.standard,
        title: '标准音质 · 128K',
        subtitle: '省流量，文件最小',
      ),
      const _QualityChoice(
        quality: AudioQuality.high,
        title: '高品音质 · 320K',
        subtitle: '推荐；体积与音质均衡',
      ),
      const _QualityChoice(
        quality: AudioQuality.lossless,
        title: '无损音质 · FLAC',
        subtitle: '单曲约 30–50MB；该曲无无损源时自动降级',
      ),
    ];
    // radio 的值用列表下标而不是 AudioQuality?：null 既表示「跟随」又是
    // showDialog 的「取消」，直接拿可空音质当值会让用户点「跟随」时被当成
    // 取消，回不到跟随。
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载音质'),
        content: SingleChildScrollView(
          child: RadioGroup<int>(
            groupValue: choices.indexWhere(
              (choice) => choice.quality == current,
            ),
            onChanged: (index) {
              if (index == null) return;
              Navigator.of(dialogContext).pop(index);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < choices.length; i++)
                  RadioListTile<int>(
                    value: i,
                    title: Text(choices[i].title),
                    subtitle: Text(choices[i].subtitle),
                  ),
              ],
            ),
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
    if (selected == null || !mounted) return; // null = 用户取消
    final quality = choices[selected].quality;
    setState(() => _saving = true);
    try {
      await widget.downloads.setDownloadQuality(quality);
      // 设置成功由 controller 的 notifyListeners 触发重建，这里只留日志，
      // 便于「设置 → 应用 → 运行日志与诊断」里排查用户到底选了什么。
      debugPrint('[设置] 下载音质已更新: ${quality?.label ?? '跟随播放音质'}');
    } catch (error) {
      // 写 prefs 失败（存储异常/平台通道异常）时已选档位不会生效，必须
      // 明确提示，否则用户下次下载才发现音质没变。
      debugPrint('[设置] 保存下载音质失败: $error');
      if (mounted) Toast.error('保存下载音质失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      icon: Icons.graphic_eq_rounded,
      iconColor: const Color(0xFF5E35B1),
      title: '下载音质',
      subtitle: _subtitle,
      loading: _saving,
      onTap: _selectQuality,
    );
  }
}

/// 弹窗里的一档下载音质；[quality] 为 null 表示「跟随播放音质」。
class _QualityChoice {
  const _QualityChoice({
    required this.quality,
    required this.title,
    required this.subtitle,
  });

  final AudioQuality? quality;
  final String title;
  final String subtitle;
}
