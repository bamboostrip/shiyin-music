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
    if (_requiresUserSelection(json)) {
      final accounts = asList(json['accounts'])
          .whereType<Map>()
          .map((item) => MobileLoginAccount.fromJson(asMap(item)))
          .where((item) => item.userId.isNotEmpty)
          .toList();
      return PhoneLoginResult.accountSelection(
        accounts: accounts,
        message:
            asString(json['message']) ?? asString(json['msg']) ?? '请选择需要登录的账号',
        errorCode: asInt(json['errorCode'] ?? json['error_code']),
      );
    }
    if (!_isSuccess(json)) {
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

  /// 拉取酷狗账号云端播放历史（「云端播放记录」数据源，只读）。
  ///
  /// 注意：/playhistory 只是「最近播放」服务（官方 App 的播放不入库，
  /// 2026-10 真机翻页验证），并非概念版「听歌时光机」排行的数据源——
  /// 排行接口未公开。
  ///
  /// 引擎对成功响应会把 data 提升为根并注入 status:1/error_code:0；失败时
  /// 原样返回原始信封——其 status 仍可能是 1/200 而 error_code 非零（引擎
  /// is_success_pair 的失败分支不改动 root）。所以这里与引擎同口径地同时
  /// 校验 status 与 error_code，失败转成 ApiException 交给调用方展示，
  /// 而不是被容错解析误读成「云端无记录」。
  /// 响应的具体承载形状由 [CloudPlayHistory.fromJson] 容错处理。
  Future<CloudPlayHistory> cloudPlayHistory() async {
    // 「云端播放记录」即本接口（bp 游标翻页，has_more=1 时把响应的
    // bp 回传拉下一页，直到游标耗尽/终止防护触发）。
    final records = <CloudPlayRecord>[];
    final seenRecordKeys = <String>{};
    final seenBps = <String?>{};
    String? bp;
    Object? firstRaw;
    for (var page = 0; page < _kMaxCloudHistoryPages; page++) {
      final raw = await _client.get(
        '/user/playhistory',
        bp == null ? const {} : {'bp': bp},
      );
      final json = asMap(raw);
      if (_isFailureEnvelope(json)) {
        throw ApiException('拉取云端播放历史失败${_failureSuffix(json)}');
      }
      firstRaw ??= raw;
      // 验收期临时：落盘每页原文（截断），确认跨页形状/排序后移除。
      final encoded = jsonEncode(raw);
      debugPrint(
        '[时音][cloud-history][probe] 第${page + 1}页 '
        'has_more=${json['has_more']} bp=${json['bp']} 原文[0:1500]='
        '${encoded.substring(0, encoded.length < 1500 ? encoded.length : 1500)}',
      );
      // 游标异常（回环/原地重复）时后页可能重复返回同一批记录，按键去重。
      var pageRecordCount = 0;
      for (final record in CloudPlayHistory.fromJson(raw).records) {
        if (seenRecordKeys.add(
          '${record.song.hash}|${record.playedAt?.millisecondsSinceEpoch}',
        )) {
          records.add(record);
          pageRecordCount++;
        }
      }
      // 终止三防护（与 Mineradio 生产实现同款）：无更多页 / 游标缺失或
      // 已见过（全集防环）/ 本页零记录仍称 has_more（服务端异常）。
      if (asInt(json['has_more']) != 1) break;
      final nextBp = asString(json['bp']);
      if (nextBp == null || nextBp.isEmpty || !seenBps.add(nextBp)) break;
      if (pageRecordCount == 0) break;
      bp = nextBp;
    }
    if (records.isNotEmpty) {
      debugPrint('[时音][cloud-history] 拉到 ${records.length} 条云端记录');
    } else {
      // 真机验收诊断：解析为空时自动探测候选数据源并落盘日志，确认
      // 概念版「时光机」的真实数据源与响应形状后移除（见 _diagnoseEmptyPull）。
      unawaited(_diagnoseEmptyPull(firstRaw));
    }
    return CloudPlayHistory(records: records);
  }

  /// 翻页上限：防止游标异常时的无限请求；10 页足够覆盖当前验收体量。
  static const _kMaxCloudHistoryPages = 10;

  /// 空结果自动诊断（验收期临时代码，形状确认后移除）：
  ///
  /// 概念版「时光机」展示的是听歌排形态的聚合数据，与 /playhistory 的
  /// 逐条播放记录可能是两个数据服务。主源解析为空时，把主源原始形状与
  /// listenservice（/v2/get_list，听歌排行最可疑的候选源，list_type 语义
  /// 未知，探测 0/1 两档）的原始响应一并写入 AppLog 落盘日志，一次真机
  /// 打开即可定位真实数据源。仅诊断日志，不影响返回值与 UI。
  Future<void> _diagnoseEmptyPull(Object? mainRaw) async {
    debugPrint(
      '[时音][cloud-history][probe] 主源 /user/playhistory 解析为空，'
      '响应形状: ${_diagnosticDump(mainRaw)}',
    );
    for (final listType in const [0, 1]) {
      try {
        final rank = asMap(
          await _client.get('/user/listenrank', {'list_type': listType}),
        );
        debugPrint(
          '[时音][cloud-history][probe] listenservice list_type=$listType '
          '响应形状: ${_diagnosticDump(rank)}',
        );
      } catch (error) {
        debugPrint(
          '[时音][cloud-history][probe] listenservice list_type=$listType '
          '拉取失败: $error',
        );
      }
    }
  }

  /// 诊断用原始响应概要：根类型 + 顶层键与各键形状 + 截断的 JSON 原文。
  static String _diagnosticDump(Object? raw) {
    final buffer = StringBuffer();
    if (raw is List) {
      buffer.write('根为数组(${raw.length} 项)');
    } else if (raw is Map) {
      buffer.write('根为对象，键: ${raw.keys.toList()}');
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is List) {
          buffer.write(' | ${entry.key}: 数组(${value.length})');
        } else if (value is Map) {
          buffer.write(
            ' | ${entry.key}: 对象(键: ${value.keys.take(20).toList()})',
          );
        }
      }
    } else {
      buffer.write('根为 ${raw.runtimeType}');
    }
    final encoded = jsonEncode(raw);
    buffer.write(
      encoded.length > 500 ? ' | 原文[0:500]=${encoded.substring(0, 500)}' : ' | 原文=$encoded',
    );
    return buffer.toString();
  }

  /// 上报一条播放记录到酷狗云端（「云端播放记录」二期，写操作）。
  ///
  /// 由设置开关「同步播放记录」控制，PlayerController 在起播成功后调用；
  /// 失败向上抛、由调用方吞错，不影响播放主链路。与 addListeningTime
  /// 同款最简 POST；不做信封校验（无 UI 反馈，静默语义），但上游回执
  /// 非成功时 debugPrint 一行错误码，供灰度验收排查（静默吞掉会无从定位）。
  Future<void> uploadPlayHistory({
    required String mixSongId,
    int playCount = 1,
  }) async {
    final raw = await _client.post(
      '/playhistory/upload',
      query: {'mixsongid': mixSongId, 'play_count': playCount},
    );
    final json = asMap(raw);
    if (_isFailureEnvelope(json)) {
      debugPrint(
        '[时音][cloud-history] upload rejected: '
        'status=${json['status']} '
        'error_code=${json['error_code'] ?? json['errcode']}'
        '${_failureSuffix(json)}',
      );
    }
  }

  /// 引擎失败信封判定，与 rust `is_success_pair` 同口径：status 非 1/200，
  /// 或 error_code/errcode 存在且非零，都算失败。失败信封由引擎原样透传，
  /// 其 status 仍可能保持 1/200，所以不能只看 status（成功路径引擎必注入
  /// error_code:0，不会误伤）。
  bool _isFailureEnvelope(Map<String, dynamic> json) {
    final status = asInt(json['status']);
    final errorCode = asInt(json['error_code'] ?? json['errcode']);
    return json.isNotEmpty &&
        status != null &&
        (status != 1 && status != 200 || (errorCode != null && errorCode != 0));
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
