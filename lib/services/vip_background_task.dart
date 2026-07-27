import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';
import 'music_api.dart';

/// 领取会员后的结果状态。
enum VipClaimStatus { none, success, alreadyClaimed, failed }

/// 单次领取会员的对外结果，供 UI 反馈使用。
class VipClaimResult {
  const VipClaimResult(this.status, this.message);

  final VipClaimStatus status;
  final String message;

  static const empty = VipClaimResult(VipClaimStatus.none, '');
}

/// 自动领取酷狗概念版每日 VIP 的后台任务。
///
/// 触发时机：应用启动 / 从后台恢复 / 登录成功（见 [AuthController] 与
/// [main.dart]），以及用户在设置页手动点击“立即领取”。
/// 去重 key 与上次结果持久化在 SharedPreferences，跨重启保留。
class VipBackgroundTask extends ChangeNotifier {
  VipBackgroundTask(this._api);

  final MusicApi _api;

  /// 领取成功后触发，供外部刷新 VIP 信息（如 AuthController.refreshProfile）。
  VoidCallback? onClaimSuccess;

  static const _autoEnabledKey = 'settings.auto_claim_vip_enabled';
  static const _lastRunKeyKey = 'settings.vip_last_run_key';
  static const _lastStatusKey = 'settings.vip_last_status';
  static const _lastMessageKey = 'settings.vip_last_message';
  static const _lastTimeKey = 'settings.vip_last_time';

  bool _loaded = false;
  bool _autoEnabled = true;
  bool _isClaiming = false;
  VipClaimStatus _lastStatus = VipClaimStatus.none;
  String _lastMessage = '';
  DateTime? _lastClaimTime;
  // 已成功跑过当日领取的去重 key（identity@date），跨重启持久化。
  String? _lastRunKey;
  // 记住最近一次有效 session，供 claimNow(null) 回退使用。
  LoginSession? _lastSession;

  bool get autoEnabled => _autoEnabled;
  bool get isClaiming => _isClaiming;
  VipClaimStatus get lastStatus => _lastStatus;
  String get lastMessage => _lastMessage;
  DateTime? get lastClaimTime => _lastClaimTime;

  /// 从持久化载入开关与上次结果（幂等）。
  Future<void> loadPrefsOnce() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _autoEnabled = prefs.getBool(_autoEnabledKey) ?? true;
    _lastRunKey = prefs.getString(_lastRunKeyKey);
    _lastStatus = VipClaimStatus.values.firstWhere(
      (s) => s.name == prefs.getString(_lastStatusKey),
      orElse: () => VipClaimStatus.none,
    );
    _lastMessage = prefs.getString(_lastMessageKey) ?? '';
    final millis = prefs.getInt(_lastTimeKey);
    if (millis != null) {
      _lastClaimTime = DateTime.fromMillisecondsSinceEpoch(millis);
    }
    _loaded = true;
    notifyListeners();
  }

  /// 开关切换：持久化 + 通知。开启时不立即触发，由后续 resume/restore 或手动领取触发。
  Future<void> setAutoEnabled(bool enabled) async {
    if (_autoEnabled == enabled) return;
    _autoEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoEnabledKey, enabled);
    notifyListeners();
  }

  /// 静默自动领取：受 [autoEnabled] 与当日去重 key 约束。
  void schedule(LoginSession? session) {
    if (session?.isValid == true) _lastSession = session;
    if (!_autoEnabled) return;
    if (_isClaiming) return;
    final runKey = _buildRunKey(session);
    if (runKey == null) return;

    _isClaiming = true;
    notifyListeners();
    unawaited(() async {
      await loadPrefsOnce();
      if (!_autoEnabled || runKey == _lastRunKey) {
        _isClaiming = false;
        notifyListeners();
        return;
      }
      await _performClaim(runKey);
      _isClaiming = false;
      notifyListeners();
    }());
  }

  /// 手动领取：跳过当日去重，返回结果供 UI 反馈。
  /// 传入 null 时回退到最近一次 schedule 记住的 session。
  Future<VipClaimResult> claimNow(LoginSession? session) async {
    await loadPrefsOnce();
    if (_isClaiming) return const VipClaimResult(VipClaimStatus.none, '正在领取中');
    final effectiveSession = session ?? _lastSession;
    final runKey = _buildRunKey(effectiveSession);
    if (runKey == null) {
      return const VipClaimResult(VipClaimStatus.failed, '未登录，无法领取');
    }

    _isClaiming = true;
    notifyListeners();
    try {
      return await _performClaim(runKey);
    } finally {
      _isClaiming = false;
      notifyListeners();
    }
  }

  /// 用于 UI 副标题的简要状态文案。
  String statusText() {
    if (_lastStatus == VipClaimStatus.none) {
      return '登录后自动领取每日 VIP';
    }
    final time = _lastClaimTime == null ? '' : _formatTime(_lastClaimTime!);
    switch (_lastStatus) {
      case VipClaimStatus.success:
        return '上次领取：$time 成功';
      case VipClaimStatus.alreadyClaimed:
        return '今日已领取 $time';
      case VipClaimStatus.failed:
        return '上次失败：${_lastMessage.isEmpty ? '请稍后重试' : _lastMessage}';
      case VipClaimStatus.none:
        return '登录后自动领取每日 VIP';
    }
  }

  String? _buildRunKey(LoginSession? session) {
    if (session?.isValid != true) return null;
    final identity =
        session?.userId ?? session?.sessionId ?? session?.token ?? '';
    if (identity.isEmpty) return null;
    final today = DateTime.now().toIso8601String().split('T').first;
    return '$identity@$today';
  }

  /// 执行 查记录→领取→升级 的完整流程，并持久化结果。
  Future<VipClaimResult> _performClaim(String runKey) async {
    VipClaimResult result;
    try {
      final history = await _api.vipReceiveHistory();
      if (history.status != 1) {
        result = VipClaimResult(
          VipClaimStatus.failed,
          '查询领取记录失败（${history.errorCode ?? '未知'}）',
        );
      } else {
        final today = DateTime.now().toIso8601String().split('T').first;
        VipReceiveItem? todayRecord;
        for (final item in history.items) {
          if (item.day == today) {
            todayRecord = item;
            break;
          }
        }

        if (todayRecord == null) {
          final daily = await _api.dailyVip();
          if (daily.status != 1) {
            result = VipClaimResult(
              VipClaimStatus.failed,
              '领取失败（${daily.errorCode ?? '未知'}）',
            );
          } else {
            await Future<void>.delayed(const Duration(seconds: 1));
            final upgraded = await _upgradeVipReward();
            result = upgraded
                ? const VipClaimResult(
                    VipClaimStatus.success, '今日已领取并升级为概念版 VIP',
                  )
                : const VipClaimResult(
                    VipClaimStatus.success, '今日 VIP 已领取，升级未成功',
                  );
          }
        } else if (todayRecord.vipType == 'tvip') {
          final upgraded = await _upgradeVipReward();
          result = upgraded
              ? const VipClaimResult(VipClaimStatus.success, '已升级为概念版 VIP')
              : const VipClaimResult(
                  VipClaimStatus.alreadyClaimed, '今日概念版 VIP 已领取',
                );
        } else {
          result = const VipClaimResult(
            VipClaimStatus.alreadyClaimed, '今日 VIP 已领取',
          );
        }
      }
    } catch (error, stackTrace) {
      result = VipClaimResult(VipClaimStatus.failed, '领取异常：$error');
      debugPrint('[KA Music][vip-task] claim failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    _lastStatus = result.status;
    _lastMessage = result.message;
    _lastClaimTime = DateTime.now();
    // 仅在成功或已领取时记录当日去重 key，避免失败后当日不再重试。
    if (result.status == VipClaimStatus.success ||
        result.status == VipClaimStatus.alreadyClaimed) {
      _lastRunKey = runKey;
    }
    await _persistState();
    if (result.status == VipClaimStatus.success) {
      onClaimSuccess?.call();
    }
    notifyListeners();
    return result;
  }

  Future<bool> _upgradeVipReward() async {
    final result = await _api.upgradeVipReward();
    return result.status == 1;
  }

  Future<void> _persistState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastStatusKey, _lastStatus.name);
      await prefs.setString(_lastMessageKey, _lastMessage);
      await prefs.setInt(
        _lastTimeKey,
        _lastClaimTime!.millisecondsSinceEpoch,
      );
      if (_lastRunKey != null) {
        await prefs.setString(_lastRunKeyKey, _lastRunKey!);
      }
    } catch (error) {
      debugPrint('[KA Music][vip-task] persist state failed: $error');
    }
  }

  String _formatTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.month}-${t.day} $hh:$mm';
  }
}
