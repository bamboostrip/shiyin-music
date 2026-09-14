import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../src/rust/api.dart';
import '../src/rust/frb_generated.dart';
// api.dart 只 import 不 re-export IdentifyCandidate,需直接引入声明文件
// (与 local_music_controller.dart 引 LocalSongEntry 同款做法)。
import '../src/rust/services/identify.dart' show IdentifyCandidate;
import 'api_client.dart';
import 'api_client_interface.dart';

/// 后台 isolate 解析用回调：必须是顶层/静态函数才能跨 isolate 发送
/// （jsonDecode 自带 reviver 命名参数，签名不满足 compute 的要求）。
Future<dynamic> _decodeJsonOffThread(String body) => jsonDecode(body);

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
      try {
        return jsonDecode(response.body);
      } catch (e) {
        // 第三方 API 返回 HTML 错误页/非 JSON 时包装成统一异常，
        // 调用方拿到可读错误而非裸 FormatException。
        throw ApiException('响应不是有效 JSON: $e', statusCode: 502);
      }
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

  /// 超过该长度的响应体交给后台 isolate 解析。大响应（电台分类目录等
  /// 可达数百 KB）在主 isolate 上 jsonDecode 会同步卡住 UI 线程数百毫秒，
  /// 刷新期间帧率掉光（顶部均衡器动画冻结直到刷新结束才弹出）。小响应
  /// 仍就地解析，省去 isolate 启动的固定开销。
  static const int _offThreadDecodeThreshold = 32 * 1024;

  /// 大响应在后台 isolate 解析，避免阻塞 UI 线程；解析结果为纯
  /// JSON 值（Map/List/String/num/bool/null），可跨 isolate 传输。
  Future<dynamic> _decodeBody(String body) async {
    if (body.length < _offThreadDecodeThreshold) {
      return jsonDecode(body);
    }
    try {
      return await compute(_decodeJsonOffThread, body);
    } catch (_) {
      // isolate 启动/传输异常时退回主 isolate 解析，保证接口可用性。
      return jsonDecode(body);
    }
  }

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
      final decoded = await _decodeBody(result);
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

  /// 听歌识曲:上传 8000Hz/16bit/单声道 PCM,返回按匹配度降序的候选。
  /// 透传 Rust identifyMusic(Err 会抛异常,由上层处理),不包 try、不加
  /// 超时——指纹上传比对耗时远超普通请求,复用 _requestTimeout(20s)会误杀。
  Future<List<IdentifyCandidate>> identify(Uint8List pcm) =>
      identifyMusic(engine: _engine, pcm: pcm);

  @override
  void close() {}
}
