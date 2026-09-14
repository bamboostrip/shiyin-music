import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/rust_api_client.dart';
import '../models/model_parsing.dart' show normalizeImageUrl;
import '../models/song.dart';
import '../src/rust/api.dart' as rust;
// api.dart 只 import 不 re-export IdentifyCandidate,需直接引入声明文件
// (与 local_music_controller.dart 引 LocalSongEntry 同款做法)。
import '../src/rust/services/identify.dart' show IdentifyCandidate;

/// 采集后端接口(UI 测试可注入 fake;生产按平台选择)。
abstract class IdentifyCaptureBackend {
  /// 开始采集。[source] 仅桌面后端消费:"mic" 麦克风 / "system" 系统内录;
  /// Android 后端忽略(只有麦克风)。
  Future<void> start({String source = 'mic'});

  /// 停止并取末尾 [durationMs] 毫秒的 PCM;数据不足时返回已有部分,
  /// 完全无数据返回 null(Android 通道空缓冲即回 null,UI 层据此走空态)。
  Future<Uint8List?> stopAndCollect({int durationMs = 10000});

  /// 丢弃采集(用户取消/关页)。
  Future<void> cancel();
}

/// 听歌识曲服务:平台分流采集 PCM,识别统一走 Rust
/// (fingerprint.service,协议见 rust/src/services/identify.rs)。
///
/// - Windows/Linux:Rust cpal 采集(麦克风,或 WASAPI loopback 系统内录)
/// - Android:原生 AudioRecord 通道(原生 8000Hz 采集,免重采样)
/// - iOS/macOS/Web:不支持(Rust 引擎未接入,同响度分析的平台边界)
///
/// 采集生命周期(start/stop/cancel)由 UI 持有的 [IdentifyCaptureBackend]
/// 管理,本类只负责平台选择与候选映射,静态方法均可独立测试。
class IdentifyService {
  IdentifyService._();

  /// Android(原生通道)与桌面(Rust cpal)支持;iOS/macOS/Web 不支持。
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isWindows || Platform.isLinux;
  }

  /// 桌面走 Rust 采集,其余(即 Android)走原生通道。
  static bool get _useRustCapture =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  /// 当前平台的采集后端。仅应在 [isSupported] 为 true 的平台调用。
  static IdentifyCaptureBackend platformDefault() =>
      _useRustCapture ? _RustCaptureBackend() : _AndroidCaptureBackend();

  /// 上传 PCM 识别,返回按置信度降序的歌曲。识别失败(Rust Err/网络)
  /// 直接向上抛异常,由 UI 决定提示方式,这里不做静默兜底。
  static Future<List<({Song song, double confidence})>> identify(
    RustApiClient api,
    Uint8List pcm,
  ) async {
    final candidates = await api.identify(pcm);
    final matches = candidates.map(candidateToSong).toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return matches;
  }

  /// 候选 → 可播放 Song(纯函数)。置信度 = 1 - dist(dist 是上游匹配
  /// 距离,0~1 越小越准;钳制防脏数据算出负置信度)。
  static ({Song song, double confidence}) candidateToSong(
    IdentifyCandidate c,
  ) {
    final song = Song(
      // 生成层对酷狗指纹接口字段做了别名兜底,缺省为空串:无
      // albumAudioId 时用 hash 兜底 id,保证候选始终可被播放链路定位。
      id: c.albumAudioId.isNotEmpty ? c.albumAudioId : c.hash,
      title: c.name.isNotEmpty ? c.name : '未知歌曲',
      artist: c.singer.isNotEmpty ? c.singer : '未知艺人',
      hash: c.hash,
      albumId: c.albumId.isNotEmpty ? c.albumId : null,
      albumAudioId: c.albumAudioId.isNotEmpty ? c.albumAudioId : null,
      albumName: c.albumName.isNotEmpty ? c.albumName : null,
      coverUrl: c.cover.isNotEmpty ? _normalizeCover(c.cover) : null,
      duration: c.durationMs > 0 ? Duration(milliseconds: c.durationMs) : null,
    );
    return (song: song, confidence: 1.0 - c.dist.clamp(0.0, 1.0));
  }

  /// 酷狗指纹接口返回的封面常是图床相对路径(Rust 侧取自
  /// union_cover/sizable_cover/cover/img,与搜索接口同源),补前缀;
  /// 完整 URL 原样保留。sizable_cover 常带 {size} 占位符,占位符清洗
  /// 复用 model_parsing.normalizeImageUrl,不复制第二份逻辑。
  static String _normalizeCover(String raw) {
    final url = raw.startsWith('http') ? raw : 'https://imge.kugou.com/$raw';
    // normalizeImageUrl 签名返回 String?(null 入 → null 出),这里入参
    // 必非 null,结果也必非 null,用 ! 收窄。
    return normalizeImageUrl(url)!;
  }
}

/// 桌面 Rust 采集后端(cpal 采集 + 环形缓冲,生成函数 Err 时抛异常,
/// Dart 不再包一层 try)。
class _RustCaptureBackend implements IdentifyCaptureBackend {
  @override
  Future<void> start({String source = 'mic'}) =>
      rust.identifyStartCapture(source: source);

  @override
  Future<Uint8List?> stopAndCollect({int durationMs = 10000}) =>
      rust.identifyCaptureSnapshot(durationMs: durationMs);

  @override
  Future<void> cancel() => rust.identifyCancelCapture();
}

/// Android 原生 AudioRecord 采集后端(通道实现见
/// android/.../AudioCaptureHandler.kt)。
class _AndroidCaptureBackend implements IdentifyCaptureBackend {
  static const _channel = MethodChannel('shiyin_music/audio_capture');

  @override
  Future<void> start({String source = 'mic'}) async {
    // 先确保 RECORD_AUDIO 运行时权限,拒绝则抛错让 UI 提示去设置页。
    final granted = await _channel.invokeMethod<bool>('requestPermission');
    if (granted != true) {
      throw Exception('麦克风权限未授权');
    }
    await _channel.invokeMethod<dynamic>('start');
  }

  @override
  Future<Uint8List?> stopAndCollect({int durationMs = 10000}) =>
      _channel.invokeMethod<Uint8List>('stop', {'durationMs': durationMs});

  @override
  Future<void> cancel() => _channel.invokeMethod<dynamic>('cancel');
}
