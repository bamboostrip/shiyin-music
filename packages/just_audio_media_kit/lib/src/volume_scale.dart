library just_audio_media_kit;

import 'dart:math' as math;

/// just_audio 线性幅度音量 → mpv volume 属性值（立方刻度）。
///
/// just_audio 的 volume 契约是线性幅度（1.0 = 原幅度），而 mpv 的 volume
/// 属性是立方刻度：实际增益 = (volume/100)³，即 dB = 60·log10(volume/100)
/// （见 mpv 源码 player/audio.c 的 audio_get_gain）。因此不能把线性值直接
/// ×100 传给 mpv——那会把所有增益的 dB 值放大 3 倍（0.5 → -18dB 而非
/// -6dB；2.0 → +18dB 而非 +6dB），表现为"轻歌炸、响歌哑"。正确换算是
/// 取立方根：mpv_volume = 100 × linear^(1/3)。
///
/// 线性 1.0 → 100（0dB）；线性 2.0 → ≈125.99（+6dB）；线性 0.5 →
/// ≈79.37（-6dB）。
double mpvVolumeFromLinear(double linear) {
  if (linear <= 0) return 0;
  return 100.0 * math.pow(linear, 1.0 / 3.0);
}

/// mpv volume 属性值（立方刻度）→ just_audio 线性幅度音量。
///
/// [mpvVolumeFromLinear] 的反向换算（立方：linear = (mpv_volume/100)³），
/// 用于 volume 流回读。mpv 回发的 volume 是立方刻度，若直接除以 100 当
/// 线性值，just_audio 内部音量状态会漂移（0.5 被回读成 0.79）。
double linearFromMpvVolume(double mpvVolume) {
  final scaled = mpvVolume / 100.0;
  if (scaled <= 0) return 0;
  return math.pow(scaled, 3).toDouble();
}
