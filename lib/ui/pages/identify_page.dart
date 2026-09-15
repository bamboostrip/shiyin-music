import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../core/rust_api_client.dart';
import '../../models/music_models.dart';
import '../../services/identify_service.dart';
import '../../services/music_api.dart';
import '../form_factor.dart';
import '../widgets/mini_player.dart';
import '../widgets/toast.dart';
import 'artist_detail_page.dart';
import 'search_song_results.dart';

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
/// - 打开页面即开始采集,满 10s 自动提交或随时点"立即识别"手动提交;
/// - matching 阶段 `stopAndCollect` 取末段 PCM(空/过短直接空态,不发请求),
///   再经 [IdentifyService.identify] 上传识别;
/// - 空态/错误态给"再试一次",回 listening 重新采集;失败页文案保持
///   友好口语化,不向用户暴露字节/异常等技术细节(细节只进日志)。
///
/// 平台支持范围(Android/Windows/Linux,见 [IdentifyService.isSupported])
/// 由入口按钮的显示与否把关:入口隐藏即闸门,本页内部不再兜底。
class IdentifyPage extends StatefulWidget {
  const IdentifyPage({
    super.key,
    required this.player,
    this.auth,
    this.musicApi,
    this.onViewArtist,
    this.api,
    this.captureBackend,
    this.onIdentify,
  });

  /// 点结果行播放用的控制器。
  final PlayerController player;

  /// 用户认证控制器（收藏/加歌单等操作）；缺省时使用内置 fallback。
  final AuthController? auth;

  /// 音乐 API（查看歌手等操作）。
  final MusicApi? musicApi;

  /// 查看歌手外部回调（若提供则优先调用）。
  final void Function(Song song)? onViewArtist;

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
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// 自动提交时限:满 10s 仍无人手动点击"立即识别"就自动收尾。
  static const _autoSubmitDelay = Duration(seconds: 10);

  /// 建议的最短录音时长(3 秒)，达到后主操作按钮变为醒目的"立即识别"。
  static const _minManualSeconds = 3;

  /// 单次提交取末段 PCM 的时长(与 IdentifyCaptureBackend 缺省对齐)。
  static const _collectDurationMs = 10000;

  /// 短于该字节数的 PCM 视为"几乎没采到"(8000Hz/16bit/单声道下约 0.5s),
  /// 不请求网络直接空态。
  static const _minPcmBytes = 8000;

  late final IdentifyCaptureBackend _backend;
  late final AnimationController _pulse;
  late final AuthController _auth = widget.auth ?? _FallbackAuthController();

  _IdentifyPhase _phase = _IdentifyPhase.listening;
  _IdentifySource _source = _IdentifySource.mic;
  List<({Song song, double confidence})> _results = const [];
  var _elapsedSeconds = 0;
  var _lastPcmBytes = 0;
  Timer? _autoSubmitTimer;
  Timer? _elapsedTimer;

  /// 在途的采集 start（null = 当前没有待收尾的 start）。
  /// dispose/后台切换时的 cancel 必须排在它完成后：两条 FRB 调用在 Rust
  /// 线程池上相互独立，cancel 先于 start 落地的话，流会在页面死后才启动，
  /// 麦克风指示灯常亮到下一次识曲或进程退出。
  Future<void>? _startFuture;

  /// 采集启停串行链：所有 cancel 追加到队尾，后续 start 排在链上——
  /// 保证「上一次 cancel」永远先于「下一次 start」生效，不会误杀新流。
  Future<void> _captureTeardown = Future.value();

  /// 是否显示 mic/system 源切换(仅桌面形态;Android/移动形态只有麦克风)。
  bool get _showSourceSwitch =>
      !kIsWeb && isDesktopFormFactor && (Platform.isWindows || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    _autoSubmitTimer?.cancel();
    _elapsedTimer?.cancel();
    _pulse.dispose();
    // 关页一律停采集:桌面 stopAndCollect 只取快照不停流,matching/done/empty
    // 态离开页面也必须 cancel(两端 cancel 均幂等安全)。cancel 排队在
    // 在途 start 之后,不留无主采集流。
    _cancelCapture();
    super.dispose();
  }

  /// 后台静默期处理:Android 12+ 切后台会悄悄切断麦克风,留在 listening
  /// 只会让 10s 自动提交白跑一趟网络(录到静音/空数据)。退后台即停采集
  /// 与计时,回前台重新开一轮完整聆听窗口。
  ///
  /// 只响应 paused/hidden(完全不可见):inactive 在权限弹窗等瞬态遮挡时
  /// 也会触发,此时采集尚未开始/正在进行,不能打断。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_phase == _IdentifyPhase.listening) {
        _autoSubmitTimer?.cancel();
        _elapsedTimer?.cancel();
        _cancelCapture();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (mounted && _phase == _IdentifyPhase.listening) {
        _beginListening();
      }
    }
  }

  /// 取消当前采集:排在任何在途 start 之后,并把后续 start 挡在自己后面。
  void _cancelCapture() {
    final pendingStart = _startFuture;
    _startFuture = null;
    _captureTeardown = _captureTeardown.then((_) async {
      if (pendingStart != null) {
        try {
          await pendingStart;
        } catch (_) {
          // start 自身失败已有错误态处理,这里只保证时序。
        }
      }
      try {
        await _backend.cancel();
      } catch (_) {
        // cancel 幂等;后端已释放时忽略。
      }
    });
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
    debugPrint('[IdentifyPage] 开始采集: source=${_source.value}');
    // 排在 teardown 链之后启动(防旧 cancel 误杀新流);fire-and-forget:
    // start 失败(如 Android 麦克风权限被拒)转错误态。
    unawaited(
      _captureTeardown.then((_) async {
        if (!mounted || _phase != _IdentifyPhase.listening) return;
        final start = _backend.start(source: _source.value);
        _startFuture = start;
        try {
          await start;
        } catch (error) {
          if (mounted) _showError(error);
        }
      }),
    );
  }

  /// 提交识别:停止采集取末段 PCM → 上传识别 → 结果/空态/错误。
  /// 手动点"立即识别"与自动定时器并发触发,靠阶段守卫防重入。
  Future<void> _submit() async {
    if (_phase != _IdentifyPhase.listening) return;
    _autoSubmitTimer?.cancel();
    _elapsedTimer?.cancel();
    _pulse.stop();
    setState(() => _phase = _IdentifyPhase.matching);
    debugPrint('[IdentifyPage] 提交识别: 采集时长=$_elapsedSeconds 秒, source=${_source.value}');
    try {
      final pcm = await _backend.stopAndCollect(durationMs: _collectDurationMs);
      _lastPcmBytes = pcm?.length ?? 0;
      debugPrint('[IdentifyPage] 采集到的 PCM 大小: $_lastPcmBytes 字节 (判定阈值: $_minPcmBytes 字节)');
      // 双兜底:Android 空缓冲回 null,桌面空缓冲回空表;两者及
      // 过短(<0.5s)的 PCM 都不请求网络,直接空态。
      if (pcm == null || pcm.isEmpty || pcm.length < _minPcmBytes) {
        debugPrint('[IdentifyPage] 采集字节数不足，直接进入空态');
        if (mounted) setState(() => _phase = _IdentifyPhase.empty);
        return;
      }
      debugPrint('[IdentifyPage] 上传 PCM 请求识别中...');
      final matches =
          await (widget.onIdentify ?? _defaultIdentify)(pcm);
      if (!mounted) return;
      debugPrint('[IdentifyPage] 识别成功，候选歌曲数: ${matches.length}');
      setState(() {
        if (matches.isEmpty) {
          _phase = _IdentifyPhase.empty;
        } else {
          _results = matches;
          _phase = _IdentifyPhase.done;
        }
      });
    } catch (error) {
      debugPrint('[IdentifyPage] 识别异常: $error');
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
    // 错误态不再聆听:停掉脉冲,否则错误页以 60fps 空转到关闭。
    _pulse.stop();
    // 原始异常只进日志;页面文案见 _buildErrorBody(不向用户暴露细节)。
    debugPrint('[IdentifyPage] 识别异常: $error');
    setState(() => _phase = _IdentifyPhase.error);
  }

  /// 空态/错误态"重试":清结果回聆听态,重新采集重新计时。
  void _retry() {
    setState(() {
      _phase = _IdentifyPhase.listening;
      _results = const [];
    });
    _beginListening();
  }

  /// 桌面切源:切换即 cancel 旧源采集 → 以新源重新 start(重新计时)。
  Future<void> _switchSource(_IdentifySource source) async {
    if (_source == source || _phase != _IdentifyPhase.listening) return;
    debugPrint('[IdentifyPage] 切换采集源: 从 ${_source.value} 切换到 ${source.value}');
    // 先停旧源定时器:await cancel 挂起期间旧源定时器可能到期触发提交(竞态)。
    _autoSubmitTimer?.cancel();
    _elapsedTimer?.cancel();
    setState(() => _source = source);
    _cancelCapture();
    await _captureTeardown;
    if (mounted && _phase == _IdentifyPhase.listening) _beginListening();
  }

  /// 播放结果歌曲：以全部候选为队列直接交由 player 播放，保持留在识曲结果页内试听。
  void _playSong(Song song) {
    final queue = _results.map((m) => m.song).toList();
    widget.player.playSong(song, queue: queue);
  }

  /// 查看歌手主页。
  void _openArtist(Song song) {
    if (widget.onViewArtist != null) {
      widget.onViewArtist!(song);
      return;
    }
    if (song.source != SongSource.kugou) {
      Toast.info('其他平台歌曲暂不支持查看歌手');
      return;
    }
    final artist = song.artists.firstWhere(
      (a) => a.name.isNotEmpty,
      orElse: () => ArtistRef(id: '', name: song.artist),
    );
    if (artist.name.isEmpty) {
      Toast.info('未找到该歌手信息');
      return;
    }
    if (widget.musicApi == null) {
      Toast.info('暂无法查看歌手主页');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtistDetailPage(
          api: widget.musicApi!,
          auth: _auth,
          artist: artist,
          player: widget.player,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌识曲'),
        centerTitle: !isDesktopFormFactor,
        leading: IconButton(
          tooltip: '返回',
          icon: Icon(
            isDesktopFormFactor
                ? Icons.arrow_back_rounded
                : Icons.arrow_back_ios_new_rounded,
            size: 20,
          ),
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
              tooltip: '使用麦克风 (听周围声音)',
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
              tooltip: '使用电脑声音 (系统内录)',
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
      body: Stack(
        children: [
          Positioned.fill(
            child: switch (_phase) {
              _IdentifyPhase.listening => _buildListeningBody(context),
              _IdentifyPhase.matching => _buildMatchingBody(context),
              _IdentifyPhase.done => _buildResultsBody(context),
              _IdentifyPhase.empty => _buildEmptyBody(context),
              _IdentifyPhase.error => _buildErrorBody(context),
            },
          ),
          if (!isDesktopFormFactor && _phase == _IdentifyPhase.done)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 8,
              child: MiniPlayerSlot(player: widget.player, auth: _auth),
            ),
        ],
      ),
    );
  }

  // ---- 聆听态 ----

  Widget _buildRipple(double phaseOffset, Color color) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = (_pulse.value + phaseOffset) % 1.0;
        final curveValue = Curves.easeOutCubic.transform(t);
        final scale = 0.65 + curveValue * 0.75;
        final opacity = ((1.0 - curveValue) * 0.35).clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: color,
                  width: 2.0,
                ),
                color: color.withValues(alpha: 0.08),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildListeningBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 桌面端源切换控件(突出显示,方便用户明确当前是麦克风还是系统内录)
            if (_showSourceSwitch) ...[
              SegmentedButton<_IdentifySource>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: _IdentifySource.mic,
                    icon: Icon(Icons.mic_rounded),
                    label: Text('麦克风声音 (听环境音)'),
                  ),
                  ButtonSegment(
                    value: _IdentifySource.system,
                    icon: Icon(Icons.speaker_rounded),
                    label: Text('电脑声音 (系统内录)'),
                  ),
                ],
                selected: {_source},
                onSelectionChanged: (selected) {
                  if (selected.isNotEmpty) {
                    _switchSource(selected.first);
                  }
                },
              ),
              const SizedBox(height: 36),
            ],
            SizedBox(
              width: 220,
              height: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 3 层扩散涟漪，随 1.2s 周期错开相位外扩并淡出
                  _buildRipple(0.0, colorScheme.primary),
                  _buildRipple(0.33, colorScheme.primary),
                  _buildRipple(0.66, colorScheme.primary),
                  // 中心圆 + 渐变与呼吸投影
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, child) => Transform.scale(
                      scale: 1.0 + math.sin(_pulse.value * math.pi) * 0.04,
                      child: child,
                    ),
                    child: Container(
                      width: 124,
                      height: 124,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            colorScheme.primary,
                            colorScheme.primary.withValues(alpha: 0.82),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: colorScheme.primary.withValues(
                              alpha: isDark ? 0.45 : 0.3,
                            ),
                            blurRadius: 28,
                            spreadRadius: 2,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Icon(
                          _source == _IdentifySource.mic
                              ? Icons.graphic_eq_rounded
                              : Icons.speaker_rounded,
                          size: 54,
                          color: colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            Text(
              _source == _IdentifySource.mic
                  ? '正在识别音乐…'
                  : '正在捕获电脑当前播放的声音…',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
            ),
            const SizedBox(height: 10),
            Text(
              _elapsedSeconds < _minManualSeconds
                  ? (_source == _IdentifySource.system
                      ? '请确保电脑正在播放音乐…'
                      : '请靠近音源并保持安静…')
                  : '已聆听 $_elapsedSeconds 秒，随时可点击“立即识别”',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
                  ),
            ),
            const SizedBox(height: 32),
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              height: 48,
              child: _elapsedSeconds >= _minManualSeconds
                  ? FilledButton.icon(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        shape: const StadiumBorder(),
                        elevation: 2,
                      ),
                      icon: const Icon(Icons.auto_awesome_rounded, size: 20),
                      label: const Text(
                        '立即识别',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        shape: const StadiumBorder(),
                      ),
                      icon: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: _elapsedSeconds / _minManualSeconds,
                          color: colorScheme.primary,
                        ),
                      ),
                      label: Text(
                        '正在聆听 ($_elapsedSeconds 秒)',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            Text(
              _elapsedSeconds >= _minManualSeconds
                  ? '已录制 $_elapsedSeconds 秒音频，随时可提交'
                  : '建议录制 3 秒以上以获得更准确的匹配结果',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
            ),
          ],
        ),
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
    final songs = _results.map((m) => m.song).toList();
    final topConfidence = _results.isNotEmpty ? _results.first.confidence : 0.0;
    final hasHighConfidence = topConfidence >= 0.4;
    final confidencePct = (topConfidence * 100).toStringAsFixed(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      '识别结果 (为你找到 ${_results.length} 首)',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    if (hasHighConfidence)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '最佳匹配 $confidencePct%',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
                onPressed: _retry,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重新识别', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
        Expanded(
          child: SearchSongResults(
            songs: songs,
            onPlay: _playSong,
            isLiked: (song) => _auth.isLiked(song),
            onLikeTap: (song) => _auth.toggleLike(song),
            auth: _auth,
            player: widget.player,
            onViewArtist: _openArtist,
          ),
        ),
      ],
    );
  }

  // ---- 空态 / 错误态 ----

  /// 空态/错误态共用的柔和版式：圆形浅色底 + 图标 + 一句话说明 + 重试按钮。
  /// 面向用户的文案不出现任何技术细节（字节数/异常堆栈等）。
  Widget _buildFriendlyStatusBody(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required Color circleColor,
    required String title,
    required String hint,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(shape: BoxShape.circle, color: circleColor),
              child: Icon(icon, size: 44, color: iconColor),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _retry,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                shape: const StadiumBorder(),
              ),
              child: const Text('再试一次'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSystem = _source == _IdentifySource.system;
    final isTooShort = _lastPcmBytes < _minPcmBytes;

    final String hint;
    if (isSystem) {
      hint = isTooShort
          ? '没有听到电脑正在播放的声音\n请确认电脑正在播放音乐后再试'
          : '没有认出这首歌\n换一段更清晰的歌曲片段试试吧';
    } else {
      hint = isTooShort
          ? '周围好像没什么声音\n请靠近音源，多听几秒再试'
          : '这首歌没有听出来\n离音源近一点，避开嘈杂环境再试试';
    }

    return _buildFriendlyStatusBody(
      context,
      icon: Icons.music_off_rounded,
      iconColor: colorScheme.onSurfaceVariant,
      circleColor: colorScheme.surfaceContainerHighest.withValues(alpha: .6),
      title: '没听出这首歌',
      hint: hint,
    );
  }

  Widget _buildErrorBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 原始异常只进日志，不展示给用户。
    return _buildFriendlyStatusBody(
      context,
      icon: Icons.cloud_off_rounded,
      iconColor: colorScheme.error.withValues(alpha: .85),
      circleColor: colorScheme.errorContainer.withValues(alpha: .45),
      title: '识别失败了',
      hint: '可能是网络不太顺畅\n请稍后再试一次',
    );
  }
}

/// 当未传入外部 AuthController 时使用的无操作 Fallback 实现。
class _FallbackAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  Future<void> toggleLike(Song song) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
