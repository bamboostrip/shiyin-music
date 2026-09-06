import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../src/rust/api.dart';
import '../src/rust/frb_generated.dart';
import 'api_client.dart';
import 'api_client_interface.dart';

class RustApiClient implements ApiClientInterface {
  RustApiClient._(this._engine);

  static RustApiClient? _instance;
  final Engine _engine;

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  static Future<RustApiClient> getInstance() async {
    if (_instance != null) return _instance!;
    await RustLib.init();
    final dir = await getApplicationSupportDirectory();
    final engine = await createEngine(dataDir: dir.path);
    _instance = RustApiClient._(engine);
    return _instance!;
  }

  @override
  Future<dynamic> get(String path, [Map<String, Object?> query = const {}]) {
    return _request('GET', path, query, null);
  }

  @override
  Future<dynamic> getRaw(Uri uri) async {
    final client = http.Client();
    try {
      final response = await client
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(response.body, statusCode: response.statusCode);
      }
      if (response.body.trim().isEmpty) return null;
      return jsonDecode(response.body);
    } finally {
      client.close();
    }
  }

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) {
    return _request('POST', path, query, body);
  }

  /// 播放主链路统一超时：Rust 引擎弱网下可能不返回，不加超时 playSong
  /// 会无限挂起，智能降级/重试拿不到错误。与 getRaw(15s) 对齐，取 20s
  /// 给长尾留余量；超时转为 408 ApiException 进正常错误处理链。
  static const Duration _requestTimeout = Duration(seconds: 20);

  Future<dynamic> _request(
    String method,
    String path,
    Map<String, Object?> query,
    Map<String, Object?>? body,
  ) async {
    final queryJson = jsonEncode(
      query.map((k, v) => MapEntry(k, v?.toString() ?? '')),
    );
    final bodyJson = body != null ? jsonEncode(body) : null;

    try {
      final result = await engineRequest(
        engine: _engine,
        method: method,
        path: path,
        query: queryJson,
        body: bodyJson,
      ).timeout(_requestTimeout);
      if (result.isEmpty || result == 'null') return null;
      final decoded = jsonDecode(result);
      return unwrapData(decoded);
    } on TimeoutException {
      throw ApiException('请求超时，请检查网络后重试', statusCode: 408);
    } catch (e) {
      throw ApiException(e.toString(), statusCode: 500);
    }
  }

  void setSession(String? userid, String? token, String? t1) {
    this.token = token;
    this.t1 = t1;
    engineSetSession(
      engine: _engine,
      userid: userid ?? '',
      token: token ?? '',
      t1: t1 ?? '',
    );
  }

  @override
  void close() {}
}
