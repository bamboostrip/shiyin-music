import '../../models/music_models.dart';

enum LyricDisplayMode {
  lyricsWithTranslation,
  lyricsOnly,
  lyricsWithRomanization,
}

List<LyricDisplayMode> availableLyricDisplayModes(List<LyricLine> lyrics) {
  if (lyrics.isEmpty) {
    return const [];
  }

  final modes = <LyricDisplayMode>[];
  final hasTranslation = lyrics.any(
    (line) => line.translation != null && line.translation!.isNotEmpty,
  );
  final hasRomanization = lyrics.any(
    (line) => line.romanization != null && line.romanization!.isNotEmpty,
  );

  if (hasTranslation) {
    modes.add(LyricDisplayMode.lyricsWithTranslation);
  }
  modes.add(LyricDisplayMode.lyricsOnly);
  if (hasRomanization) {
    modes.add(LyricDisplayMode.lyricsWithRomanization);
  }
  return modes;
}

/// 由译/音开关换算歌词显示模式。
///
/// 优先级与移动端歌词页一致：翻译开启时优先显示翻译，
/// 否则开了音译显示音译，都没开则仅歌词。
LyricDisplayMode lyricDisplayModeOf({
  required bool showTranslation,
  required bool showRomanization,
}) {
  if (showTranslation) return LyricDisplayMode.lyricsWithTranslation;
  if (showRomanization) return LyricDisplayMode.lyricsWithRomanization;
  return LyricDisplayMode.lyricsOnly;
}

String lyricDisplayModeLabel(LyricDisplayMode mode) {
  return switch (mode) {
    LyricDisplayMode.lyricsWithTranslation => '歌词 + 翻译',
    LyricDisplayMode.lyricsWithRomanization => '歌词 + 音译',
    LyricDisplayMode.lyricsOnly => '仅歌词',
  };
}
