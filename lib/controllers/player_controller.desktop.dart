// player_controller.desktop.dart —— PlayerController 的职责分片：桌面歌词与系统集成（悬浮窗歌词/卡拉OK进度/AudioSession 打断策略/设备接入自动播放）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerDesktop on _PlayerControllerBase {
  Future<void> _setupAudioSessionListeners() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          // 打断开始：系统可能已自动暂停播放器。
          // 若开启了"阻止打断"，立即恢复播放以对抗暂停。
          if (!audioInterruptionEnabled && isPlaying && currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 300), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_audioHandler.play());
              }
            });
          }
        } else {
          // 打断结束：若开启了"自动恢复"或"阻止打断"，恢复播放。
          if ((autoResumeAfterInterruption || (!audioInterruptionEnabled)) &&
              currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_audioHandler.play());
              }
            });
          }
        }
      });
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        if (!audioInterruptionEnabled) {
          // 阻止打断模式下忽略耳机拔出
          return;
        }
        if (autoResumeAfterInterruption && currentSong != null) {
          _autoResumeTimer?.cancel();
          _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
            if (!isPlaying && currentSong != null) {
              unawaited(_audioHandler.play());
            }
          });
        }
      });
      _previousDevices = await session.getDevices();
      _devicesSub = session.devicesStream.listen((devices) {
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
                !isPlaying) {
              _autoResumeTimer?.cancel();
              _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
                if (!isPlaying && currentSong != null) {
                  unawaited(_audioHandler.play());
                }
              });
            }
          }
        }
        _previousDevices = devices;
      });
    } catch (_) {
      // AudioSession not available on this platform
    }
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
      final session = await AudioSession.instance;
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

  Future<void> setDesktopLyricsEnabled(bool enabled) async {
    if (desktopLyricsEnabled == enabled) return;
    desktopLyricsEnabled = enabled;
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
        '$desktopLyricsEnabled');
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
    return !_isAppForeground || _desktopLyricsPreviewVisible;
  }

  @override
  Future<void> _syncDesktopLyricsVisibility() async {
    if (!_shouldShowDesktopLyrics) {
      // transient=true 仅当“本会展示、只因 App 在前台而隐藏”：原生保留
      // 自愈标记与缓存歌词，回桌面可即时重建；关开关/无歌是显式关闭，
      // 原生清除标记与缓存，不复活。
      await _desktopLyrics.hide(
        transient: desktopLyricsEnabled && currentSong != null,
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
      // 悬浮窗每次创建都是原生默认值（白字/双行/不透明度 0.8）：用户在设置页
      // 调好的配色/行数/透明度只在“设置变更”时下发，首次显示（冷启动、切歌
      // 拉起服务）会用原生默认把高亮颜色盖错——这里显示成功后补推一次当前
      // 设置，保证卡拉 OK 高亮色第一次就正确。Windows 子窗同理（幂等重建）。
      unawaited(_desktopLyrics.updateSettings(desktopLyricsSettings));
      _syncDesktopLyrics();
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
      } else if (desktopLyricsEnabled) {
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
      // 无谓地把服务拉起来。
      if (desktopLyricsEnabled) {
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

  void _syncDesktopKaraokeProgress() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    final line = lyrics[index.clamp(0, lyrics.length - 1)];
    final position = smoothPosition;
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
    if (_isAppForeground == isForeground) return;
    _isAppForeground = isForeground;
    if (desktopLyricsEnabled) {
      _desktopLyrics.setAppForeground(isForeground: isForeground);
      unawaited(_syncDesktopLyricsVisibility());
    }
  }

  Future<void> setDesktopLyricsPreviewVisible(bool visible) async {
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
    desktopLyricsEnabled = false;
    _desktopLyricsPreviewVisible = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
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
