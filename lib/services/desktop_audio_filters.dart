import 'dart:math' as math;

/// 桌面端（mpv）音频滤镜链组装：把均衡器/低音/环绕状态编译成 mpv `af`
/// 属性的滤镜片段列表。纯函数，供单测与 PlayerController 桌面路径复用。
///
/// - 均衡器：ffmpeg `firequalizer`（FFT FIR，任意频点增益），毫贝尔值
///   除以 100 转 dB 后逐点写 gain_entry；频率点间线性插值由滤镜完成。
/// - 低音增强：Android 有独立 BassBoost 效果器，mpv 无对应物，折算成
///   31/62/125Hz 三点搁架抬升（满强度 +12dB 梯形）叠进 EQ 曲线。
/// - 环绕：mpv 原生 `extrastereo`（立体声差异放大，m>1 展宽），强度
///   线性映射 m = 1 + 0.55×strength，c=1 开启削波保护防大音量爆音。
abstract final class DesktopAudioFilters {
  /// firequalizer 单点增益钳制（±24dB），防叠加后的极端值。
  static const _maxDb = 24.0;

  static List<String> build({
    required bool equalizerEnabled,
    required List<int> centerHz,
    required List<int> levelsMillibels,
    bool bassEnabled = false,
    double bassStrength = 0,
    bool surroundEnabled = false,
    double surroundStrength = 0,
  }) {
    final filters = <String>[];
    final hasEq =
        equalizerEnabled && centerHz.isNotEmpty && levelsMillibels.isNotEmpty;
    final bassDb = bassEnabled ? bassStrength.clamp(0.0, 1.0) * 12.0 : 0.0;
    if (hasEq || bassDb > 0) {
      filters.add(
        _firequalizer(centerHz, levelsMillibels, applyEq: hasEq, bassDb: bassDb),
      );
    }
    if (surroundEnabled && surroundStrength > 0) {
      filters.add(
        'extrastereo=m='
        '${(1 + 0.55 * surroundStrength.clamp(0.0, 1.0)).toStringAsFixed(3)}'
        ':c=1',
      );
    }
    return filters;
  }

  static String _firequalizer(
    List<int> centerHz,
    List<int> levels, {
    required bool applyEq,
    required double bassDb,
  }) {
    final count = math.min(centerHz.length, levels.length);
    final entries = <String>[
      for (var index = 0; index < count; index++)
        'entry(${centerHz[index]},'
        '${_bandDb(centerHz[index], applyEq ? levels[index] / 100.0 : 0, bassDb).toStringAsFixed(1)})',
    ];
    return "lavfi=[firequalizer=gain_entry='${entries.join(';')}']";
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
