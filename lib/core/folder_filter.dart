import '../models/music_models.dart';

/// 本地音乐扫描的文件夹过滤工具。
///
/// 用户可将录音等目录加入排除列表，扫描结果中位于这些目录
/// （含子目录）下的歌曲将被过滤掉。所有比较均不区分大小写，
/// 并统一路径分隔符，避免大小写/分隔符差异导致匹配失败。
class FolderFilter {
  const FolderFilter._();

  /// 规范化文件夹路径：统一分隔符、去尾部 `/`、转小写。
  ///
  /// 空字符串或空白输入返回 `null`。
  static String? normalizeFolderPath(String? path) {
    if (path == null) return null;
    var normalized = path.trim().replaceAll('\\', '/');
    while (normalized.endsWith('/') && normalized.length > 1) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.isEmpty || normalized == '/') return null;
    return normalized.toLowerCase();
  }

  /// 取文件所在父文件夹（已规范化）。无法解析时返回 `null`。
  static String? parentFolderOf(String? filePath) {
    if (filePath == null) return null;
    final normalized = filePath.trim().replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    if (index <= 0) return null;
    return normalizeFolderPath(normalized.substring(0, index));
  }

  /// 判断 [filePath] 是否位于 [folder] 目录（含其子目录）下。
  ///
  /// [folder] 会先做规范化；两者比较不区分大小写。
  static bool isPathUnderFolder(String filePath, String folder) {
    final normalizedFolder = normalizeFolderPath(folder);
    if (normalizedFolder == null) return false;
    final parent = parentFolderOf(filePath);
    if (parent == null) return false;
    return parent == normalizedFolder ||
        parent.startsWith('$normalizedFolder/');
  }

  /// 过滤掉位于 [excludedFolders] 目录（含子目录）下的歌曲。
  static List<Song> filterSongs(
    List<Song> songs,
    Iterable<String> excludedFolders,
  ) {
    final normalized = excludedFolders
        .map(normalizeFolderPath)
        .whereType<String>()
        .toSet();
    if (normalized.isEmpty) return List<Song>.of(songs);

    return songs.where((song) {
      final parent = parentFolderOf(song.hash);
      return parent == null ||
          (!normalized.contains(parent) &&
              !normalized.any((folder) => parent.startsWith('$folder/')));
    }).toList();
  }

  /// 统计各父文件夹下的歌曲数量（按数量降序，供排除设置界面展示）。
  static List<({String folder, int count})> folderCounts(List<Song> songs) {
    final counts = <String, int>{};
    for (final song in songs) {
      final parent = parentFolderOf(song.hash);
      if (parent == null) continue;
      counts[parent] = (counts[parent] ?? 0) + 1;
    }
    final result =
        counts.entries
            .map((entry) => (folder: entry.key, count: entry.value))
            .toList()
          ..sort((a, b) {
            final byCount = b.count.compareTo(a.count);
            return byCount != 0 ? byCount : a.folder.compareTo(b.folder);
          });
    return result;
  }
}
