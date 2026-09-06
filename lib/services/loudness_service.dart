import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/rust/api.dart' as rust;

/// 响度均衡服务:基于 EBU R128 K-weighted LUFS 分析并应用增益,
/// 消除歌曲间音量差异(避免忽大忽小)。
///
/// 应用策略(详见 [applyGain]):
/// - gain > 0(轻歌放大):Android 用原生 [LoudnessEnhancer],iOS/桌面无放大能力。
/// - gain <= 0(响歌衰减):两端统一用 [AudioPlayer.setVolume]。
///
/// 分析采用**渐进式**:原生解码过程中每 [progressIntervalMs] 推一次"截至当前"
/// 的 LUFS(算法上正确,integratedLufs 在任何时刻都能基于已累积 block 算出
/// 真实值),Dart 侧立即算出增益并渐变应用。用户 0.5s 即可听到"大致均衡",
/// 不必等全曲分析完(全曲分析需 1-3s)。最终全曲分析完成时,用精确值做最后
/// 一次微调并写缓存。
///
/// 分析结果按 `song.hash` 缓存到 SharedPreferences(LRU 有上限),避免重复分析。
class LoudnessService {
  LoudnessService() {
    _registerProgressHandler();
  }

  static const _channel = MethodChannel('kgka_music_hl/audio_effects');
  static const _cacheKey = 'loudness_cache';
  static const _enabledKey = 'loudness_enabled';

  /// 目标响度(LUFS)。Spotify/Apple 流媒体标准约 -14 LUFS。
  static const double targetLufs = -14.0;

  /// 缓存条目上限,超过则淘汰最久未写入的(简单 LRU,Map 按插入序遍历)。
  static const int _maxCacheSize = 1000;

  /// 增益钳制上限(±dB)。超过则裁剪,避免动态大的歌被推到过载发紧。
  /// Spotify/Apple 的标准化都有限幅,不会无脑放大。
  static const double _maxGainDb = 6.0;

  /// 增益渐变时长(ms)。分析完成瞬间切换增益会有"音量突然塌下去"的突兀感,
  /// 用此时长平滑过渡到目标音量,人耳对 250ms 内的渐变几乎无感。
  static const int _rampDurationMs = 250;

  /// 中途进度推送间隔(ms)。原生解码每满此时长推一次"截至当前"的 LUFS。
  /// 500ms 兼顾及时性与开销:0.5s 即有初步增益,且不会因推送太频繁打断解码。
  static const int _progressIntervalMs = 500;

  /// 中途增益微调阈值(dB)。新增益与当前应用增益差异超过此值才重新渐变应用,
  /// 避免微小波动(<0.3dB,人耳几乎不可辨)频繁触发 ramp。
  static const double progressGainThreshold = 0.3;

  /// 渡口效应缓解:分析开始后前 [earlyProgressWallMs] 毫秒(墙钟时间)的中途
  /// 增益做 EMA 低通滤波。
  /// 渡口等歌前奏安静,初步 LUFS 偏低导致增益被推到极限,随分析推进大幅回落。
  /// 注意:必须用墙钟时间而非解码音频时长——解码远快于实时(27x),3s 音频在
  /// ~110ms 墙钟内就解码完,若按音频时长滤波,EMA 窗口在用户听到第一个进度时
  /// 就已关闭。按墙钟时间则覆盖用户实际听到的前 3 秒播放。
  static const int earlyProgressWallMs = 3000;

  /// EMA 平滑系数(α)。α 越小越平滑(响应慢但跳变小),越大越跟随(响应快但跳变大)。
  /// 0.3 表示新值权重 30%、历史值权重 70%,对 +6→+1.69 这种 4.3dB 跳变
  /// 会平滑到约 +3.9dB(首次)→ +3.0dB(二次),用户可感但不再突兀。
  static const double emaAlpha = 0.3;

  /// 详细日志开关。测试阶段开启,通过 `adb logcat -s flutter` 查看 [loudness]
  /// 前缀日志,确认响度分析/应用是否正常工作。正式发布可置 false 关闭。
  static bool verboseLog = false;

  /// 统一日志输出(print 而非 debugPrint,确保 release 打包也能在 adb logcat 看到,
  /// tag 为 flutter)。用 [loudness] 前缀方便 `adb logcat -s flutter | grep loudness` 过滤。
  static void log(String msg) {
    if (verboseLog) {
      // ignore: avoid_print
      print('[loudness] $msg');
    }
  }

  final Map<String, double> _cache = {}; // hash → measured lufs
  bool _enabled = false;
  bool _initialized = false;
  // setVolume 渐变定时器,新 ramp 开始前取消旧的,保证只有一条 ramp 在跑。
  Timer? _volumeRampTimer;

  /// 当前活跃的渐进式分析进度回调。同一时刻只允许一个分析在途(切歌时由
  /// controller 调 cancelAnalysis 取消旧的)。原生反向 invokeMethod
  /// 'onLoudnessProgress' 到来时,若此回调非空则调用。
  void Function(double lufs, int analyzedMs)? _activeProgressCallback;

  bool get isEnabled => _enabled;
  bool get isInitialized => _initialized;

  /// 注册反向 MethodChannel handler,接收原生推送的中途响度进度。
  /// 原生在解码循环里每 [progressIntervalMs] 调一次 invokeMethod
  /// 'onLoudnessProgress',这里收到后转发给当前活跃的回调。
  /// controller 侧用序号守卫决定是否应用(切歌后旧回调应被丢弃)。
  void _registerProgressHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onLoudnessProgress':
          final args = call.arguments as Map?;
          if (args == null) return null;
          final lufs = (args['lufs'] as num?)?.toDouble();
          final analyzedMs = (args['analyzedMs'] as num?)?.toInt();
          if (lufs == null || !lufs.isFinite || analyzedMs == null) return null;
          // 转发给当前活跃回调。controller 在启动分析时设置回调,
          // 切歌/取消时清空,从而丢弃旧分析的中途进度。
          final cb = _activeProgressCallback;
          if (cb != null) {
            cb(lufs, analyzedMs);
          }
          return null;
        default:
          return null;
      }
    });
  }

  /// 清空全部响度分析缓存(供设置页"缓存管理"调用)。下次播放会重新分析。
  Future<void> clearCache() async {
    _cache.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
  }

  /// 缓存条目数(供 UI 展示)。
  int get cacheCount => _cache.length;

  /// 快速查缓存计算增益(已钳制),不触发原生分析。
  /// 命中返回 (gainDb, true);未命中返回 (null, false)。
  /// 供 controller 在"首播前"判断:命中则首播即应用正确增益(instant),
  /// 未命中才在播放中分析后渐变应用。
  ({double? gainDb, bool fromCache}) gainFromCache(String songHash) {
    if (!_enabled || songHash.isEmpty) return (gainDb: null, fromCache: false);
    final cached = _cache[songHash];
    if (cached == null) {
      log('cache MISS hash=${_shortHash(songHash)} → 需原生分析');
      return (gainDb: null, fromCache: false);
    }
    final gain = _clampedGainFromLufs(cached);
    log('cache HIT hash=${_shortHash(songHash)} lufs=${cached.toStringAsFixed(1)} gain=${gain.toStringAsFixed(2)}dB');
    return (gainDb: gain, fromCache: true);
  }

  /// hash 截短显示(日志可读性),取前 8 位足够区分。
  static String _shortHash(String hash) =>
      hash.length > 8 ? hash.substring(0, 8) : hash;

  /// 是否支持原生 LUFS 分析。
  ///
  /// - Android/iOS：MethodChannel 原生实现（LoudnessAnalyzer.kt / Swift）。
  /// - Windows/Linux：Rust 引擎（symphonia 解码 + 同款 EBU R128 计量，
  ///   见 rust/src/services/loudness.rs，算法与 Android 1:1 对齐）。
  /// - macOS：Rust 引擎未接入 Xcode 构建（见 form_factor.dart 的 macOS
  ///   适配清单），不支持；Web 不支持。
  bool get isAnalysisSupported {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return true;
    }
    return Platform.isWindows || Platform.isLinux;
  }

  /// 桌面（Windows/Linux）走 Rust 引擎分析通道。
  static bool get _useRustAnalyzer {
    assert(!kIsWeb);
    return Platform.isWindows || Platform.isLinux;
  }

  /// 初始化:加载缓存与开关状态。
  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? false;
    final json = prefs.getString(_cacheKey);
    if (json != null) {
      try {
        final map = jsonDecode(json) as Map<String, dynamic>;
        _cache.addAll(map.map((k, v) => MapEntry(k, (v as num).toDouble())));
      } catch (_) {
        // 缓存损坏,忽略
      }
    }
    _initialized = true;
  }

  /// 开关响度均衡。关闭时立即重置增益。
  Future<void> setEnabled({
    required bool enabled,
    required AudioPlayer audioPlayer,
    int? audioSessionId,
  }) async {
    if (_enabled == enabled) return;
    _enabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    if (!enabled) {
      await resetGain(
        audioPlayer: audioPlayer,
        audioSessionId: audioSessionId,
      );
    }
  }

  /// 由实测 LUFS 计算应用增益,并钳制到 [_maxGainDb]。
  /// 缓存里始终存原始 LUFS,钳制只发生在计算 gain 这一步,
  /// 保证存储值、UI 显示、实际应用三者一致。
  double _clampedGainFromLufs(double lufs) =>
      (targetLufs - lufs).clamp(-_maxGainDb, _maxGainDb);

  /// 分析歌曲响度并计算应应用的增益(dB,已钳制)。渐进式版本。
  ///
  /// 流程:
  /// 1. 查缓存:命中则直接返回(无需分析),不触发 [onProgress]。
  /// 2. 未命中调原生分析,原生在解码循环里每 [progressIntervalMs] 反向
  ///    invokeMethod 'onLoudnessProgress' 推中途 LUFS,这里通过
  ///    [_activeProgressCallback] 转发给 [onProgress]。controller 侧收到后
  ///    立即算增益并渐变应用,用户 0.5s 即可听到大致均衡。
  /// 3. 全曲分析完成,返回最终精确 LUFS,controller 侧做最后一次微调+写缓存。
  ///
  /// [onProgress] 参数:(gainDb 已钳制, lufs, analyzedMs, isFinal)。
  /// isFinal=true 表示这是全曲分析完成的最终值(此时 controller 应写缓存)。
  /// 切歌时 controller 应调 [cancelAnalysis] 取消在途分析。
  ///
  /// 返回值:最终增益(dB,已钳制);null=未启用/缓存未命中但分析失败/被取消。
  Future<double?> analyzeAndComputeGain({
    required String songHash,
    required String url,
    void Function(double gainDb, double lufs, int analyzedMs, bool isFinal)?
        onProgress,
  }) async {
    if (!_enabled || songHash.isEmpty) return null;

    // 1. 查缓存(命中则重新排队,保证常用歌曲不被淘汰)。缓存命中不触发 onProgress,
    //    因为 controller 在调本方法前已用 gainFromCache instant 应用过。
    final cached = _cache.remove(songHash);
    if (cached != null) {
      _cache[songHash] = cached;
      final gain = _clampedGainFromLufs(cached);
      return gain;
    }

    // 2. 调原生渐进式分析
    if (!isAnalysisSupported) {
      log('analyze SKIP hash=${_shortHash(songHash)} 平台不支持原生分析');
      return null;
    }

    log('analyze START hash=${_shortHash(songHash)} url=$url interval=${_progressIntervalMs}ms');

    // 桌面（Windows/Linux）：Rust 引擎（symphonia + EBU R128），
    // 渐进事件语义与原生通道一致（Progress → Done，取消时无 Done）。
    if (_useRustAnalyzer) {
      return _analyzeViaRust(
        songHash: songHash,
        url: url,
        onProgress: onProgress,
      );
    }

    // 设置当前活跃进度回调。原生反向 invokeMethod 到来时转发给 onProgress。
    // 注意:必须在新分析开始前设置,并确保上一分析的回调已被清空(由 controller
    // 在切歌时调 cancelAnalysis 保证)。
    _activeProgressCallback = (lufs, analyzedMs) {
      final gain = _clampedGainFromLufs(lufs);
      log('analyze PROGRESS hash=${_shortHash(songHash)} lufs=${lufs.toStringAsFixed(1)} gain=${gain.toStringAsFixed(2)}dB analyzed=${analyzedMs}ms');
      onProgress?.call(gain, lufs, analyzedMs, false);
    };

    try {
      final result = await _channel.invokeMethod<Map>('analyzeLoudness', {
        'url': url,
        'progressIntervalMs': _progressIntervalMs,
      });
      // 分析完成(或被取消返回 null),清空活跃回调。
      _activeProgressCallback = null;

      if (result == null) {
        log('analyze CANCELLED hash=${_shortHash(songHash)} (切歌或手动取消)');
        return null; // 被取消
      }
      final lufs = (result['lufs'] as num?)?.toDouble();
      if (lufs == null || !lufs.isFinite) {
        log('analyze INVALID hash=${_shortHash(songHash)} result=$result');
        return null;
      }
      final gain = _clampedGainFromLufs(lufs);

      // 通知最终值(isFinal=true),controller 侧据此写缓存+最后微调。
      final analyzedMs = (result['analyzedMs'] as num?)?.toInt() ?? 0;
      log('analyze DONE hash=${_shortHash(songHash)} lufs=${lufs.toStringAsFixed(1)} gain=${gain.toStringAsFixed(2)}dB analyzed=${analyzedMs}ms sampleRate=${result['sampleRate']}');
      onProgress?.call(gain, lufs, analyzedMs, true);

      // 缓存原始 LUFS(LRU:命中后重新排队,写入时超限淘汰最早条目)
      _cacheLufs(songHash, lufs);
      return gain;
    } on PlatformException catch (e) {
      _activeProgressCallback = null;
      log('analyze FAILED hash=${_shortHash(songHash)} ${e.code}: ${e.message}');
      return null;
    } on MissingPluginException {
      _activeProgressCallback = null;
      log('analyze NO_PLUGIN hash=${_shortHash(songHash)} (非 Android/iOS)');
      return null;
    }
  }

  /// 桌面 Rust 分析通道（渐进事件 → onProgress，Done → 缓存 + 返回增益）。
  ///
  /// 事件语义见 rust/src/api.rs 的 [rust.LoudnessEvent]：
  /// - failure != null：分析失败，返回 null（不写缓存）；
  /// - isFinal：最终值（写缓存 + isFinal=true 回调）后流关闭；
  /// - 流关闭而没有 isFinal：被取消，返回 null。
  Future<double?> _analyzeViaRust({
    required String songHash,
    required String url,
    void Function(double gainDb, double lufs, int analyzedMs, bool isFinal)? onProgress,
  }) async {
    final completer = Completer<double?>();
    StreamSubscription<rust.LoudnessEvent>? subscription;
    var settled = false;

    Future<void> finish(double? value) async {
      if (settled) return;
      settled = true;
      await subscription?.cancel();
      if (!completer.isCompleted) completer.complete(value);
    }

    try {
      final stream = rust.analyzeLoudness(url: url);
      subscription = stream.listen(
        (event) {
          final failure = event.failure;
          if (failure != null) {
            log('analyze FAILED(rust) hash=${_shortHash(songHash)} $failure');
            finish(null);
            return;
          }
          final lufs = event.lufs;
          if (!lufs.isFinite) {
            log('analyze INVALID(rust) hash=${_shortHash(songHash)} lufs=$lufs');
            finish(null);
            return;
          }
          final gain = _clampedGainFromLufs(lufs);
          final analyzedMs = event.analyzedMs.toInt();
          onProgress?.call(gain, lufs, analyzedMs, event.isFinal);
          if (event.isFinal) {
            log('analyze DONE(rust) hash=${_shortHash(songHash)} lufs=${lufs.toStringAsFixed(1)} gain=${gain.toStringAsFixed(2)}dB analyzed=${analyzedMs}ms');
            _cacheLufs(songHash, lufs);
            finish(gain);
          }
        },
        onError: (Object error) {
          log('analyze FAILED(rust) hash=${_shortHash(songHash)} $error');
          finish(null);
        },
        onDone: () {
          // 没有 isFinal 事件就关流 = 被取消（对齐 Android 语义）。
          log('analyze CANCELLED(rust) hash=${_shortHash(songHash)}');
          finish(null);
        },
        cancelOnError: false,
      );
    } catch (error) {
      // RustLib 未初始化 / FFI 异常等：按分析失败处理。
      log('analyze RUST_ERROR hash=${_shortHash(songHash)} $error');
      finish(null);
    }

    return completer.future;
  }

  /// 缓存原始 LUFS（LRU：命中后重新排队，写入时超限淘汰最早条目）。
  void _cacheLufs(String songHash, double lufs) {
    _cache.remove(songHash);
    _cache[songHash] = lufs;
    while (_cache.length > _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    unawaited(_persistCache());
    log('cache WRITE hash=${_shortHash(songHash)} size=${_cache.length}');
  }

  /// 取消当前在途的响度分析(切歌时调用)。
  /// 通知原生解码循环立即结束,同时清空活跃进度回调,使任何迟到的中途进度
  /// 被丢弃。不阻塞——取消是异步的,旧分析的 Future 会以 null 返回。
  Future<void> cancelAnalysis() async {
    log('cancelAnalysis 调用 (切歌/关开关/清缓存)');
    _activeProgressCallback = null;
    if (!isAnalysisSupported) return;
    if (_useRustAnalyzer) {
      try {
        await rust.cancelLoudnessAnalysis();
      } catch (error) {
        // RustLib 未就绪等：忽略（序号守卫会兜底丢弃旧结果）。
        debugPrint('[loudness] rust cancelLoudnessAnalysis 失败: $error');
      }
      return;
    }
    try {
      await _channel.invokeMethod<bool>('cancelLoudnessAnalysis');
    } on PlatformException catch (_) { // ignore: empty_catches
      // 取消失败不影响主流程(序号守卫会兜底丢弃旧结果)
    } on MissingPluginException { // ignore: empty_catches
      // 非 Android/iOS,忽略
    }
  }

  /// 应用增益。
  ///
  /// 按增益正负分流:
  /// - gain > 0(歌曲偏轻,需放大):
  ///   - Android:原生 [LoudnessEnhancer](官方仅支持正向放大),setVolume 1.0;
  ///   - Linux:mpv 音量上限已被 vendored just_audio_media_kit 抬高
  ///     (volume-max=400),setVolume 可 >1.0 直接数字放大;
  ///   - Windows:WinRT MediaPlayer.Volume 只认 0..1,无放大能力,
  ///     保持 1.0(平台限制,设置页有说明);
  ///   - iOS/macOS:同 Windows,保持 1.0。
  /// - gain <= 0(歌曲偏响,需衰减):统一用 [AudioPlayer.setVolume] 衰减。
  ///   Android 的 LoudnessEnhancer 不支持负增益(衰减属未定义行为,
  ///   多数设备无效),故响歌也走 setVolume。
  /// - gain 为 null/非有限/未启用:重置为原始音量。
  ///
  /// 增益先钳制到 [_maxGainDb] 避免过载;setVolume 的变化走渐变(ramp),
  /// 消除"分析完成后音量瞬间塌下去"的突兀感。Android LoudnessEnhancer
  /// 本身是 DRC 类效果,内置平滑,无需渐变。
  Future<void> applyGain({
    required AudioPlayer audioPlayer,
    required int? audioSessionId,
    required double? gainDb,
    /// true=缓存命中/首播前已知增益,直接应用无需渐变;false=播放中分析完成,
    /// 需渐变避免跳变。默认 false(保守,有渐变更安全)。
    bool instant = false,
  }) async {
    if (!_enabled || gainDb == null || !gainDb.isFinite) {
      log('applyGain RESET (未启用或增益无效) instant=$instant');
      await resetGain(
        audioPlayer: audioPlayer,
        audioSessionId: audioSessionId,
      );
      return;
    }

    // 防御性二次钳制:正常流程增益已在 analyzeAndComputeGain/gainFromCache 钳过,
    // 这里再 clamp 一次保证任何来源的值都不会越界。
    final clampedGain = gainDb.clamp(-_maxGainDb, _maxGainDb);

    if (clampedGain <= 0) {
      // 响歌衰减:LoudnessEnhancer 不支持负增益,统一走 setVolume
      final volume = pow(10, clampedGain / 20).toDouble().clamp(0.0, 1.0);
      log('applyGain ATTENUATE gain=${clampedGain.toStringAsFixed(2)}dB volume=${volume.toStringAsFixed(3)} instant=$instant');
      await _disableNativeEnhancer(audioSessionId);
      await _setVolumeRamped(audioPlayer, volume, instant);
      return;
    }

    // 轻歌放大:Android 用 LoudnessEnhancer;Linux 用 mpv 数字放大(>1.0);
    // Windows(WinRT Volume 0..1)/iOS/macOS 无放大能力,保持 1.0。
    if (defaultTargetPlatform == TargetPlatform.android) {
      final gainMb = (clampedGain * 100).round().clamp(0, 1500);
      try {
        await _channel.invokeMethod<bool>('configureLoudnessGain', {
          'audioSessionId': audioSessionId,
          'enabled': true,
          'gainMb': gainMb,
        });
        // 放大用 LoudnessEnhancer,setVolume 保持 1.0 避免双重增益
        log('applyGain AMPLIFY(android) gain=${clampedGain.toStringAsFixed(2)}dB gainMb=$gainMb instant=$instant');
        await audioPlayer.setVolume(1.0);
        return;
      } on PlatformException catch (e) {
        log('applyGain AMPLIFY(android) FAILED ${e.code}: ${e.message} → 降级 setVolume');
      } on MissingPluginException {
        log('applyGain AMPLIFY(android) NO_PLUGIN → 降级 setVolume');
      }
    } else if (defaultTargetPlatform == TargetPlatform.linux && !kIsWeb) {
      // mpv: just_audio volume 1.0 = mpv volume 100; 放大即 >100
      //（vendored just_audio_media_kit 已抬高 volume-max）。
      final volume = pow(10, clampedGain / 20)
          .toDouble()
          .clamp(0.0, _linuxMaxBoostVolume);
      log('applyGain AMPLIFY(linux/mpv) gain=${clampedGain.toStringAsFixed(2)}dB volume=${volume.toStringAsFixed(3)} instant=$instant');
      await _disableNativeEnhancer(audioSessionId);
      await _setVolumeRamped(audioPlayer, volume, instant);
      return;
    }
    // Windows/iOS/macOS:无法放大,setVolume 保持 1.0
    log('applyGain AMPLIFY_SKIP($defaultTargetPlatform) gain=${clampedGain.toStringAsFixed(2)}dB (平台不支持放大,保持原始音量)');
    await audioPlayer.setVolume(1.0);
  }

  /// Linux 放大上限（mpv 音量标量）。+6dB = 2.0；vendored 适配层把
  /// mpv volume-max 抬到 400（=4.0/+12dB），留出钳制后的安全余量。
  static const double _linuxMaxBoostVolume = 2.0;

  /// 平台音量上限（ramp 插值时的 clamp 边界）。
  static double get _platformMaxVolume =>
      (!kIsWeb && Platform.isLinux) ? _linuxMaxBoostVolume : 1.0;

  /// 平滑过渡 setVolume。instant=true 直接设置(缓存命中首播);否则在
  /// [_rampDurationMs] 内线性插值,消除音量突变。插值边界按平台音量上限
  /// clamp（Linux 放大路径允许 >1.0，见 [_linuxMaxBoostVolume]）。
  Future<void> _setVolumeRamped(
    AudioPlayer audioPlayer,
    double targetVolume, [
    bool instant = false,
  ]) async {
    _volumeRampTimer?.cancel();
    final maxVolume = _platformMaxVolume;
    final clampedTarget = targetVolume.clamp(0.0, maxVolume);
    final current = audioPlayer.volume;
    if (instant || (current - clampedTarget).abs() < 0.002) {
      await audioPlayer.setVolume(clampedTarget);
      return;
    }
    // 20ms 步进,总时长 _rampDurationMs
    const steps = 12;
    final stepDuration = _rampDurationMs ~/ steps;
    var i = 0;
    final completer = Completer<void>();
    _volumeRampTimer = Timer.periodic(
      Duration(milliseconds: stepDuration),
      (t) {
        i++;
        final t01 = i / steps;
        final v = current + (clampedTarget - current) * t01;
        audioPlayer.setVolume(v.clamp(0.0, maxVolume));
        if (i >= steps) {
          t.cancel();
          audioPlayer.setVolume(clampedTarget);
          completer.complete();
        }
      },
    );
    return completer.future;
  }

  /// 禁用原生 LoudnessEnhancer(切到 setVolume 衰减模式时调用)。
  Future<void> _disableNativeEnhancer(int? audioSessionId) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<bool>('configureLoudnessGain', {
        'audioSessionId': audioSessionId,
        'enabled': false,
        'gainMb': 0,
      });
    } on PlatformException catch (_) { // ignore: empty_catches
      // 禁用失败不影响 setVolume 衰减
    } on MissingPluginException { // ignore: empty_catches
      // 插件未注册(非 Android),忽略
    }
  }

  /// 重置增益(关闭/异常时恢复原始音量)。渐变回到 1.0 避免关开关时跳变。
  Future<void> resetGain({
    required AudioPlayer audioPlayer,
    int? audioSessionId,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod<bool>('configureLoudnessGain', {
          'audioSessionId': audioSessionId,
          'enabled': false,
          'gainMb': 0,
        });
      } on PlatformException catch (_) { // ignore: empty_catches
        // 重置/释放失败不影响主流程
      } on MissingPluginException { // ignore: empty_catches
        // 插件未注册(非 Android),忽略
      }
    }
    await _setVolumeRamped(audioPlayer, 1.0, false);
  }

  /// 释放原生 LoudnessEnhancer(App 退出/释放时)。
  Future<void> releaseNative() async {
    _volumeRampTimer?.cancel();
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod<bool>('releaseLoudnessGain');
      } on PlatformException catch (_) { // ignore: empty_catches
        // 重置/释放失败不影响主流程
      } on MissingPluginException { // ignore: empty_catches
        // 插件未注册(非 Android),忽略
      }
    }
  }

  Future<void> _persistCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonEncode(_cache));
  }
}
