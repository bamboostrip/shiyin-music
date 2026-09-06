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
      await _desktopLyrics.hide();
      return;
    }

    final song = currentSong;
    if (song == null) return;
    final shown = await _desktopLyrics.show(
      title: song.title,
      artist: song.artist,
    );
    if (!shown) {
      debugPrint(
        '[时音][桌面歌词] 悬浮窗创建失败：检查 desktop_multi_window/window_manager 插件注册与窗口权限',
      );
    } else {
      _syncDesktopLyrics();
      _syncDesktopPlayState();
      _syncDesktopKaraokeProgress();
    }
  }

  @override
  void _syncDesktopLyrics() {
    if (!_shouldShowDesktopLyrics) return;
    final index = activeLyricIndex;
    if (lyrics.isEmpty) {
      _desktopLyrics.updateLyrics(current: '', next: '');
      return;
    }
    final current = lyrics[index.clamp(0, lyrics.length - 1)].text;
    final nextIndex = index + 1;
    final next = nextIndex < lyrics.length ? lyrics[nextIndex].text : '';
    _desktopLyrics.updateLyrics(current: current, next: next);
  }

  void _syncDesktopPlayState() {
    if (!_shouldShowDesktopLyrics) return;
    _desktopLyrics.updatePlayState(isPlaying: isPlaying);
  }

  void _maybeSyncDesktopLyricFromPosition() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    if (index != _lastDesktopLyricIndex) {
      _lastDesktopLyricIndex = index;
      _syncDesktopLyrics();
    }
    // Karaoke progress for current line
    _syncDesktopKaraokeProgress();
  }

  void _syncDesktopKaraokeProgress() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    final line = lyrics[index.clamp(0, lyrics.length - 1)];
    final position = smoothPosition;
    final lineDuration = line.duration ?? _estimatedLineDuration(index);

    if (line.words.isEmpty) {
      // No word-level data: estimate progress from line duration
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      } else {
        _desktopLyrics.updateKaraokeProgress(
          progress: 1.0,
          lineDuration: null,
          isPlaying: isPlaying,
        );
      }
    } else {
      // Word-level: find active word and compute progress
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      }
    }
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
}
