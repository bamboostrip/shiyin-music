String? asString(Object? value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? asInt(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString());
}

List<dynamic> asList(Object? value) {
  if (value is List) {
    return value;
  }
  return const [];
}

Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}

Duration? durationFromSeconds(Object? value) {
  final seconds = asInt(value);
  return seconds == null ? null : Duration(seconds: seconds);
}

Duration? durationFromMilliseconds(Object? value) {
  final milliseconds = asInt(value);
  return milliseconds == null ? null : Duration(milliseconds: milliseconds);
}

String? normalizeImageUrl(String? url, {int size = 480}) {
  if (url == null) {
    return null;
  }
  return url
      .replaceAll('{size}', '$size')
      .replaceAll('{SIZE}', '$size')
      .replaceAll('/{size}/', '/$size/')
      .replaceAll('/{SIZE}/', '/$size/');
}

String formatDuration(Duration? duration) {
  if (duration == null) {
    return '--:--';
  }
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
