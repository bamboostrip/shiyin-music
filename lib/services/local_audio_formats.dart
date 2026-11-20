import 'package:flutter/foundation.dart';

/// 本地音频“能不能放”的能力判定。
///
/// 背景（issue #32）：本地音乐列表来自**媒体库枚举**（Android MediaStore、
/// 桌面 Rust 扫描），而真正解码的是平台播放内核（桌面 mpv、Android
/// ExoPlayer、Apple AVFoundation）——两者的格式支持范围并不一致。此前
/// 列表照单全收、播放直接交给内核，内核不支持时只会抛一个「Failed to
/// open http://127.0.0.1:xxxxx/play/1.ape」，最终被播放失败处理统一糊成
/// 「暂无可播放音源」：用户既不知道是格式问题，也不知道该怎么办。
///
/// 这里把「内核能力」显式建模，供三处使用：
/// - [PlayerController.playSong] 在交给内核前判定，避免用确定性失败去
///   污染连续失败计数、也避免白等引擎超时；
/// - 失败提示据此给出可行动文案（点名后缀，建议转码）；
/// - 桌面扫描白名单与代理的 Content-Type 表与之对齐（见
///   `rust/src/services/local_media.rs` 与 `MusicAudioHandler`）。
///
/// 判定原则：**只拦确定不支持的后缀**。未知后缀、未知平台一律放行——
/// 宁可让内核自己去试（它可能恰好能放），也不能凭一张表把用户能放的文件
/// 判死。
enum LocalAudioEngine {
  /// 桌面（Windows / Linux）：media_kit(libmpv)，实际由 ffmpeg 解码。
  mpv,

  /// Android：just_audio → ExoPlayer(media3)。
  exoPlayer,

  /// iOS / macOS：AVPlayer。
  avFoundation,

  /// 未知平台（Web / Fuchsia 等）：不做拦截。
  unknown,
}

/// 平台 → 播放内核。抽成纯函数是为了能在单测里遍历所有平台。
LocalAudioEngine localAudioEngineFor(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.windows || TargetPlatform.linux => LocalAudioEngine.mpv,
    TargetPlatform.android => LocalAudioEngine.exoPlayer,
    TargetPlatform.iOS || TargetPlatform.macOS => LocalAudioEngine.avFoundation,
    _ => LocalAudioEngine.unknown,
  };
}

/// 当前进程实际使用的播放内核。
LocalAudioEngine get currentLocalAudioEngine => kIsWeb
    ? LocalAudioEngine.unknown
    : localAudioEngineFor(defaultTargetPlatform);

/// 各内核**确定能**解码的容器/后缀（小写、不含点）。
///
/// - mpv / ffmpeg：几乎全格式，含 APE/WMA/WavPack/DSD 与 AIFF；
/// - ExoPlayer(media3)：MP4 家族、Matroska/WebM、MP3、FLAC、Ogg/Opus、
///   WAV、ADTS AAC、AMR。**没有** AIFF/APE/WMA/DSD/WavPack 解析器；
/// - AVFoundation：MP3/AAC/M4A/WAV/AIFF/CAF/FLAC（iOS 11+），不含
///   APE/WMA/OGG。
const Map<LocalAudioEngine, Set<String>> localAudioSupportedExtensions = {
  LocalAudioEngine.mpv: {
    'mp3',
    'flac',
    'wav',
    'ogg',
    'oga',
    'opus',
    'm4a',
    'm4b',
    'mp4',
    'aac',
    'aiff',
    'aif',
    'aifc',
    'ape',
    'wma',
    'wv',
    'tta',
    'mka',
    'caf',
    'dsf',
    'dff',
  },
  LocalAudioEngine.exoPlayer: {
    'mp3',
    'flac',
    'wav',
    'ogg',
    'oga',
    'opus',
    'm4a',
    'm4b',
    'mp4',
    'aac',
    'mka',
    'amr',
  },
  LocalAudioEngine.avFoundation: {
    'mp3',
    'm4a',
    'm4b',
    'mp4',
    'aac',
    'wav',
    'aiff',
    'aif',
    'aifc',
    'caf',
    'flac',
  },
  // 未识别平台：空集合 = 不拦截（见 [isSupportedLocalAudio]）。
  LocalAudioEngine.unknown: <String>{},
};

/// 取本地文件后缀（小写、不含点）。路径式与 `file://` 都接受；无后缀返回 null。
String? localAudioExtensionOf(String path) {
  var name = path;
  if (name.contains('://')) {
    name = Uri.tryParse(name)?.path ?? '';
  }
  final slash = name.lastIndexOf(RegExp(r'[/\\]'));
  final base = slash >= 0 ? name.substring(slash + 1) : name;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return null;
  return base.substring(dot + 1).toLowerCase();
}

/// 全部内核认识的音频后缀并集。用于区分「明确知道不支持」与「压根不认识」。
final Set<String> knownLocalAudioExtensions = {
  for (final set in localAudioSupportedExtensions.values) ...set,
};

/// 当前内核能否解码该本地文件。
///
/// 判定顺序：无后缀 → 放行；后缀不在 [knownLocalAudioExtensions] 里
/// （我们完全没有该格式的能力情报）→ 放行交给内核试；其余按目标内核的
/// 白名单判定。
///
/// 也就是说这里**只拦确定不支持**的格式：宁可让内核报一次错，也不能凭
/// 一张表把用户能放的文件判死。
bool isSupportedLocalAudio(String path, {LocalAudioEngine? engine}) {
  final ext = localAudioExtensionOf(path);
  if (ext == null) return true;
  if (!knownLocalAudioExtensions.contains(ext)) return true;
  final supported = localAudioSupportedExtensions[engine ?? currentLocalAudioEngine];
  if (supported == null || supported.isEmpty) return true;
  return supported.contains(ext);
}

/// 不支持的**原因**（可直接展示给用户）；支持或未知返回 null。
///
/// 文案刻意点名后缀并给出出路：这类失败是能力边界，不是网络抖动，
/// 用户重试一百次也不会变好。
String? unsupportedLocalAudioReason(String path, {LocalAudioEngine? engine}) {
  if (isSupportedLocalAudio(path, engine: engine)) return null;
  final ext = localAudioExtensionOf(path);
  final suffix = ext == null ? '该' : '.$ext';
  return '当前播放内核无法解码 $suffix 格式，可转成 FLAC/MP3 后再试';
}
