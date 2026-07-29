class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

dynamic unwrapData(dynamic json) {
  if (json is Map<String, dynamic>) {
    final data = json['data'];
    // 仅当 data 是结构化数据（Map/List）时解包；
    // 错误响应中 data 可能是字符串（如 "参数错误"），此时保留完整响应以保留 status/error_code。
    if (data is Map || data is List) {
      return data;
    }
  }
  return json;
}
