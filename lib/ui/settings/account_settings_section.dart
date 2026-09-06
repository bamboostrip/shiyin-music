import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import 'settings_widgets.dart';

/// 设置页「账号」分节。
///
/// [onClaimVip]/[onLogout] 由页面注入（导航/弹窗逻辑保留在 settings_page）。
class AccountSettingsSection extends StatelessWidget {
  const AccountSettingsSection({
    super.key,
    required this.auth,
    required this.onClaimVip,
    required this.onLogout,
  });

  final AuthController auth;
  final VoidCallback? onClaimVip;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '账号'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.sync_rounded,
              iconColor: const Color(0xFF1E88E5),
              title: '同步个人信息',
              subtitle: '刷新头像、昵称和歌单数据',
              loading: auth.isLoading,
              onTap: auth.isLoading ? null : () => auth.refreshProfile(),
            ),
            SettingsDivider(),
            SettingsSwitchTile(
              icon: Icons.card_giftcard_rounded,
              iconColor: const Color(0xFFFFA000),
              title: '自动领取VIP',
              subtitle: auth.vipClaim.statusText(),
              value: auth.vipClaim.autoEnabled,
              onChanged: auth.vipClaim.setAutoEnabled,
            ),
            SettingsDivider(),
            SettingsTile(
              icon: Icons.redeem_rounded,
              iconColor: const Color(0xFFFF5722),
              title: '立即领取',
              subtitle: auth.vipClaim.lastMessage,
              loading: auth.vipClaim.isClaiming,
              onTap: auth.vipClaim.isClaiming ? null : onClaimVip,
            ),
            SettingsDivider(),
            SettingsTile(
              icon: Icons.logout_rounded,
              iconColor: colorScheme.error,
              title: '退出登录',
              titleColor: colorScheme.error,
              onTap: auth.isLoading ? null : onLogout,
            ),
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
