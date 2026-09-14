import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../core/rust_api_client.dart';
import '../../models/song.dart';
import '../../services/identify_service.dart';
import '../widgets/artwork.dart';

/// 识曲采集源。桌面(Windows/Linux)两种都支持;Android 只有麦克风,
/// 切换控件在移动端不显示。
enum _IdentifySource { mic, system }

extension on _IdentifySource {
  /// 采集后端消费的字符串源标识(与 IdentifyCaptureBackend.start 对齐)。
  String get value => this == _IdentifySource.mic ? 'mic' : 'system';
}

/// 识别页状态机阶段。
enum _IdentifyPhase {
  /// 正在聆听采集(脉冲动画 + 已聆听秒数计时)。
  listening,

  /// 停止采集、上传 PCM 识别中(转圈)。
  matching,

  /// 有结果,展示候选列表。
  done,

  /// 识别不到(PCM 空/过短或服务端无候选)。
  empty,

  /// 采集或识别异常。
  error,
}

/// 听歌识曲页面:聆听采集 → 上传识别 → 结果列表 → 点击播放。
///
/// 状态机 listening → matching → done/empty/error:
/// - 打开页面即开始采集,满 12s 自动提交或点"停止识别"手动提交;
/// - matching 阶段 `stopAndCollect` 取末段 PCM(空/过短直接空态,不发请求),
///   再经 [IdentifyService.identify] 上传识别;
/// - 空态/错误态给"重试",回 listening 重新采集。
///
/// 平台支持范围(Android/Windows/Linux,见 [IdentifyService.isSupported])
/// 由入口按钮的显示与否把关:入口隐藏即闸门,本页内部不再兜底。
class IdentifyPage extends StatefulWidget {
  const IdentifyPage({
    super.key,
    required this.player,
    this.api,
    this.captureBackend,
    this.onIdentify,
  });

  /// 点结果行播放用的控制器(播放后整页 pop 回原页面)。
  final PlayerController player;

  /// 识别用客户端;缺省用全局单例([RustApiClient.getInstance],内部有缓存)。
  final RustApiClient? api;

  /// 采集后端;缺省按平台取 [IdentifyService.platformDefault]。
  /// 测试注入 fake 用。
  final IdentifyCaptureBackend? captureBackend;

  /// 识别函数(入参 PCM,返回按置信度降序的候选);缺省走
  /// [IdentifyService.identify]。测试注入 fake 用。
  final Future<List<({Song song, double confidence})>> Function(
    Uint8List pcm,
  )? onIdentify;

  @override
  State<IdentifyPage> createState() => _IdentifyPageState();
}

class _IdentifyPageState extends State<IdentifyPage>
    with SingleTickerProviderStateMixin {
  /// 自动提交时限:满 12s 仍无人点"停止识别"就自动收尾。
  static const _autoSubmitDelay = Duration(seconds: 12);

  /// 单次提交取末段 PCM 的时长(与 IdentifyCaptureBackend 缺省对齐)。
  static const _collectDurationMs = 10000;

  /// 短于该字节数的 PCM 视为"几乎没采到"(8000Hz/16bit/单声道下约 0.5s),
  /// 不请求网络直接空态。
  static const _minPcmBytes = 8000;

  late final IdentifyCaptureBackend _backend;
  late final AnimationController _pulse;

  _IdentifyPhase _phase = _IdentifyPhase.listening;
  _IdentifySource _source = _IdentifySource.mic;
  List<({Song song, double confidence})> _results = const [];
  String? _errorText;
  var _elapsedSeconds = 0;
  Timer? _autoSubmitTimer;
  Timer? _elapsedTimer;

  /// 是否显示 mic/system 源切换(仅桌面;Android 只有麦克风,iOS 等无入口)。
  bool get _showSourceSwitch =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    _backend = widget.captureBackend ?? IdentifyService.platformDefault();
    // 聆听脉冲:1.2s 一轮的 repeat 控制器(测试不能 pumpAndSettle 的原因)。
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _beginListening();
  }

  @override
  void dispose() {
    _autoSubmitTimer?.cancel();
    _elapsedTimer?.cancel();
    _pulse.dispose();
    // 关页一律停采集:桌面 stopAndCollect 只取快照不停流,matching/done/empty
    // 态离开页面也必须 cancel(两端 cancel 均幂等安全,fire-and-forget)。
    unawaited(_backend.cancel());
    super.dispose();
  }

  /// 进入(或重试、切源后重新进入)聆听态:开采集 + 起两个计时器 + 起脉冲。
  void _beginListening() {
    _autoSubmitTimer?.cancel();
    _elapsedTimer?.cancel();
    _elapsedSeconds = 0;
    _autoSubmitTimer = Timer(_autoSubmitDelay, _submit);
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _phase == _IdentifyPhase.listening) {
        setState(() => _elapsedSeconds++);
      }
    });
    _pulse.repeat();
    // fire-and-forget:start 失败(如 Android 麦克风权限被拒)转错误态。
    unawaited(
      _backend.start(source: _source.value).catchError((Object error) {
        if (mounted) _showError(error);
      }),
    );
  }

  /// 提交识别:停止采集取末段 PCM → 上传识别 → 结果/空态/错误。
  /// 手动点"停止识别"与 12s 定时器并发触发,靠阶段守卫防重入。
  Future<void> _submit() async {
    if (_phase != _IdentifyPhase.listening) return;
    _autoSubmitTimer?.cancel();
    _elapsedTimer?.cancel();
    _pulse.stop();
    setState(() => _phase = _IdentifyPhase.matching);
    try {
      final pcm = await _backend.stopAndCollect(durationMs: _collectDurationMs);
      // 双兜底:Android 空缓冲回 null,桌面空缓冲回空表;两者及
      // 过短(<0.5s)的 PCM 都不请求网络,直接空态。
      if (pcm == null || pcm.isEmpty || pcm.length < _minPcmBytes) {
        if (mounted) setState(() => _phase = _IdentifyPhase.empty);
        return;
      }
      final matches =
          await (widget.onIdentify ?? _defaultIdentify)(pcm);
      if (!mounted) return;
      setState(() {
        if (matches.isEmpty) {
          _phase = _IdentifyPhase.empty;
        } else {
          _results = matches;
          _phase = _IdentifyPhase.done;
        }
      });
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  /// 生产识别路径:全局单例客户端(内部缓存,勿重复 init)+ 服务静态方法。
  Future<List<({Song song, double confidence})>> _defaultIdentify(
    Uint8List pcm,
  ) async {
    final api = widget.api ?? await RustApiClient.getInstance();
    return IdentifyService.identify(api, pcm);
  }

  void _showError(Object error) {
    setState(() {
      _phase = _IdentifyPhase.error;
      _errorText = error.toString();
    });
  }

  /// 空态/错误态"重试":清结果回聆听态,重新采集重新计时。
  void _retry() {
    setState(() {
      _phase = _IdentifyPhase.listening;
      _results = const [];
      _errorText = null;
    });
    _beginListening();
  }

  /// 桌面切源:切换即 cancel 旧源采集 → 以新源重新 start(重新计时)。
  Future<void> _switchSource(_IdentifySource source) async {
    if (_source == source || _phase != _IdentifyPhase.listening) return;
    // 先停旧源定时器:await cancel 挂起期间旧源定时器可能到期触发提交(竞态)。
    _autoSubmitTimer?.cancel();
    _elapsedTimer?.cancel();
    setState(() => _source = source);
    await _backend.cancel();
    if (mounted && _phase == _IdentifyPhase.listening) _beginListening();
  }

  /// 点结果行:以全部候选为队列播放,然后整页关掉(识曲流程结束)。
  void _playResult(({Song song, double confidence}) entry) {
    final queue = _results.map((m) => m.song).toList();
    widget.player.playSong(entry.song, queue: queue);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌识曲'),
        leading: IconButton(
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            // 关页/返回一律停采集,dispose 再兜底。
            unawaited(_backend.cancel());
            Navigator.of(context).maybePop();
          },
        ),
        actions: [
          // 桌面源切换:麦克风 / 系统内录;仅聆听态可切,Android 不显示。
          if (_showSourceSwitch && _phase == _IdentifyPhase.listening) ...[
            IconButton(
              tooltip: '识别麦克风声音',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.mic_rounded,
                color: _source == _IdentifySource.mic
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              onPressed: () => _switchSource(_IdentifySource.mic),
            ),
            IconButton(
              tooltip: '识别本机播放的声音',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.speaker_rounded,
                color: _source == _IdentifySource.system
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              onPressed: () => _switchSource(_IdentifySource.system),
            ),
          ],
          const SizedBox(width: 4),
        ],
      ),
      body: switch (_phase) {
        _IdentifyPhase.listening => _buildListeningBody(context),
        _IdentifyPhase.matching => _buildMatchingBody(context),
        _IdentifyPhase.done => _buildResultsBody(context),
        _IdentifyPhase.empty => _buildEmptyBody(context),
        _IdentifyPhase.error => _buildErrorBody(context),
      },
    );
  }

  // ---- 聆听态 ----

  Widget _buildListeningBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 168,
            height: 168,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 涟漪外圈:随 1.2s 周期放大淡出,营造"正在听"的呼吸感。
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) {
                    final t = _pulse.value;
                    return Opacity(
                      opacity: (1 - t) * 0.35,
                      child: Transform.scale(
                        scale: 1 + t * 0.45,
                        child: child,
                      ),
                    );
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colorScheme.primary.withValues(alpha: .25),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                // 中心圆 + 麦克风图标,随周期轻微缩放。
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) => Transform.scale(
                    scale: 1 + _pulse.value * 0.06,
                    child: child,
                  ),
                  child: Container(
                    width: 128,
                    height: 128,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colorScheme.primaryContainer,
                    ),
                    child: Icon(
                      Icons.mic_rounded,
                      size: 56,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            // 提示语随源切换:桌面系统内录与本机播放声音对应。
            _source == _IdentifySource.mic
                ? '正在聆听,请靠近音源…'
                : '正在识别本机播放的声音…',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            '已聆听 $_elapsedSeconds 秒(12 秒后自动识别)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('停止识别'),
          ),
        ],
      ),
    );
  }

  // ---- 匹配态 ----

  Widget _buildMatchingBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            '正在识别…',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  // ---- 结果态 ----

  Widget _buildResultsBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _results.length + 1,
      itemBuilder: (context, index) {
        // 首行放小标题,后面是候选行(置信度降序,IdentifyService 已排好)。
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              '识别结果(为你找到 ${_results.length} 首)',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          );
        }
        return _ResultRow(
          entry: _results[index - 1],
          onTap: () => _playResult(_results[index - 1]),
        );
      },
    );
  }

  // ---- 空态 / 错误态 ----

  Widget _buildEmptyBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.music_off_rounded,
            size: 56,
            color: colorScheme.onSurfaceVariant.withValues(alpha: .6),
          ),
          const SizedBox(height: 14),
          Text(
            '未识别到歌曲',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '请靠近音源后重试',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: colorScheme.error,
            ),
            const SizedBox(height: 14),
            Text(
              '识别失败',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              _errorText ?? '出错了,请重试',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 识别结果行:封面 + 歌名/歌手 + 右侧置信度(≥40% 显示百分比,更低显示"较低")。
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.entry, required this.onTap});

  final ({Song song, double confidence}) entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final song = entry.song;
    // 置信度展示:百分比取整;低于 40% 换成"较低",避免误导用户。
    final confidence = entry.confidence;
    final confidenceText = confidence < 0.4
        ? '较低'
        : '${(confidence * 100).toStringAsFixed(0)}%';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Artwork(url: song.coverUrl, size: 52, borderRadius: 8),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              confidenceText,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: confidence < 0.4
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
