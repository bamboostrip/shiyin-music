import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/music_models.dart';
import 'local_artwork_service.dart';

/// 系统媒体会话侧「本地封面」的解析状态机（issue #34）。
///
/// 本地歌的 `coverUrl` 是进程内伪 URL（`localart://…`），系统解析不了；要让
/// 通知栏/锁屏显示封面，必须先把内嵌图落盘、再把 `file://` URI 发给系统。
/// 落盘要解析音频文件（几十到几百毫秒），不能拖住首次 MediaItem 下发——
/// 所以分两拍：先无图发，落盘完成后经 [onReady] 让持有者重发。
///
/// 从 `MusicAudioHandler` 抽成独立类：handler 的字段初始化会 new 真实
/// AudioPlayer，仓库明令禁止在单测里创建；解析器只依赖两个注入的回调，
/// 切歌竞态、失败重试这些时序逻辑才能被直接钉住。
class SystemMediaArtResolver {
  SystemMediaArtResolver({
    required this.resolve,
    required this.onReady,
  });

  /// 把伪 URL 的目标（文件路径 / `content://` 地址）落盘，返回可交给系统的
  /// `file://` URI；返回 null = 没有可下发的封面。
  final Future<Uri?> Function(String target) resolve;

  /// 当前歌曲的封面就绪时回调，持有者据此重发 MediaItem。只在「当前歌」的
  /// 封面就绪时触发，解析途中已切歌的旧结果不会回调。
  final void Function() onReady;

  /// 正在解析 / 已解析的目标；null 表示当前没有需要跟进的本地封面。
  String? _target;

  /// [_target] 对应的落盘 URI；目标相同但这里是 null = 还在解析。
  Uri? _uri;

  /// 下发给系统媒体会话的封面 URI（没有则 null）。
  ///
  /// 在线封面原样透传。本地封面只认「当前这一份」：伪 URL 本身对系统没有
  /// 意义，发出去只会让它拿着坏 URI 去请求，所以非当前歌、或当前歌尚未
  /// 落盘完成时一律给 null（按无图处理）。
  Uri? artUriFor(String? coverUrl) {
    if (coverUrl == null) return null;
    if (!LocalArtworkService.isArtworkUrl(coverUrl)) {
      return Uri.tryParse(coverUrl);
    }
    final target = LocalArtworkService.targetOf(coverUrl);
    return target != null && target == _target ? _uri : null;
  }

  /// 让当前歌曲的本地封面进入解析；在线歌、无封面的歌直接返回。
  ///
  /// 每次换歌（[Song] 的封面目标变化）调用一次，同曲重载不会重复解析。
  void ensure(Song song) {
    final coverUrl = song.coverUrl;
    final target =
        coverUrl == null ? null : LocalArtworkService.targetOf(coverUrl);
    // 在线歌/无封面歌没有可落盘目标：必须清掉上一首的本地目标。否则之后
    // 再切回同一首本地歌时 target == _target 会提前返回，若期间系统清掉了
    // 缓存文件，_uri 就永远指向一个不存在的文件，再也不会重新落盘。
    if (target == null) {
      _target = null;
      _uri = null;
      return;
    }
    if (target == _target) return;
    _target = target;
    _uri = null;
    unawaited(() async {
      Uri? uri;
      try {
        uri = await resolve(target);
      } catch (error) {
        // 解析失败不能外抛：这里跑在无人等待的异步链上，上抛即未处理异常。
        debugPrint('[AudioHandler] 系统封面落盘失败: $target ($error)');
      }
      // 解析期间已切歌：这份结果不属于当前歌，丢弃（文件已在盘上，下次
      // 轮到它时直接命中），绝不能把上一首的封面贴到新歌上。
      if (_target != target) return;
      if (uri == null) {
        // 无图/读取失败不缓存否定结果：同曲再 ensure 时重试，外接盘
        // 挂载完成后即可自愈。确定无图的情况读取层有负缓存，重试不读盘。
        _target = null;
        return;
      }
      _uri = uri;
      // onReady 会重发 MediaItem，属于无人等待的异步链：handler 关闭/热重启
      // 等竞态下它可能抛异常，不能让它变成未处理异步异常。
      try {
        onReady();
      } catch (error, stack) {
        debugPrint('[AudioHandler] 系统封面就绪回调失败(忽略): $error\n$stack');
      }
    }());
  }
}
