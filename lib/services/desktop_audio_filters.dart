import 'dart:math' as math;

/// 桌面端（mpv）音频滤镜链组装：把均衡器/低音/环绕状态编译成 mpv `af`
/// 属性的滤镜片段列表。纯函数，供单测与 PlayerController 桌面路径复用。
///
/// 滤镜选型受运行时 libmpv 的 ffmpeg 滤镜白名单硬约束（真机教训：
/// Windows 捆绑的 media-kit audio-only 构建 libmpv-2.dll 是
/// `--disable-filters` 后仅放行 overlay/equalizer 两个滤镜，
/// firequalizer/stereotools/extrastereo 一概不存在——extrastereo 还在
/// mpv 0.36+ 被上游移除。写入不存在的滤镜会让 mpv 拒绝整条 af，错误
/// 经 errorStream 冒充播放中断把当前歌打断）。因此：
///
/// - 均衡器：lavfi 音频 `equalizer`（峰值双二阶滤波器）每段一个、逗号
///   串联成链——该滤镜在 Windows 白名单内，且与 Android 系统 Equalizer
///   同为 biquad 实现，两端听感一致；毫贝尔值除以 100 转 dB，Q 取 1.2
///   （倍频程段常规宽度），四舍五入后为零的段跳过不写。
/// - 低音增强：Android 有独立 BassBoost 效果器，mpv 无对应滤镜，折算成
///   31/62/125Hz 三点抬升（满强度 +12dB 梯形）叠进 EQ 各段。
/// - 环绕：lavfi `stereotools` 的 slev（边声道增益，>1 声场展宽），强度
///   线性映射 1 + 0.55×strength。仅 Linux 系统 libmpv（发行版全量
///   ffmpeg）可用；Windows audio-only 构建没有任何展宽类滤镜，由
///   [surroundAvailable] 置 false 整段不写。
///
/// lavfi 图一律用方括号 `lavfi=[...]` 包裹：mpv 属性接口的 af 字符串
/// 解析器对 `[...]` 内的分隔符（逗号/冒号）原样放行，而对单引号包裹
/// 直接报 unsupported format（scripts/mpv_af_probe.dart 对真实 DLL 的
/// 实测结论，曾因引号格式导致音效链整体写入失败）。
abstract final class DesktopAudioFilters {
  /// 单段增益钳制（±24dB），防 EQ 与低音叠加后的极端值。
  static const _maxDb = 24.0;

  /// 峰值滤波器 Q 值：10 段倍频程图形均衡的常规宽度。
  static const _bandQ = 1.2;

  static List<String> build({
    required bool equalizerEnabled,
    required List<int> centerHz,
    required List<int> levelsMillibels,
    bool bassEnabled = false,
    double bassStrength = 0,
    bool surroundEnabled = false,
    double surroundStrength = 0,
    bool surroundAvailable = true,
  }) {
    final filters = <String>[];
    final hasEq =
        equalizerEnabled && centerHz.isNotEmpty && levelsMillibels.isNotEmpty;
    final bassDb = bassEnabled ? bassStrength.clamp(0.0, 1.0) * 12.0 : 0.0;
    final eqChain = _equalizerChain(
      centerHz,
      levelsMillibels,
      applyEq: hasEq,
      bassDb: bassDb,
    );
    if (eqChain != null) {
      filters.add(eqChain);
    }
    if (surroundAvailable && surroundEnabled && surroundStrength > 0) {
      final slev =
          (1 + 0.55 * surroundStrength.clamp(0.0, 1.0)).toStringAsFixed(3);
      filters.add('lavfi=[stereotools=slev=$slev]');
    }
    return filters;
  }

  /// 组装 biquad 链；四舍五入后无任何非零增益段时返回 null（不发 EQ 片段）。
  static String? _equalizerChain(
    List<int> centerHz,
    List<int> levels, {
    required bool applyEq,
    required double bassDb,
  }) {
    final count = math.min(centerHz.length, levels.length);
    final segments = <String>[];
    for (var index = 0; index < count; index++) {
      final db = _bandDb(
        centerHz[index],
        applyEq ? levels[index] / 100.0 : 0,
        bassDb,
      );
      final gainText = db.toStringAsFixed(1);
      if (double.parse(gainText) == 0) {
        continue;
      }
      segments.add(
        'equalizer=f=${centerHz[index]}:t=q:w=$_bandQ:g=$gainText',
      );
    }
    if (segments.isEmpty) {
      return null;
    }
    return 'lavfi=[${segments.join(',')}]';
  }

  static double _bandDb(int hz, double eqDb, double bassDb) {
    final db = eqDb + _bassShelfDb(hz, bassDb);
    return db.clamp(-_maxDb, _maxDb);
  }

  static double _bassShelfDb(int hz, double bassDb) {
    if (bassDb <= 0) {
      return 0;
    }
    if (hz <= 31) {
      return bassDb;
    }
    if (hz <= 62) {
      return bassDb * 0.7;
    }
    if (hz <= 125) {
      return bassDb * 0.35;
    }
    return 0;
  }
}
