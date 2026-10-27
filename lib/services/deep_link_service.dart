import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// AI / 外部唤起的 DeepLink 指令（URL Scheme：`shiyin://`）。
///
/// 协议（与上游 3.3.0 #152 对等，仅 Android 原生侧）：
/// - `shiyin://play?keyword=晴天` / `shiyin://play?song=晴天`：搜索并播放第一首
/// - `shiyin://control?action=next|prev|previous|play|pause|toggle`：播控
///
/// 设计：解析（[DeepLinkService.parse]）是纯函数，分发通过构造时注入的
/// [DeepLinkService.onCommand] 回调完成，因此单测不依赖真实播放器/网络。
/// 原生侧无实现（桌面平台）、链接非法或执行失败时一律静默，绝不影响启动。
sealed class DeepLinkCommand {
  const DeepLinkCommand();
}

/// 搜索并播放第一首（`shiyin://play?keyword=|song=`）。
class DeepLinkPlayCommand extends DeepLinkCommand {
  const DeepLinkPlayCommand(this.query);

  /// 已 trim 的非空搜索词/歌名。
  final String query;
}

/// 播控指令取值（`shiyin://control?action=`）。
enum DeepLinkControlAction { next, previous, play, pause, toggle }

/// 播控（`shiyin://control?action=`）。
class DeepLinkControlCommand extends DeepLinkCommand {
  const DeepLinkControlCommand(this.action);

  final DeepLinkControlAction action;
}

typedef DeepLinkCommandHandler = Future<void> Function(DeepLinkCommand command);

/// `shiyin://` DeepLink 的解析与分发。
class DeepLinkService {
  DeepLinkService({
    required this.onCommand,
    @visibleForTesting MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(channelName);

  /// 与 Android MainActivity 对应的 MethodChannel 名（fork 命名空间）。
  static const String channelName = 'shiyin_music/deep_link';

  /// URL Scheme（fork 品牌名）。
  static const String scheme = 'shiyin';

  /// 原生 → Dart：热启动（singleTop onNewIntent）推送链接的方法名。
  static const String methodOnDeepLink = 'onDeepLink';

  /// Dart → 原生：索取冷启动链接的方法名。
  static const String methodGetInitialLink = 'getInitialLink';

  final DeepLinkCommandHandler onCommand;
  final MethodChannel _channel;
  bool _started = false;
  bool _disposed = false;

  /// 纯解析：把 `shiyin://` 链接转成指令对象。
  ///
  /// 非法 scheme/host、空参数、未知 action 等一律返回 null（静默丢弃）。
  static DeepLinkCommand? parse(String? link) {
    if (link == null) return null;
    final text = link.trim();
    if (text.isEmpty) return null;
    try {
      final uri = Uri.tryParse(text);
      if (uri == null || uri.scheme.toLowerCase() != scheme) return null;
      final action = uri.host.toLowerCase();
      final params = uri.queryParameters;
      switch (action) {
        case 'play':
          // keyword 为主协议字段；song/q/title 为上游兼容别名。
          final query =
              params['keyword'] ??
              params['song'] ??
              params['q'] ??
              params['title'];
          final trimmed = query?.trim();
          if (trimmed == null || trimmed.isEmpty) return null;
          return DeepLinkPlayCommand(trimmed);
        case 'control':
          final command = (params['action'] ?? params['cmd'])
              ?.trim()
              .toLowerCase();
          switch (command) {
            case 'next':
              return const DeepLinkControlCommand(DeepLinkControlAction.next);
            case 'prev':
            case 'previous':
              return const DeepLinkControlCommand(
                DeepLinkControlAction.previous,
              );
            case 'play':
              return const DeepLinkControlCommand(DeepLinkControlAction.play);
            case 'pause':
              return const DeepLinkControlCommand(DeepLinkControlAction.pause);
            case 'toggle':
              return const DeepLinkControlCommand(DeepLinkControlAction.toggle);
            default:
              return null;
          }
        default:
          return null;
      }
    } catch (_) {
      // Uri 解码异常（如非法百分号转义）等：按非法链接静默丢弃。
      return null;
    }
  }

  /// 开始监听原生推送并同步冷启动链接。
  ///
  /// 不阻塞调用方（main 中 `unawaited` 调用）：桌面平台没有原生实现时
  /// `invokeMethod` 抛 MissingPluginException，被静默吞掉。
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    await requestInitialLink();
  }

  /// 主动向原生再取一次「冷启动链接」。
  ///
  /// 冷启动（引擎新建）时由 [start] 拉取；此外 Android 上 Activity 被回收
  /// 重建而 Dart 引擎仍存活（后台播放场景）时，新 Activity 会把链接暂存到
  /// 原生侧，但 Dart 初始化已完成、不会自动再取——由 main 在前台恢复时补拉
  /// 一次。原生侧取走后置空，重复调用天然幂等，不会重复执行同一条链接。
  Future<void> requestInitialLink() async {
    if (_disposed) return;
    try {
      final link = await _channel.invokeMethod<String>(methodGetInitialLink);
      if (link != null && link.isNotEmpty) {
        await handleLink(link);
      }
    } catch (error) {
      // 桌面平台无原生 channel（MissingPluginException）或原生侧异常：静默。
      debugPrint('[DeepLink] 获取冷启动链接失败（忽略）: $error');
    }
  }

  /// 处理一条链接：解析失败静默返回，回调异常仅记录不向外抛。
  Future<void> handleLink(String link) async {
    if (_disposed) return;
    final command = parse(link);
    if (command == null) return;
    try {
      await onCommand(command);
    } catch (error) {
      // DeepLink 属于外部输入：任何失败都不能冒泡成未捕获异常导致崩溃。
      debugPrint('[DeepLink] 执行指令失败（忽略）: $error');
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != methodOnDeepLink) return null;
    final link = call.arguments;
    if (link is String && link.isNotEmpty) {
      await handleLink(link);
    }
    return null;
  }

  /// 摘除原生回调（主界面销毁时调用），之后到达的链接直接丢弃。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
  }
}
