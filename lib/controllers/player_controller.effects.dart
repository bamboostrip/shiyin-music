// player_controller.effects.dart —— PlayerController 的职责分片：音效与响度（均衡器/低音增强/响度均衡分析应用）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerEffects on _PlayerControllerBase {
  bool get isAudioEffectsSupported => _audioEffects.isAudioEffectsSupported;
  bool get isBassBoostSupported => _audioEffects.isBassBoostSupported;
  bool get loudnessEnabled => _loudness.isEnabled;
  bool get isLoudnessAnalysisSupported => _loudness.isAnalysisSupported;
  String get audioEffectsLabel {
    if (!isAudioEffectsSupported) {
      return '当前平台暂不支持';
    }
    if (equalizerEnabled) {
      return '均衡器：$equalizerPresetName';
    }
    if (bassBoostEnabled) {
      return 'Bass ${(bassBoostStrength * 100).round()}%';
    }
    return '关闭';
  }

  Future<void> setBassBoostEnabled(bool enabled) async {
    if (bassBoostEnabled == enabled) {
      return;
    }
    bassBoostEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bassBoostEnabledSettingKey, enabled);
    await _applyBassBoost();
    notifyListeners();
  }

  Future<void> setBassBoostStrength(
    double strength, {
    bool persist = true,
  }) async {
    final nextStrength = strength.clamp(0.0, 1.0);
    if ((bassBoostStrength - nextStrength).abs() < 0.001) {
      return;
    }
    bassBoostStrength = nextStrength;
    if (bassBoostEnabled) {
      unawaited(_applyBassBoost());
    }
    notifyListeners();

    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_bassBoostStrengthSettingKey, nextStrength);
    }
  }

  Future<void> setEqualizerEnabled(bool enabled) async {
    if (equalizerEnabled == enabled) {
      return;
    }
    equalizerEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, enabled);
    await _applyEqualizer();
    notifyListeners();
  }

  Future<void> setEqualizerBandLevel(
    int index,
    int levelMillibels, {
    bool persist = true,
  }) async {
    if (index < 0 || index >= equalizerLevels.length) {
      return;
    }
    final clamped = levelMillibels.clamp(
      equalizerConfig.minMillibels,
      equalizerConfig.maxMillibels,
    );
    if (equalizerLevels[index] == clamped) {
      return;
    }
    equalizerLevels = List<int>.of(equalizerLevels)..[index] = clamped;
    equalizerPresetName = '自定义';
    if (equalizerEnabled) {
      unawaited(_applyEqualizer());
    }
    notifyListeners();

    if (persist) {
      await _persistEqualizer();
    }
  }

  Future<void> applyEqualizerPreset(AudioEffectPreset preset) async {
    equalizerPresetName = preset.name;
    equalizerLevels = PlayerEqualizerLogic.levelsForBandCount(
      preset.levels,
      equalizerLevels.length,
    );
    await _persistEqualizer();
    if (equalizerEnabled) {
      await _applyEqualizer();
    }
    notifyListeners();
  }

  Future<void> resetEqualizer() async {
    await applyEqualizerPreset(PlayerController.equalizerPresets.first);
  }

  Future<void> _persistEqualizer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, equalizerEnabled);
    await prefs.setString(_equalizerPresetSettingKey, equalizerPresetName);
    await prefs.setString(
      _equalizerLevelsSettingKey,
      jsonEncode(equalizerLevels),
    );
  }

  @override
  Future<void> _refreshEqualizerConfig() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    final config = await _audioEffects.equalizerConfig(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
    );
    if (config == null || config.bands.isEmpty) {
      return;
    }
    equalizerConfig = config;
    if (equalizerLevels.length != config.bands.length) {
      equalizerLevels = PlayerEqualizerLogic.levelsForBandCount(
        equalizerLevels,
        config.bands.length,
      );
      unawaited(_persistEqualizer());
    }
    notifyListeners();
  }

  @override
  Future<void> _applyEqualizer() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    await _audioEffects.configureEqualizer(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: equalizerEnabled,
      levels: equalizerLevels,
    );
  }

  @override
  Future<void> _applyBassBoost() async {
    if (!isBassBoostSupported) {
      return;
    }

    await _audioEffects.configureBassBoost(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: bassBoostEnabled,
      strength: bassBoostStrength,
    );
  }

  /// 切歌时并行分析响度,完成后应用增益(不阻塞 loadSong/播放)。
  /// 渐进式:原生解码过程中每 500ms 推一次中途 LUFS,这里收到后立即算增益
  /// 并渐变应用,用户 0.5s 即可听到大致均衡。全曲分析完成后用精确值做最后
  /// 一次微调并写缓存。
  ///
  /// 用 [_loudnessSerial] 守护:若分析期间又切了歌,本次结果(包括中途进度)
  /// 会被丢弃。切歌时 [playSong] 会调 [LoudnessService.cancelAnalysis] 取消
  /// 旧分析,避免空跑占 CPU。
  ///
  /// 仅在缓存未命中(需原生解码分析)时触发渐变应用;缓存命中已由
  /// 调用方(loadSong 前)instant 应用,这里 [analyzeAndComputeGain] 会
  /// 再次命中并返回相同值,gain 与 [_pendingGainDb] 一致则跳过重复应用。
  @override
  Future<void> _analyzeAndApplyLoudness({
    required Song song,
    required String url,
  }) async {
    final serial = ++_loudnessSerial;
    // 重置 EMA 滤波状态:每首新歌从零开始滤波,记录墙钟起点。
    _emaGainDb = null;
    _emaStartWallTime = DateTime.now();
    LoudnessService.log(
      'controller analyze 开始 serial=$serial hash=${song.hash.length > 8 ? song.hash.substring(0, 8) : song.hash}',
    );
    final gain = await _loudness.analyzeAndComputeGain(
      songHash: song.hash,
      url: url,
      onProgress: (gainDb, lufs, analyzedMs, isFinal) {
        // 切歌守卫:序号不匹配说明期间已切到其它歌曲,丢弃本次中途进度。
        if (serial != _loudnessSerial) {
          LoudnessService.log(
            'controller PROGRESS 丢弃 serial=$serial≠$_loudnessSerial (已切歌)',
          );
          return;
        }
        // 渡口效应缓解:分析开始后前 3s(墙钟时间)的中途增益做 EMA 低通滤波。
        // 用墙钟而非音频时长:解码 27x 快,3s 音频 ~110ms 就解码完,按音频时长
        // 滤波窗口在用户听到第一个进度时就已关闭。按墙钟则覆盖用户实际听到的
        // 前 3 秒播放。最终值(isFinal)不滤波,保证精度。
        var appliedGain = gainDb;
        final wallElapsedMs = _emaStartWallTime == null
            ? LoudnessService.earlyProgressWallMs + 1
            : DateTime.now().difference(_emaStartWallTime!).inMilliseconds;
        if (!isFinal && wallElapsedMs < LoudnessService.earlyProgressWallMs) {
          final prev = _emaGainDb;
          if (prev == null) {
            // 首次中途值直接采用(无历史可平均),初始化 EMA 状态。
            _emaGainDb = gainDb;
          } else {
            // EMA: α=0.3 → 新值权重 30%,历史 70%。对 +6→+1.69 跳变
            // 平滑到 +3.90(首次)→ +3.0(二次),用户可感但不再突兀。
            _emaGainDb =
                LoudnessService.emaAlpha * gainDb +
                (1 - LoudnessService.emaAlpha) * prev;
            appliedGain = _emaGainDb!;
            LoudnessService.log(
              'controller PROGRESS(mid,EMA) raw=${gainDb.toStringAsFixed(2)}dB smoothed=${appliedGain.toStringAsFixed(2)}dB wall=${wallElapsedMs}ms<${LoudnessService.earlyProgressWallMs}ms',
            );
          }
        }
        // 中途进度(isFinal=false):若新增益与当前应用增益差异超过阈值,
        // 渐变应用(用户无感)。差异太小(<0.3dB)则跳过,避免频繁 ramp。
        // 最终值(isFinal=true):总是应用(可能差异小但需定稿)。
        final currentGain = _pendingGainDb;
        final diff = currentGain == null
            ? double.infinity
            : (appliedGain - currentGain).abs();
        if (isFinal) {
          LoudnessService.log(
            'controller PROGRESS(final) gain=${appliedGain.toStringAsFixed(2)}dB diff=${diff == double.infinity ? "∞" : diff.toStringAsFixed(2)}dB → 应用(ramp)',
          );
        } else if (diff >= LoudnessService.progressGainThreshold) {
          LoudnessService.log(
            'controller PROGRESS(mid) gain=${appliedGain.toStringAsFixed(2)}dB diff=${diff.toStringAsFixed(2)}dB≥${LoudnessService.progressGainThreshold} → 应用(ramp)',
          );
        } else {
          LoudnessService.log(
            'controller PROGRESS(mid) gain=${appliedGain.toStringAsFixed(2)}dB diff=${diff.toStringAsFixed(2)}dB<${LoudnessService.progressGainThreshold} → 跳过(差异太小)',
          );
          return;
        }
        _pendingGainDb = appliedGain;
        // 中途值用渐变(ramp),最终值也用渐变(平滑收敛)。
        // 缓存命中的 instant 应用已在 playSong 里处理,不走到这里。
        unawaited(_applyLoudnessGain(instant: false));
        notifyListeners();
      },
    );
    // 切歌守卫:序号不匹配说明期间已切到其它歌曲,丢弃本次最终结果
    if (serial != _loudnessSerial) {
      LoudnessService.log(
        'controller analyze 最终结果丢弃 serial=$serial≠$_loudnessSerial (已切歌)',
      );
      return;
    }
    // 最终值已在 onProgress(isFinal=true) 里应用过,这里只处理:
    // - gain 为 null(分析失败/未启用/被取消)→ reset
    // - 缓存命中(gain 与 _pendingGainDb 一致)→ 跳过
    if (gain == null) {
      LoudnessService.log('controller analyze 返回 null (失败/取消/未启用)');
      if (_pendingGainDb != null) {
        _pendingGainDb = null;
        await _applyLoudnessGain(instant: false);
        notifyListeners();
      }
      return;
    }
    // 缓存命中场景:onProgress 不会被调用(查缓存直接返回),
    // _pendingGainDb 可能仍为 null(首次)或旧值。这里补一次 instant 应用。
    if (gain != _pendingGainDb) {
      LoudnessService.log(
        'controller analyze 缓存命中补应用 gain=${gain.toStringAsFixed(2)}dB (instant)',
      );
      _pendingGainDb = gain;
      await _applyLoudnessGain(instant: true);
      notifyListeners();
    } else {
      LoudnessService.log(
        'controller analyze 完成 gain=${gain.toStringAsFixed(2)}dB 已应用,无需补应用',
      );
    }
  }

  /// 应用当前歌曲的响度增益(sessionId 变化或分析完成时调用)。
  /// [instant]=true 直接设置(缓存命中首播/用户调音量);false 走渐变。
  /// 用户音量恒参与合成，响度永远只动自己的系数通道。
  @override
  Future<void> _applyLoudnessGain({bool instant = false}) async {
    await _loudness.applyGain(
      audioPlayer: audioPlayer,
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      gainDb: _pendingGainDb,
      userVolume: userVolume,
      instant: instant,
    );
  }

  /// 开关响度均衡。
  Future<void> setLoudnessEnabled(bool enabled) async {
    await _loudness.setEnabled(
      enabled: enabled,
      audioPlayer: audioPlayer,
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      userVolume: userVolume,
    );
    if (enabled) {
      // 开启后,对当前歌曲立即分析并应用(用已解析的真实 URL,避免重新请求)
      final song = currentSong;
      final url = _currentLoudnessUrl;
      if (song != null && url != null && url.isNotEmpty) {
        unawaited(_analyzeAndApplyLoudness(song: song, url: url));
      }
    } else {
      _pendingGainDb = null;
      _loudnessSerial++; // 使任何在途分析结果失效
      unawaited(_loudness.cancelAnalysis()); // 停掉原生解码线程
    }
    notifyListeners();
  }

  /// 响度分析缓存条目数(供设置页展示)。
  int get loudnessCacheCount => _loudness.cacheCount;

  /// 清空响度分析缓存(设置页"缓存管理"调用)。
  /// 清完后若响度开启,重置当前歌曲增益回原始音量,下次切歌重新分析。
  Future<void> clearLoudnessCache() async {
    _loudnessSerial++; // 使任何在途分析结果失效
    unawaited(_loudness.cancelAnalysis()); // 停掉原生解码线程
    _pendingGainDb = null;
    await _loudness.clearCache();
    if (_loudness.isEnabled) {
      await _loudness.resetGain(
        audioPlayer: audioPlayer,
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        userVolume: userVolume,
      );
    }
    notifyListeners();
  }
}
