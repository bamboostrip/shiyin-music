import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/toast.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth, required this.api});

  final AuthController auth;
  final MusicApi api;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _mobileController = TextEditingController();
  final _codeController = TextEditingController();
  final _mobileFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _mobilePattern = RegExp(r'^\d{11}$');

  Timer? _codeTimer;
  String? _localError;
  int _codeSeconds = 0;

  var _tabIndex = 0;
  QrCodeInfo? _qrCode;
  String _qrStatusText = '';
  bool _qrLoading = false;
  bool _qrExpired = false;
  Timer? _qrPollTimer;

  @override
  void dispose() {
    _codeTimer?.cancel();
    _qrPollTimer?.cancel();
    _mobileController.dispose();
    _codeController.dispose();
    _mobileFocus.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  Future<void> _showErrorDialog(String message) async {
    if (!mounted || message.trim().isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          icon: Icon(
            Icons.error_outline_rounded,
            color: colorScheme.error,
            size: 38,
          ),
          title: const Text(
            '登录失败',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '登录或服务请求失败，详细错误信息如下：',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.maxFinite,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.error.withValues(alpha: 0.3),
                  ),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    message,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: message));
                Toast.success('已复制错误信息到剪贴板');
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('复制错误信息'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _sendCode() async {
    if (_codeSeconds > 0) return;

    final mobile = _mobileController.text.replaceAll(RegExp(r'\D'), '');
    if (!_mobilePattern.hasMatch(mobile)) {
      setState(() => _localError = '请输入正确的手机号');
      _mobileFocus.requestFocus();
      return;
    }

    setState(() => _localError = null);
    await widget.auth.sendCode(mobile);
    if (!mounted) return;

    if (widget.auth.errorMessage == null || widget.auth.errorMessage!.isEmpty) {
      _startCodeCountdown();
      _codeFocus.requestFocus();
    }
  }

  void _startCodeCountdown() {
    _codeTimer?.cancel();
    setState(() => _codeSeconds = 60);
    _codeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_codeSeconds <= 1) {
        timer.cancel();
        setState(() => _codeSeconds = 0);
        return;
      }

      setState(() => _codeSeconds--);
    });
  }

  Future<void> _login() async {
    final mobile = _mobileController.text.replaceAll(RegExp(r'\D'), '');
    final code = _codeController.text.replaceAll(RegExp(r'\D'), '');
    if (!_mobilePattern.hasMatch(mobile)) {
      setState(() => _localError = '请输入正确的手机号');
      _mobileFocus.requestFocus();
      return;
    }
    if (code.isEmpty) {
      setState(() => _localError = '请输入验证码');
      _codeFocus.requestFocus();
      return;
    }

    setState(() => _localError = null);
    final result = await widget.auth.login(mobile, code);
    if (!mounted) return;

    if (widget.auth.errorMessage != null && widget.auth.errorMessage!.isNotEmpty) {
      return;
    }

    if (result?.requiresUserSelection == true) {
      await _showAccountSelection(result!.accounts, mobile, code, result.message);
    }
  }

  Future<void> _showAccountSelection(
    List<MobileLoginAccount> accounts,
    String mobile,
    String code,
    String? message,
  ) async {
    if (accounts.isEmpty) {
      return;
    }

    final selected = await showModalBottomSheet<MobileLoginAccount>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) =>
          _AccountSelectionSheet(accounts: accounts, message: message),
    );
    if (!mounted || selected == null) {
      return;
    }
    await widget.auth.login(mobile, code, userId: selected.userId);
  }

  Future<void> _loadQrCode() async {
    _qrPollTimer?.cancel();
    setState(() {
      _qrCode = null;
      _qrStatusText = '获取二维码中...';
      _qrLoading = true;
      _qrExpired = false;
    });
    try {
      final qr = await widget.api.getQrCode();
      if (!mounted) return;
      setState(() {
        _qrCode = qr;
        _qrLoading = false;
        _qrStatusText = '请使用酷狗音乐App扫码';
      });
      _startQrPolling(qr.key);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qrLoading = false;
        _qrStatusText = '获取二维码失败，点击重试';
        _qrExpired = true;
      });
      _showErrorDialog('获取二维码失败：$e');
    }
  }

  void _startQrPolling(String key) {
    _qrPollTimer?.cancel();
    _qrPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final result = await widget.api.checkQrStatus(key);
        if (!mounted) return;
        if (result.isSuccess) {
          _qrPollTimer?.cancel();
          final session = LoginSession(
            userId: result.userId ?? '',
            token: result.token ?? '',
            nickname: result.nickname,
            avatarUrl: result.avatar,
          );
          await widget.auth.loginWithSession(session);
          if (!mounted) return;
          if (widget.auth.errorMessage != null && widget.auth.errorMessage!.isNotEmpty) {
            _showErrorDialog(widget.auth.errorMessage!);
          }
          return;
        }
        if (result.isExpired) {
          _qrPollTimer?.cancel();
          setState(() {
            _qrStatusText = '二维码已过期，点击刷新';
            _qrExpired = true;
          });
          return;
        }
        setState(() {
          _qrStatusText = result.isWaitingForConfirm
              ? '扫码成功，请在手机上确认'
              : '请使用酷狗音乐App扫码';
        });
      } catch (_) {
        if (!mounted) return;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [Color(0xFF10233A), Color(0xFF06070A)]
                : const [Color(0xFFDCEEFF), Color(0xFFF7FBFF), Colors.white],
            stops: isDark ? const [0, 1] : const [0, .58, 1],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _LoginBackgroundPainter(
                  primary: colorScheme.primary,
                  secondary: colorScheme.secondary,
                  outline: colorScheme.outlineVariant,
                  isDark: isDark,
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      22,
                      34,
                      22,
                      keyboardInset + 24,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 58,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _LoginHeader(colorScheme: colorScheme),
                              const SizedBox(height: 28),
                              _LoginTabBar(
                                selectedIndex: _tabIndex,
                                onChanged: (i) {
                                  setState(() => _tabIndex = i);
                                  if (i == 1) _loadQrCode();
                                },
                              ),
                              const SizedBox(height: 20),
                              if (_tabIndex == 0)
                                _LoginForm(
                                  auth: widget.auth,
                                  codeController: _codeController,
                                  codeFocus: _codeFocus,
                                  codeSeconds: _codeSeconds,
                                  errorText:
                                      _localError ?? widget.auth.errorMessage,
                                  mobileController: _mobileController,
                                  mobileFocus: _mobileFocus,
                                  onLogin: _login,
                                  onSendCode: _sendCode,
                                )
                              else
                                _QrLoginForm(
                                  qrCode: _qrCode,
                                  isLoading: _qrLoading,
                                  statusText: _qrStatusText,
                                  isExpired: _qrExpired,
                                  onRefresh: _loadQrCode,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoginHeader extends StatelessWidget {
  const _LoginHeader({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppConfig.appName,
          style: textTheme.headlineMedium?.copyWith(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w900,
            height: 1.08,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '请先登录后继续使用',
          style: textTheme.bodyLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _LoginForm extends StatelessWidget {
  const _LoginForm({
    required this.auth,
    required this.codeController,
    required this.codeFocus,
    required this.codeSeconds,
    required this.errorText,
    required this.mobileController,
    required this.mobileFocus,
    required this.onLogin,
    required this.onSendCode,
  });

  final AuthController auth;
  final TextEditingController codeController;
  final FocusNode codeFocus;
  final int codeSeconds;
  final String? errorText;
  final TextEditingController mobileController;
  final FocusNode mobileFocus;
  final VoidCallback onLogin;
  final VoidCallback onSendCode;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isBusy = auth.isLoading;
    final canSendCode = !isBusy && codeSeconds == 0;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .06),
            blurRadius: 24,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '手机号登录',
              style: textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 18),
            _LoginTextField(
              controller: mobileController,
              focusNode: mobileFocus,
              icon: Icons.phone_iphone_rounded,
              hintText: '手机号',
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              enabled: !isBusy,
              maxLength: 11,
              autofillHints: const [AutofillHints.telephoneNumber],
              onSubmitted: (_) => codeFocus.requestFocus(),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _LoginTextField(
                    controller: codeController,
                    focusNode: codeFocus,
                    icon: Icons.password_rounded,
                    hintText: '验证码',
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    enabled: !isBusy,
                    maxLength: 8,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    onSubmitted: (_) => onLogin(),
                  ),
                ),
                const SizedBox(width: 10),
                _CodeButton(
                  enabled: canSendCode,
                  label: codeSeconds > 0 ? '${codeSeconds}s' : '获取验证码',
                  onTap: onSendCode,
                ),
              ],
            ),
            const SizedBox(height: 18),
            _PrimaryLoginButton(isLoading: isBusy, onTap: onLogin),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: errorText == null
                  ? const SizedBox.shrink()
                  : Padding(
                      key: ValueKey(errorText),
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        errorText!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountSelectionSheet extends StatelessWidget {
  const _AccountSelectionSheet({required this.accounts, this.message});

  final List<MobileLoginAccount> accounts;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '选择登录账号',
              style: textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message ?? '该手机号绑定了多个账号，请选择要登录的账号',
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: accounts.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final account = accounts[index];
                  return _AccountOptionTile(account: account);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountOptionTile extends StatelessWidget {
  const _AccountOptionTile({required this.account});

  final MobileLoginAccount account;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.of(context).pop(account),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: colorScheme.primary.withValues(alpha: .12),
                backgroundImage: account.avatarUrl != null
                    ? ResizeImage(NetworkImage(account.avatarUrl!), width: 96, height: 96)
                    : null,
                child: account.avatarUrl == null
                    ? Text(
                        account.displayName.substring(0, 1),
                        style: TextStyle(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w900,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (account.subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        account.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      'UID ${account.userId}',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoginTextField extends StatelessWidget {
  const _LoginTextField({
    required this.controller,
    required this.focusNode,
    required this.icon,
    required this.hintText,
    required this.keyboardType,
    required this.textInputAction,
    required this.enabled,
    required this.maxLength,
    required this.autofillHints,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final IconData icon;
  final String hintText;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final bool enabled;
  final int maxLength;
  final Iterable<String> autofillHints;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: focusNode,
      builder: (context, _) {
        final focused = focusNode.hasFocus;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: focused
                ? colorScheme.primary.withValues(alpha: .08)
                : colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: focused ? colorScheme.primary : colorScheme.outlineVariant,
              width: focused ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: focused
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: enabled ? focusNode.requestFocus : null,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (context, value, _) {
                          if (value.text.isNotEmpty) {
                            return const SizedBox.shrink();
                          }

                          return IgnorePointer(
                            child: Text(
                              hintText,
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          );
                        },
                      ),
                      EditableText(
                        controller: controller,
                        focusNode: focusNode,
                        autofillHints: autofillHints,
                        keyboardType: keyboardType,
                        textInputAction: textInputAction,
                        readOnly: !enabled,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(maxLength),
                        ],
                        cursorColor: colorScheme.primary,
                        backgroundCursorColor: colorScheme.outline,
                        selectionColor: colorScheme.primary.withValues(
                          alpha: .22,
                        ),
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                        onSubmitted: onSubmitted,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CodeButton extends StatelessWidget {
  const _CodeButton({
    required this.enabled,
    required this.label,
    required this.onTap,
  });

  final bool enabled;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 104,
        height: 58,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled
              ? colorScheme.primary.withValues(alpha: .12)
              : colorScheme.surfaceContainerHighest.withValues(alpha: .68),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: enabled
                ? colorScheme.primary.withValues(alpha: .28)
                : colorScheme.outlineVariant,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: enabled ? colorScheme.primary : colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _PrimaryLoginButton extends StatelessWidget {
  const _PrimaryLoginButton({required this.isLoading, required this.onTap});

  final bool isLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: isLoading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isLoading
              ? colorScheme.primary.withValues(alpha: .58)
              : colorScheme.primary,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: colorScheme.primary.withValues(alpha: .24),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: isLoading
            ? SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.onPrimary,
                ),
              )
            : Text(
                '登录',
                style: TextStyle(
                  color: colorScheme.onPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
      ),
    );
  }
}

class _LoginTabBar extends StatelessWidget {
  const _LoginTabBar({required this.selectedIndex, required this.onChanged});

  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: .68),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: selectedIndex == 0
                      ? colorScheme.surface
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Text(
                  '手机号登录',
                  style: TextStyle(
                    color: selectedIndex == 0
                        ? colorScheme.onSurface
                        : colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: selectedIndex == 1
                      ? colorScheme.surface
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Text(
                  '扫码登录',
                  style: TextStyle(
                    color: selectedIndex == 1
                        ? colorScheme.onSurface
                        : colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QrLoginForm extends StatelessWidget {
  const _QrLoginForm({
    required this.qrCode,
    required this.isLoading,
    required this.statusText,
    required this.isExpired,
    required this.onRefresh,
  });

  final QrCodeInfo? qrCode;
  final bool isLoading;
  final String statusText;
  final bool isExpired;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .06),
            blurRadius: 24,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              Padding(
                padding: const EdgeInsets.all(60),
                child: CircularProgressIndicator(
                  color: colorScheme.primary,
                ),
              )
            else if (qrCode != null && qrCode!.imageUrl.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _QrImage(
                  imageUrl: qrCode!.imageUrl,
                  size: 200,
                  fallbackColor: colorScheme.surfaceContainerHighest,
                  iconColor: colorScheme.onSurfaceVariant,
                ),
              )
            else
              Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.qr_code_2_rounded,
                  size: 80,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 24),
            Text(
              statusText,
              style: textTheme.bodyMedium?.copyWith(
                color: isExpired
                    ? colorScheme.error
                    : colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (isExpired) ...[
              const SizedBox(height: 20),
              GestureDetector(
                onTap: onRefresh,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '刷新二维码',
                    style: TextStyle(
                      color: colorScheme.onPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 渲染二维码图片。
///
/// 后端 `/login/qr/key` 返回的 `qrcode_img` 是 `data:image/png;base64,...`
/// 形式的 data URI，[Image.network] 无法直接加载，会触发 "Width is zero"
/// 渲染警告并导致二维码不显示。这里自动识别 data URI 并走 [Image.memory]，
/// 普通 http(s) URL 仍走 [Image.network]。
class _QrImage extends StatefulWidget {
  const _QrImage({
    required this.imageUrl,
    required this.size,
    required this.fallbackColor,
    required this.iconColor,
  });

  final String imageUrl;
  final double size;
  final Color fallbackColor;
  final Color iconColor;

  @override
  State<_QrImage> createState() => _QrImageState();
}

class _QrImageState extends State<_QrImage> {
  /// 已检测过的图片地址，避免重复解码检测。
  String? _detectedUrl;
  bool _inverted = false;

  void _ensureDetected(String url, Uint8List bytes) {
    if (_detectedUrl == url) return;
    _detectedUrl = url;
    _isInvertedQrImage(bytes).then((inverted) {
      if (!mounted || _detectedUrl != url) return;
      setState(() => _inverted = inverted);
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback() => Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.fallbackColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            Icons.qr_code_2_rounded,
            size: 80,
            color: widget.iconColor,
          ),
        );

    // 二维码的"白色"区域在 PNG 里通常是透明的。深色模式下，透明的"白"
    // 区域会透出底层近黑的 surface，使二维码变成黑底黑码，手机无法识别。
    // 因此这里始终垫一层纯白背景，保证高对比度，与主题无关。
    Widget withWhiteBackground(Widget image) => Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: image,
        );

    final uri = Uri.tryParse(widget.imageUrl);
    if (uri == null) return fallback();

    // data:image/png;base64,... -> 解码字节后用 Image.memory 渲染
    final data = uri.data;
    if (data != null) {
      final bytes = data.contentAsBytes();
      if (bytes.isEmpty) return fallback();
      _ensureDetected(widget.imageUrl, bytes);
      Widget image = Image.memory(
        bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        cacheWidth: (widget.size * 2).ceil().clamp(1, 512),
        cacheHeight: (widget.size * 2).ceil().clamp(1, 512),
        errorBuilder: (_, _, _) => fallback(),
      );
      if (_inverted) {
        image = ColorFiltered(colorFilter: _invertQrFilter, child: image);
      }
      return withWhiteBackground(image);
    }

    return withWhiteBackground(
      Image.network(
        widget.imageUrl,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        cacheWidth: (widget.size * 2).ceil().clamp(1, 512),
        cacheHeight: (widget.size * 2).ceil().clamp(1, 512),
        errorBuilder: (_, _, _) => fallback(),
      ),
    );
  }
}

/// RGB 取反、alpha 保持不变，把"黑底白码"转回标准"黑码白底"。
final _invertQrFilter = ColorFilter.matrix(<double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
]);

/// 判断二维码图片是否为"黑底白码"的反色图。
///
/// 实测酷狗 `/v2/qrcode` 返回的 PNG 是不透明的反色图（调色板仅纯黑/纯白
/// 两色，白色模块排在黑色背景上）。浅色模式下黑底在浅色页面上轮廓清晰，
/// 扫描器可以识别反色码；深色模式下黑底与页面近黑 surface 融为一体，只剩
/// 白色模块漂浮在暗背景上，扫描器无法定位。检测方法：解码后采样四角像素
/// 的平均亮度，偏暗即为反色图。透明背景的图四角无有效像素，返回 false。
Future<bool> _isInvertedQrImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final w = image.width;
      final h = image.height;
      if (w < 10 || h < 10) return false;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return false;
      var sum = 0;
      var n = 0;
      for (final (x0, y0) in [(0, 0), (w - 5, 0), (0, h - 5), (w - 5, h - 5)]) {
        for (var y = y0; y < y0 + 5; y++) {
          for (var x = x0; x < x0 + 5; x++) {
            final i = (y * w + x) * 4;
            // 跳过透明像素：四角全透明的图不视为反色，由白底容器兜底
            if (data.getUint8(i + 3) < 128) continue;
            sum +=
                data.getUint8(i) + data.getUint8(i + 1) + data.getUint8(i + 2);
            n += 3;
          }
        }
      }
      if (n == 0) return false;
      return sum / n < 128;
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

class _LoginBackgroundPainter extends CustomPainter {
  const _LoginBackgroundPainter({
    required this.primary,
    required this.secondary,
    required this.outline,
    required this.isDark,
  });

  final Color primary;
  final Color secondary;
  final Color outline;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = outline.withValues(alpha: isDark ? .28 : .58)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;

    for (var i = 0; i < 5; i++) {
      final y = size.height * (.12 + i * .05);
      final path = Path()
        ..moveTo(-20, y)
        ..cubicTo(
          size.width * .24,
          y - 30,
          size.width * .42,
          y + 34,
          size.width * .66,
          y + 2,
        )
        ..cubicTo(
          size.width * .82,
          y - 20,
          size.width * .98,
          y + 18,
          size.width + 30,
          y - 4,
        );
      canvas.drawPath(path, linePaint);
    }

    final accentPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 8;

    final center = Offset(size.width * .84, size.height * .21);
    final radius = math.min(size.width, size.height) * .18;
    accentPaint.color = primary.withValues(alpha: isDark ? .30 : .22);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi * .72,
      math.pi * .64,
      false,
      accentPaint,
    );
    accentPaint.color = secondary.withValues(alpha: isDark ? .22 : .16);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius + 22),
      math.pi * .88,
      math.pi * .46,
      false,
      accentPaint,
    );

    final barPaint = Paint()
      ..color = primary.withValues(alpha: isDark ? .18 : .14)
      ..style = PaintingStyle.fill;
    final baseY = size.height * .78;
    for (var i = 0; i < 18; i++) {
      final x = size.width * .06 + i * 18;
      final h = 18 + (math.sin(i * .8) + 1) * 22;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, baseY - h, 6, h),
        const Radius.circular(999),
      );
      canvas.drawRRect(rect, barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LoginBackgroundPainter oldDelegate) {
    return oldDelegate.primary != primary ||
        oldDelegate.secondary != secondary ||
        oldDelegate.outline != outline ||
        oldDelegate.isDark != isDark;
  }
}
