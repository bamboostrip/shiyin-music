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

String lyricDisplayModeLabel(LyricDisplayMode mode) {
  return switch (mode) {
    LyricDisplayMode.lyricsWithTranslation => '歌词 + 翻译',
    LyricDisplayMode.lyricsWithRomanization => '歌词 + 音译',
    LyricDisplayMode.lyricsOnly => '仅歌词',
  };
}
