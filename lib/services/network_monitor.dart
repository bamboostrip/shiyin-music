import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// 网络状态监听。
///
/// 车机会在 WiFi / 蜂窝数据 / 离线之间频繁切换，App 此前对切换完全无感知：
/// 断网瞬间的请求直接失败，恢复后也不会自动重试。这里统一监听网络变化，
/// 在"从无网恢复到有网"时通过 [onConnectivityRestored] 通知上层恢复播放。
class NetworkMonitor {
  NetworkMonitor._();

  static final NetworkMonitor instance = NetworkMonitor._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  /// 网络从不可用恢复到可用时触发（车机切网 / 重新连接）。
  final _restored = StreamController<void>.broadcast();
  Stream<void> get onConnectivityRestored => _restored.stream;

  bool _hasNetwork = false;
  bool get hasNetwork => _hasNetwork;

  /// 是否已订阅系统网络变化。
  bool get isListening => _sub != null;

  Future<void> start() async {
    if (_sub != null) return;
    _hasNetwork = await _checkNow();
    _sub = _connectivity.onConnectivityChanged.listen(_onChanged);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<bool> _checkNow() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  void _onChanged(List<ConnectivityResult> results) {
    final hasNetwork = results.any((r) => r != ConnectivityResult.none);
    final wasOffline = !_hasNetwork;
    _hasNetwork = hasNetwork;
    if (hasNetwork && wasOffline && !_restored.isClosed) {
      _restored.add(null);
    }
  }

  void dispose() {
    _restored.close();
  }
}
