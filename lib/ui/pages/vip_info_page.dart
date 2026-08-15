import 'package:flutter/material.dart';
import '../design_tokens.dart';

import '../../controllers/auth_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../adaptive_layout.dart';
import '../widgets/toast.dart';

/// 我的 VIP 信息页。
class VipInfoPage extends StatefulWidget {
  const VipInfoPage({super.key, required this.api, required this.auth});

  final MusicApi api;
  final AuthController auth;

  @override
  State<VipInfoPage> createState() => _VipInfoPageState();
}

class _VipInfoPageState extends State<VipInfoPage> {
  UserVipInfo? _vip;
  VipReceiveHistory? _history;
  var _isLoading = true;
  var _isClaiming = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.api.userVipDetail(),
        widget.api.vipReceiveHistory(),
      ]);
      if (!mounted) return;
      setState(() {
        _vip = results[0] as UserVipInfo;
        _history = results[1] as VipReceiveHistory;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _claimDailyVip() async {
    if (_isClaiming) return;
    setState(() => _isClaiming = true);
    try {
      final result = await widget.api.dailyVip();
      if (!mounted) return;
      if (result.status == 1) {
        Toast.success('领取成功，快去体验 VIP 特权吧');
      } else {
        Toast.info('今日已领取或暂不可领取');
      }
      await _load();
    } catch (e) {
      if (mounted) Toast.error('领取失败：$e');
    } finally {
      if (mounted) setState(() => _isClaiming = false);
    }
  }

  /// 今天是否已领取过 VIP（含后台自动领取）。
  bool _isClaimedToday(VipReceiveHistory? history) {
    if (history == null) return false;
    final today = DateTime.now().toIso8601String().split('T').first;
    for (final item in history.items) {
      if (item.day == today && item.receiveVip == 1) return true;
    }
    return false;
  }

  int get _calendarYear {
    final month = _history?.month;
    if (month != null && month.length >= 7) {
      return int.tryParse(month.substring(0, 4)) ?? DateTime.now().year;
    }
    return DateTime.now().year;
  }

  int get _calendarMonth {
    final month = _history?.month;
    if (month != null && month.length >= 7) {
      return int.tryParse(month.substring(5, 7)) ?? DateTime.now().month;
    }
    return DateTime.now().month;
  }

  /// 本月已领取的日期（按日去重）。
  Set<int> get _claimedDays {
    final result = <int>{};
    final prefix =
        '$_calendarYear-${_calendarMonth.toString().padLeft(2, '0')}';
    for (final item in _history?.items ?? const <VipReceiveItem>[]) {
      if (item.receiveVip == 1 && (item.day?.startsWith(prefix) ?? false)) {
        final day = int.tryParse((item.day ?? '').split('-').last);
        if (day != null) result.add(day);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的 VIP')),
      body: AdaptiveContentPadding(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4))
            : _error != null
            ? _buildError(context)
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    _VipStatusCard(vip: _vip),
                    const SizedBox(height: 16),
                    _DailyVipCard(
                      isClaiming: _isClaiming,
                      claimedToday: _isClaimedToday(_history),
                      onClaim: _claimDailyVip,
                    ),
                    if ((_vip?.busiVip.isNotEmpty ?? false)) ...[
                      const SizedBox(height: 24),
                      const _SectionTitle('业务线 VIP'),
                      const SizedBox(height: 8),
                      ..._vip!.busiVip.map((info) => _BusiVipTile(info: info)),
                    ],
                    if ((_history?.items.isNotEmpty ?? false)) ...[
                      const SizedBox(height: 24),
                      const _SectionTitle('本月领取记录'),
                      const SizedBox(height: 4),
                      _VipCalendar(
                        year: _calendarYear,
                        month: _calendarMonth,
                        claimedDays: _claimedDays,
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 56,
            color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
          ),
          const SizedBox(height: 12),
          Text(
            '加载失败：$_error',
            textAlign: TextAlign.center,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// VIP 状态卡片。
class _VipStatusCard extends StatelessWidget {
  const _VipStatusCard({required this.vip});

  final UserVipInfo? vip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isVip = vip?.hasVip ?? false;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isVip
              ? const [Color(0xFFF7D774), Color(0xFFE8A33D), Color(0xFFB96A1F)]
              : [
                  colorScheme.surfaceContainerHighest,
                  colorScheme.surfaceContainer,
                ],
        ),
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Row(
        children: [
          Icon(
            Icons.workspace_premium_rounded,
            size: 44,
            color: isVip ? Colors.white : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isVip ? 'VIP 会员已开通' : '暂未开通 VIP',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: isVip ? Colors.white : colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _statusText(isVip),
                  style: TextStyle(
                    fontSize: 13,
                    color: isVip
                        ? Colors.white.withValues(alpha: .92)
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _statusText(bool isVip) {
    if (!isVip) return '开通后可享受高品质音乐与更多特权';
    final tags = <String>[];
    if (vip?.isSuperVip == true) tags.add('超级 VIP');
    if (vip?.isConceptVip == true) tags.add('概念版 VIP');
    if (tags.isEmpty) tags.add('VIP');
    final typeText = vip?.vipType != null ? '类型 ${vip!.vipType}' : null;
    return [tags.join(' · '), ?typeText].join(' · ');
  }
}

/// 每日 VIP 领取卡片。
class _DailyVipCard extends StatelessWidget {
  const _DailyVipCard({
    required this.isClaiming,
    required this.claimedToday,
    required this.onClaim,
  });

  final bool isClaiming;
  final bool claimedToday;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Icon(
            Icons.card_giftcard_rounded,
            color: colorScheme.primary,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '每日 VIP 福利',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  claimedToday ? '今日福利已领取，明天再来吧' : '每天可领取一次体验 VIP',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: isClaiming || claimedToday ? null : onClaim,
            child: isClaiming
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : Text(claimedToday ? '今日已领取' : '领取'),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
    );
  }
}

/// 业务线 VIP 信息行。
class _BusiVipTile extends StatelessWidget {
  const _BusiVipTile({required this.info});

  final BusiVipInfo info;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(
            info.active ? Icons.verified_rounded : Icons.verified_outlined,
            color: info.active
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.busiType ?? '未知业务',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (info.productType case final product?)
                  Text(
                    '产品：$product',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            info.active ? '已开通' : '未开通',
            style: TextStyle(
              fontSize: 13,
              color: info.active
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// 本月领取记录日历，已领取日期高亮。
class _VipCalendar extends StatelessWidget {
  const _VipCalendar({
    required this.year,
    required this.month,
    required this.claimedDays,
  });

  final int year;
  final int month;
  final Set<int> claimedDays;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final firstWeekday = DateTime(year, month, 1).weekday;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final leading = List<int>.filled(firstWeekday - 1, 0);
    final cells = <int>[
      ...leading,
      ...List.generate(daysInMonth, (i) => i + 1),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$year 年 $month 月',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 7,
            mainAxisSpacing: 4,
            children: [
              for (final label in const ['一', '二', '三', '四', '五', '六', '日'])
                Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final day in cells)
                day == 0
                    ? const SizedBox.shrink()
                    : _CalendarDay(
                        day: day,
                        claimed: claimedDays.contains(day),
                      ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CalendarDay extends StatelessWidget {
  const _CalendarDay({required this.day, required this.claimed});

  final int day;
  final bool claimed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: claimed ? colorScheme.primary : null,
          shape: BoxShape.circle,
        ),
        child: Text(
          '$day',
          style: TextStyle(
            color: claimed ? colorScheme.onPrimary : colorScheme.onSurface,
            fontWeight: claimed ? FontWeight.w800 : FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
