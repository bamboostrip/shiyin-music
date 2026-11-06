part of 'music_api.dart';

/// 登录提示文案。
const _registerHint = '若没有账号请先在酷狗音乐概念版App注册';

/// 登录 / 会话 / 用户资料 / 会员权益。
mixin _MusicApiAuth on _MusicApiBase {
  void setSession(LoginSession? session) {
    if (session == null) {
      _client.token = null;
      _client.t1 = null;
      _client.sessionId = null;
      if (_client case RustApiClient rust) {
        rust.setSession(null, null, null);
      }
      return;
    }
    _client.token = session.token;
    _client.t1 = session.t1;
    final sid = session.sessionId;
    if (sid != null && sid.isNotEmpty) {
      _client.sessionId = sid;
    }
    if (_client case RustApiClient rust) {
      rust.setSession(session.userId, session.token, session.t1);
    }
  }

  Future<void> sendLoginCode(String mobile) async {
    final json = asMap(
      await _client.post('/captcha/sent', query: {'mobile': mobile}),
    );
    if (!_isSuccess(json)) {
      throw ApiException('发送验证码失败，$_registerHint${_failureSuffix(json)}');
    }
  }

  Future<PhoneLoginResult> loginWithPhone({
    required String mobile,
    required String code,
    String? userId,
  }) async {
    final json = asMap(
      await _client.post(
        '/login/cellphone',
        body: {
          'mobile': mobile,
          'code': code,
          if (userId != null && userId.isNotEmpty) 'userId': userId,
        },
      ),
    );
    // 先解析候选账号：多账号选择必须真的拿到账号，否则 PhoneLoginResult 的
    // requiresUserSelection 为 false，调用方会拿 null session 走成功分支。
    final accounts = asList(json['accounts'])
        .whereType<Map>()
        .map((item) => MobileLoginAccount.fromJson(asMap(item)))
        .where((item) => item.userId.isNotEmpty)
        .toList();
    if (_requiresUserSelection(json) && accounts.isNotEmpty) {
      return PhoneLoginResult.accountSelection(
        accounts: accounts,
        message:
            asString(json['message']) ?? asString(json['msg']) ?? '请选择需要登录的账号',
        errorCode: asInt(json['errorCode'] ?? json['error_code']),
      );
    }
    if (!_isSuccess(json)) {
      // 34175 但没有可用账号：真实原因是账号列表缺失/不可用，
      // 不能再提示「没有账号请先注册」，否则会误导用户去注册。
      if (asInt(json['errorCode'] ?? json['error_code']) == 34175) {
        throw ApiException('该手机号绑定了多个账号，但未能获取账号列表，请稍后重试');
      }
      throw ApiException('登录失败，$_registerHint${_failureSuffix(json)}');
    }
    final session = LoginSession.fromJson(json);
    return PhoneLoginResult.success(
      LoginSession(
        userId: session.userId,
        token: session.token,
        t1: session.t1,
        sessionId: _client.sessionId,
      ),
    );
  }

  Future<LoginSession> refreshToken() async {
    final json = asMap(await _client.post('/login/token'));
    final session = LoginSession.fromJson(json);
    return LoginSession(
      userId: session.userId,
      token: session.token,
      t1: session.t1,
      sessionId: _client.sessionId,
    );
  }

  Future<void> logout() async {
    await _client.post('/login/logout');
  }

  Future<QrCodeInfo> getQrCode() async {
    final json = asMap(await _client.get('/login/qr/key'));
    return QrCodeInfo.fromJson(json);
  }

  Future<QrCheckResult> checkQrStatus(String key) async {
    final json = asMap(await _client.get('/login/qr/check', {'key': key}));
    return QrCheckResult.fromJson(json);
  }

  Future<UserProfile> userDetail() async {
    final json = asMap(await _client.get('/user/detail'));
    return UserProfile.fromJson(json);
  }

  Future<VipReceiveHistory> vipReceiveHistory() async {
    final json = asMap(await _client.get('/youth/month/vip/record'));
    return VipReceiveHistory.fromJson(json);
  }

  Future<UserVipInfo> userVipDetail() async {
    final json = asMap(await _client.get('/user/vip/detail'));
    return UserVipInfo.fromJson(json);
  }

  Future<OneDayVipResult> dailyVip() async {
    final json = asMap(await _client.get('/youth/day/vip'));
    return OneDayVipResult.fromJson(json);
  }

  Future<UpgradeVipResult> upgradeVipReward() async {
    final json = asMap(await _client.get('/youth/day/vip/upgrade'));
    return UpgradeVipResult.fromJson(json);
  }

  Future<void> addListeningTime() async {
    await _client.post('/listen/timeadd');
  }

  bool _isSuccess(Map<String, dynamic> json) {
    return asInt(json['status']) == 1;
  }

  bool _requiresUserSelection(Map<String, dynamic> json) {
    final requiresUserSelection = json['requiresUserSelection'];
    if (requiresUserSelection is bool) {
      return requiresUserSelection;
    }
    final errorCode = asInt(json['errorCode'] ?? json['error_code']);
    final accounts = asList(json['accounts']);
    return errorCode == 34175 && accounts.isNotEmpty;
  }

  String _failureSuffix(Map<String, dynamic> json) {
    final message =
        asString(json['msg']) ??
        asString(json['message']) ??
        asString(json['errmsg']) ??
        asString(json['error']) ??
        asString(json['error_msg']);
    if (message != null) {
      return '：$message';
    }

    final errorCode =
        asString(json['error_code']) ??
        asString(json['errcode']) ??
        asString(json['code']);
    if (errorCode != null) {
      return '（错误码：$errorCode）';
    }

    return '';
  }
}
