// player_controller.desktop.dart —— PlayerController 的职责分片：桌面歌词与系统集成（悬浮窗歌词/卡拉OK进度/AudioSession 打断策略/设备接入自动播放）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerDesktop on _PlayerControllerBase {
  /// 系统音频打断与设备断连策略（**本 fork 独占**，just_audio 的
  /// `handleInterruptions` 已关闭，见 `MusicAudioHandler.audioPlayer`）。
  ///
  /// 移植上游 3.3.0 `56d0c9f` + `9426621` + `c7ba1e6`，按本 fork 的架构改了三处：
  ///
  /// - **不做手动 duck 音量**。上游在这里用 `_volumeBeforeDuck/_duckedVolume`
  ///   把引擎音量对半压，但本 fork 的引擎音量由 [LoudnessService] 独占
  ///   （正向增益走 Android LoudnessEnhancer，衰减走 `setVolume` + 渐变 ramp），
  ///   任何一处裸 `setVolume` 都会被下一次 `applyGain` 覆盖，还会和用户音量
  ///   互相打。duck（导航播报/通知提示音）保持现状：不暂停也不改音量。
  /// - **起播收口是 [_requestPlayback]**（带平台确认超时），不是上游的
  ///   `_startPlayback`，所以企图代次守卫加在那里。
  /// - **自动恢复统一走 [_scheduleAutomaticResume]**：定时器代次
  ///   （[_autoResumeSerial]）负责让排队中的旧回调失效。旧实现直接
  ///   `Timer(callback)`，用户在这一拍里暂停也拦不住。
  Future<void> _setupAudioSessionListeners() async {
    try {
      final session = await _audioSessionProvider();
      await session.configure(_audioSessionConfiguration);
      _interruptionSub = session.interruptionEventStream.listen(
        handleInterruptionEvent,
      );
      _becomingNoisySub = session.becomingNoisyEventStream.listen(
        (_) => handleBecomingNoisy(),
      );
      _previousDevices = await session.getDevices();
      _devicesSub = session.devicesStream.listen(handleDevicesChanged);
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  /// 系统音频打断事件（来电、语音助手、其他 App 抢焦点）。
  ///
  /// 公开给测试直接驱动：`AudioSession` 是私有构造的单例，单测无法伪造，
  /// 而这里的决策逻辑（要不要暂停、要不要恢复）才是容易错的部分。
  @visibleForTesting
  void handleInterruptionEvent(AudioInterruptionEvent event) {
    if (event.begin) {
      _autoResumeTimer?.cancel();
      _autoResumeSerial++;
      // 同一轮打断会连发多次 begin（不同焦点类型），只在首次采样，
      // 否则后到的 begin 看到的是「已经被我 pause 掉」的 false。
      if (!_isAudioInterrupted) {
        _wasPlayingAtInterruption =
            audioPlayer.playing ||
            _pendingPlaybackIntent == _playbackIntentSerial;
      }
      _isAudioInterrupted = true;
      if (event.type == AudioInterruptionType.duck) {
        // 见类注释：音量归 LoudnessService，这里不接管。
        return;
      }
      _interruptionRequiresPause = true;
      if (audioInterruptionEnabled) {
        // 关闭了 just_audio 的自动打断，暂停必须由我们自己发；
        // userInitiated=false：这是流程动作，不能当成用户放弃播放。
        unawaited(_audioHandler.pause(userInitiated: false));
      } else if (_wasPlayingAtInterruption) {
        // 「阻止打断」模式：主动对抗系统的暂停。
        _scheduleAutomaticResume(
          const Duration(milliseconds: 300),
          allowDuringInterruption: true,
        );
      }
      return;
    }

    final shouldResume = _wasPlayingAtInterruption;
    _wasPlayingAtInterruption = false;
    _isAudioInterrupted = false;
    _interruptionRequiresPause = false;
    if (event.type != AudioInterruptionType.duck &&
        audioInterruptionEnabled &&
        (!autoResumeAfterInterruption ||
            event.type != AudioInterruptionType.pause)) {
      // 本轮不恢复：连在途的起播请求一起作废。它可能正卡在地址解析里，
      // 不作废就会在几百毫秒后自己出声（「挂断后自己开始播」的另一半）。
      _cancelAutomaticResume();
    }
    if (event.type == AudioInterruptionType.pause &&
        shouldResume &&
        (autoResumeAfterInterruption || (!audioInterruptionEnabled)) &&
        currentSong != null) {
      _scheduleAutomaticResume(const Duration(milliseconds: 500));
    }
  }

  /// 音频路由即将变得「不私密」（拔耳机 / 蓝牙断开）。
  @visibleForTesting
  void handleBecomingNoisy() {
    if (autoPauseOnDeviceDisconnect) {
      // 蓝牙掉线/拔耳机：Android 会把音频改路由到扬声器继续播。
      // 置断连保护并立刻暂停；保护只能由用户显式播放解除。
      _resumeBlockedByDisconnect = true;
      _cancelAutomaticResume();
      unawaited(_audioHandler.pause(userInitiated: false));
      return;
    }
    if (!audioInterruptionEnabled) {
      // 阻止打断模式下忽略耳机拔出（用户明确表示不想被打断）。
      return;
    }
    // 关闭了「断开停止播放」：仍要暂停（防外放是底线），
    // 只是允许按 autoResumeAfterInterruption 自行恢复。
    final wasPlaying = audioPlayer.playing;
    unawaited(_audioHandler.pause(userInitiated: false));
    if (wasPlaying && autoResumeAfterInterruption && currentSong != null) {
      _scheduleAutomaticResume(const Duration(milliseconds: 500));
    }
  }

  /// 音频设备列表变化（插拔耳机/接上车机）。
  @visibleForTesting
  void handleDevicesChanged(Set<AudioDevice> devices) {
    if (_previousDevices != null) {
      final addedDevices = devices.difference(_previousDevices!);
      if (addedDevices.isNotEmpty) {
        // ignore: experimental_member_use
        final hasNewAudioDevice = addedDevices.any(
          (d) =>
              // ignore: experimental_member_use
              d.type == AudioDeviceType.bluetoothA2dp ||
              // ignore: experimental_member_use
              d.type == AudioDeviceType.bluetoothLe ||
              // ignore: experimental_member_use
              d.type == AudioDeviceType.bluetoothSco ||
              // ignore: experimental_member_use
              d.type == AudioDeviceType.wiredHeadset ||
              // ignore: experimental_member_use
              d.type == AudioDeviceType.wiredHeadphones ||
              // ignore: experimental_member_use
              d.type == AudioDeviceType.carAudio,
        );

        if (hasNewAudioDevice &&
            autoPlayOnDeviceConnected &&
            currentSong != null &&
            !isPlaying &&
            // 打断期间不抢占：来电中接上车机不该开始放歌。
            !_isAudioInterrupted) {
          // 重新接上设备等同「用户把耳机插回来」，解除断连保护。
          _resumeBlockedByDisconnect = false;
          _scheduleAutomaticResume(const Duration(milliseconds: 500));
        }
      }
    }
    _previousDevices = devices;
  }

  /// 根据打断设置生成 AudioSessionConfiguration。
  ///
  /// 阻止打断时使用 [AndroidAudioFocusGainType.gain] 并禁用 androidWillPauseWhenDucked，
  /// 向系统声明不希望被其他 App 打断。同时配合 interruptionEventStream 中的
  /// 主动恢复播放作为双保险。
  AudioSessionConfiguration get _audioSessionConfiguration {
    if (audioInterruptionEnabled) {
      return const AudioSessionConfiguration.music();
    }
    // 阻止打断模式：声明需要独占音频焦点，不因降音暂停
    return const AudioSessionConfiguration(
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      // 不因其他 App 降音而暂停
      androidWillPauseWhenDucked: false,
    );
  }

  Future<void> setAudioInterruptionEnabled(bool enabled) async {
    if (audioInterruptionEnabled == enabled) return;
    audioInterruptionEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_audioInterruptionEnabledSettingKey, enabled);
    // 设置变更后立即重新配置 AudioSession，使新策略生效
    unawaited(_reconfigureAudioSession());
    notifyListeners();
  }

  /// 重新配置 AudioSession 以应用最新的打断策略。
  Future<void> _reconfigureAudioSession() async {
    try {
      final session = await _audioSessionProvider();
      await session.configure(_audioSessionConfiguration);
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  Future<void> setAutoResumeAfterInterruption(bool enabled) async {
    if (autoResumeAfterInterruption == enabled) return;
    autoResumeAfterInterruption = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoResumeAfterInterruptionSettingKey, enabled);
    notifyListeners();
  }

  /// 开关「蓝牙断开停止播放」（默认开，上游 3.3.0 `56d0c9f`）。
  ///
  /// 关闭后回到旧行为：断开时仍会暂停（防外放是底线），但允许按
  /// [autoResumeAfterInterruption] 自行恢复。
  Future<void> setAutoPauseOnDeviceDisconnect(bool enabled) async {
    if (autoPauseOnDeviceDisconnect == enabled) return;
    autoPauseOnDeviceDisconnect = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPauseOnDeviceDisconnectSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setDesktopLyricsEnabled(bool enabled) async {
    if (desktopLyricsEnabled == enabled) return;
    desktopLyricsEnabled = enabled;
    // 显式开启/关闭都结束“临时隐藏”，避免开关打开了却仍因旧标记不显示。
    _desktopLyricsUserDismissed = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, enabled);
    notifyListeners();

    if (enabled) {
      final hasPermission = await _desktopLyrics.checkPermission();
      if (!hasPermission) {
        debugPrint('[时音][桌面歌词] 开启失败：checkPermission=false');
        desktopLyricsEnabled = false;
        await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
        notifyListeners();
        await _desktopLyrics.requestPermission();
        return;
      }
      final song = currentSong;
      if (song != null) {
        await _syncDesktopLyricsVisibility();
      }
    } else {
      await _desktopLyrics.hide();
    }
  }

  /// 通知卡片「桌面歌词」按钮的开关入口：与设置页开关同一状态源。区别在
  /// 无悬浮窗权限时的处理——不跳系统设置页（媒体卡片回调属于后台
  /// startActivity，会被后台启动限制拦截，用户也正盯着通知栏），改弹
  /// 原生 Toast 引导用户先在应用内开启一次；授权后此按钮即可长期使用。
  Future<void> toggleDesktopLyricsFromNotification() async {
    debugPrint('[SYNOTIF] 通知卡片词按钮触发：当前 desktopLyricsEnabled='
        '$desktopLyricsEnabled dismissed=$_desktopLyricsUserDismissed');
    // 临时隐藏期间点「词」按钮 = 恢复显示，而不是把功能真关掉。
    if (_desktopLyricsUserDismissed) {
      _desktopLyricsUserDismissed = false;
      await _syncDesktopLyricsVisibility();
      return;
    }
    if (desktopLyricsEnabled) {
      await setDesktopLyricsEnabled(false);
      return;
    }
    final granted = await _desktopLyrics.checkPermission();
    debugPrint('[SYNOTIF] 悬浮窗权限检查结果: $granted');
    if (!granted) {
      await _desktopLyrics.showToast('开启桌面歌词需要悬浮窗权限，请先在应用内开启一次桌面歌词');
      return;
    }
    await setDesktopLyricsEnabled(true);
  }

  bool get _shouldShowDesktopLyrics {
    if (!desktopLyricsEnabled || currentSong == null) return false;
    // 桌面端（Windows 等）：开启即显示，与前台/后台无关（PC 软件逻辑）。
    // AppLifecycleState 在桌面基本恒为 resumed，沿用移动端的
    // “后台才悬浮”判断会导致前台点开启毫无反应（图4问题）。
    if (isDesktopFormFactor) return true;
    // 设置页预览优先：用户可能刚点过「关闭」，预览仍应可见。
    if (_desktopLyricsPreviewVisible) return true;
    // 移动端：本次会话里点过悬浮窗关闭 → 保持隐藏，直到回前台/重新开启。
    if (_desktopLyricsUserDismissed) return false;
    return !_isAppForeground;
  }

  @override
  Future<void> _syncDesktopLyricsVisibility() async {
    if (!_shouldShowDesktopLyrics) {
      // transient=true 仅当“本会展示、只因 App 在前台而隐藏”：原生保留
      // 自愈标记与缓存歌词，回桌面可即时重建；关开关/无歌/用户点过关闭
      // 是显式隐藏，原生清除标记与缓存，不复活。
      await _desktopLyrics.hide(
        transient: desktopLyricsEnabled &&
            currentSong != null &&
            !_desktopLyricsUserDismissed,
      );
      return;
    }

    final song = currentSong;
    if (song == null) return;
    // 建窗前先把当前句写进主窗侧缓存：show 请求随内容一起下发，窗口一建出来
    // 就有字（伴奏期没有换句推送，空窗会一直挂到下一句）。
    _syncDesktopLyrics();
    final shown = await _desktopLyrics.show(
      title: song.title,
      artist: song.artist,
    );
    if (!shown) {
      debugPrint(
        '[时音][桌面歌词] 悬浮窗创建失败：检查 desktop_multi_window/window_manager 插件注册与窗口权限',
      );
    } else {
      // 原生设置在每次 ACTION_UPDATE_SETTINGS 时已落盘、onCreate 恢复，
      // 正常与 Flutter 侧一致；这里补推只为兜住"首次安装尚无持久化/原生
      // 偏好被清"的首帧（幂等）。歌词内容不再补推：show 请求自带
      // （上方 _syncDesktopLyrics 已把镜像备好），Windows 子窗创建参数同
      // 样自带，重复推送只会多一次 IPC。
      unawaited(_desktopLyrics.updateSettings(desktopLyricsSettings));
      _syncDesktopPlayState();
      _syncDesktopKaraokeProgress();
    }
  }

  @override
  void _syncDesktopLyrics() {
    final index = activeLyricIndex;
    if (lyrics.isEmpty) {
      // 无歌词也要把缓存清成空：否则切到没歌词的歌后回桌面，重建出来的是
      // 上一首的句子（show 请求自带空内容，原生不会再回退到旧缓存）。
      // 隐藏期间只写缓存，不发"上屏"类推送（悬浮窗本来就不在）。
      if (_shouldShowDesktopLyrics) {
        _desktopLyrics.updateLyrics(
          current: '',
          next: '',
          activeOnBottom: false,
        );
      } else if (desktopLyricsEnabled && !_desktopLyricsUserDismissed) {
        unawaited(
          _desktopLyrics.cacheNativeLyrics(
            current: '',
            next: '',
            activeOnBottom: false,
          ),
        );
      } else {
        _desktopLyrics.cacheLyrics(
          current: '',
          next: '',
          activeOnBottom: false,
        );
      }
      return;
    }
    final clamped = index.clamp(0, lyrics.length - 1);
    final current = lyrics[clamped].text;
    final nextIndex = clamped + 1;
    final next = nextIndex < lyrics.length ? lyrics[nextIndex].text : '';
    // 双行交替（乒乓）高亮：偶数句落在上行、奇数句落在下行。子窗据此把
    // 逐字进度交给"正在唱的那一行"，另一行换成下一句 —— 正在唱的那句
    // 文字始终不移动（历史实现里它每句都要从下行跳到上行）。
    final activeOnBottom = clamped.isOdd;
    if (!_shouldShowDesktopLyrics) {
      // App 在前台：悬浮窗被原生隐藏（移动端产品行为），但内容缓存必须继续
      // 跟随播放。回桌面时原生用这份缓存即刻重建 —— 伴奏（间奏）期间没有
      // 换句推送，只有缓存里存着"最后一次唱到的句子"，窗口才不会空到下一句。
      // 歌词开着时同步推给原生（原生只缓存、不建窗）；关开关时不推，避免
      // 无谓地把服务拉起来。用户点过关闭（临时隐藏）同样不推：此时开关
      // 仍是开的，逐句 cacheNativeLyrics 会反复 startService 把歌词服务
      // 拉起（每条歌词一次），长会话下是白耗电；下次真正展示前
      // _syncDesktopLyricsVisibility 会先 seeding 再 show，内容不会丢。
      if (desktopLyricsEnabled && !_desktopLyricsUserDismissed) {
        unawaited(
          _desktopLyrics.cacheNativeLyrics(
            current: current,
            next: next,
            activeOnBottom: activeOnBottom,
          ),
        );
      } else {
        _desktopLyrics.cacheLyrics(
          current: current,
          next: next,
          activeOnBottom: activeOnBottom,
        );
      }
      return;
    }
    _desktopLyrics.updateLyrics(
      current: current,
      next: next,
      activeOnBottom: activeOnBottom,
    );
  }

  void _syncDesktopPlayState() {
    if (!_shouldShowDesktopLyrics) return;
    _desktopLyrics.updatePlayState(isPlaying: isPlaying);
  }

  void _maybeSyncDesktopLyricFromPosition() {
    // 换句检测不按可见性提前返回：App 在前台（悬浮窗被原生隐藏）时也要把
    // 新句子送进缓存，回桌面重建才能立刻显示当前句（伴奏期的关键）。
    if (lyrics.isEmpty) return;
    final index = activeLyricIndex;
    if (index != _lastDesktopLyricIndex) {
      _lastDesktopLyricIndex = index;
      _syncDesktopLyrics();
    }
    // Karaoke progress for current line
    if (_shouldShowDesktopLyrics) {
      _syncDesktopKaraokeProgress();
    }
  }

  @override
  void _syncDesktopKaraokeProgress() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    final line = lyrics[index.clamp(0, lyrics.length - 1)];
    // 用带偏移的歌词位置：偏移只作用于歌词，不改变真实播放进度条。
    final position = lyricPosition;
    final lineDuration = line.duration ?? _estimatedLineDuration(index);
    // 有逐字时间时按字符占比分段映射（字间间隙停住不动），无逐字时间才
    // 退回整行线性推进。历史实现里 word 分支算的是与行级完全相同的线性
    // 进度（死分支），且行时长不可得时干脆不推送——高亮会停在半途。
    final progress = PlayerLyricProgressLogic.forLine(
      line: line,
      position: position,
      lineDuration: lineDuration,
    );
    _desktopLyrics.updateKaraokeProgress(
      progress: progress,
      lineDuration: lineDuration,
      isPlaying: isPlaying,
    );
  }

  Future<void> updateDesktopLyricsSettings(
    DesktopLyricsSettings settings,
  ) async {
    desktopLyricsSettings = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _desktopLyricsSettingsKey,
      jsonEncode(settings.toMap()),
    );
    await prefs.setInt(
      _desktopLyricsSettingsVersionKey,
      _desktopLyricsSettingsVersion,
    );
    debugPrint(
      '[时音][桌面歌词] 设置已保存 opacity=${settings.opacity} '
      'fontSize=${settings.fontSize}',
    );
    notifyListeners();
    await _desktopLyrics.updateSettings(settings);
  }

  bool get isDesktopLyricsSupported => DesktopLyricsService.isSupportedPlatform;

  void setAppForeground(bool isForeground) {
    // 回到前台即结束「临时关闭」：下次退到桌面/锁屏，悬浮窗自动恢复，
    // 不需要用户再去设置里重新打开（上游 166e84b）。
    // 必须在首行同值早退之前重置，否则 resumed→resumed 的重复通知会漏掉。
    if (isForeground) _desktopLyricsUserDismissed = false;
    if (_isAppForeground == isForeground) return;
    _isAppForeground = isForeground;
    if (desktopLyricsEnabled) {
      _desktopLyrics.setAppForeground(isForeground: isForeground);
      unawaited(_syncDesktopLyricsVisibility());
    }
  }

  Future<void> setDesktopLyricsPreviewVisible(bool visible) async {
    if (visible) _desktopLyricsUserDismissed = false;
    if (_desktopLyricsPreviewVisible == visible) return;
    _desktopLyricsPreviewVisible = visible;
    await _syncDesktopLyricsVisibility();
  }

  Future<void> _handleDesktopLyricsVisibility({
    required bool visible,
    required bool userClosed,
  }) async {
    if (!userClosed || !desktopLyricsEnabled) {
      return;
    }
    _desktopLyricsPreviewVisible = false;
    if (isDesktopFormFactor) {
      // PC：关闭悬浮窗 = 关闭功能（既有语义，保持不变）。
      desktopLyricsEnabled = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
    } else {
      // 移动端：仅本次后台会话临时隐藏，不写死持久化开关；回前台后
      // 下次退桌面/锁屏自动恢复自启动（上游 166e84b / issue #160）。
      _desktopLyricsUserDismissed = true;
    }
    notifyListeners();
    // 原生已自行关窗停服，这里再补一次显式关闭：既是幂等兜底，也能清掉
    // "用户点关闭那一刻正好在途的换句推送"刚写回原生的歌词缓存 —— 否则那份
    // 缓存会让原生把它当成"应展示"，在下次回桌面时把刚关掉的悬浮窗重建出来
    // （而 Flutter 侧开关已关，再也不会下发 hide，窗口会一直挂着）。
    await _desktopLyrics.hide();
  }

  void _handleDesktopLyricsPlaybackAction(String action) {
    switch (action) {
      case 'previous':
        unawaited(previous());
      case 'togglePlay':
        unawaited(togglePlay());
      case 'next':
        unawaited(next());
      // 悬浮窗快捷菜单的歌词进度调整：主窗是偏移的唯一真相源，子窗只发指令，
      // 调整结果沿既有推送链路（换行文本 + 逐字进度）自动回流到悬浮窗。
      case 'lyricOffsetEarlier':
        unawaited(adjustLyricOffset(kLyricOffsetStep));
      case 'lyricOffsetLater':
        unawaited(adjustLyricOffset(-kLyricOffsetStep));
      case 'lyricOffsetReset':
        unawaited(resetLyricOffset());
      default:
        debugPrint('[时音][player] 未知桌面歌词播控指令: $action');
    }
  }

  bool get desktopLyricsLocked => desktopLyricsSettings.locked;

  Future<void> setDesktopLyricsLocked(bool locked) async {
    if (desktopLyricsSettings.locked == locked) return;
    await updateDesktopLyricsSettings(
      desktopLyricsSettings.copyWith(locked: locked),
    );
  }

  Future<void> unlockDesktopLyrics() => setDesktopLyricsLocked(false);

  /// 子窗工具栏请求切换锁定：统一走 updateDesktopLyricsSettings（落盘 +
  /// notifyListeners 通知设置页 + 回推子窗后子窗重建并重设穿透）。
  /// 锁定语义 = QQ 音乐式全穿透；解锁入口为托盘/设置页。
  void _handleDesktopLyricsLockChanged(bool locked) {
    if (desktopLyricsSettings.locked == locked) return;
    unawaited(setDesktopLyricsLocked(locked));
  }

  Future<bool> checkDesktopLyricsPermission() =>
      _desktopLyrics.checkPermission();

  Future<void> requestDesktopLyricsPermission() =>
      _desktopLyrics.requestPermission();

  void _setupDesktopLyricsListeners() {
    _desktopLyrics.setVisibilityChangedHandler(_handleDesktopLyricsVisibility);
    _desktopLyrics.setPlaybackActionHandler(_handleDesktopLyricsPlaybackAction);
    _desktopLyrics.setLockChangedHandler(_handleDesktopLyricsLockChanged);
    _desktopLyrics.setSettingsChangedHandler((settings) async {
      await updateDesktopLyricsSettings(settings);
    });
    _desktopLyrics.setOpenSettingsHandler(_handleDesktopLyricsOpenSettings);
  }

  void _handleDesktopLyricsOpenSettings() {
    openDesktopLyricsSettingsPage();
  }

  /// 请求打开桌面歌词设置页（悬浮窗工具栏调起或外部手动调起）。
  void openDesktopLyricsSettingsPage() {
    if (_disposed) return;
    openLyricsSettingsRequest.value = false;
    openLyricsSettingsRequest.value = true;
    onOpenDesktopLyricsSettings?.call();
  }
}
