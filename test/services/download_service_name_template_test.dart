import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/download_service.dart';

void main() {
  const song = Song(id: 'hash1', title: '晴天', artist: '周杰伦', hash: 'hash1');

  group('fileNameFor 模板', () {
    test('默认与显式 artistTitle = 现状命名', () {
      final service = DownloadService();
      expect(service.fileNameFor(song, AudioQuality.lossless), '周杰伦-晴天.flac');
      expect(
        service.fileNameFor(song, AudioQuality.standard,
            template: DownloadNameTemplate.artistTitle),
        '周杰伦-晴天.mp3',
      );
    });

    test('titleArtist = 歌名在前', () {
      final service = DownloadService();
      expect(
        service.fileNameFor(song, AudioQuality.standard,
            template: DownloadNameTemplate.titleArtist),
        '晴天-周杰伦.mp3',
      );
    });

    test('模板作用于各自清洗后的段', () {
      final service = DownloadService();
      const dirty =
          Song(id: 'h', title: 'Tra?g|edy', artist: 'AC/DC', hash: 'h');
      expect(
        service.fileNameFor(dirty, AudioQuality.standard,
            template: DownloadNameTemplate.titleArtist),
        'Tra_g_edy-AC_DC.mp3',
      );
    });

    test('空段回退 hash 不受模板影响', () {
      final service = DownloadService();
      const noTitle = Song(id: 'h', title: '', artist: '周杰伦', hash: 'ab-1');
      expect(
        service.fileNameFor(noTitle, AudioQuality.standard,
            template: DownloadNameTemplate.titleArtist),
        'ab-1.mp3',
      );
    });
  });

  group('prefs 读取', () {
    test('nameTemplateFromStored：合法/缺失/脏值', () {
      expect(DownloadService.nameTemplateFromStored('title-artist'),
          DownloadNameTemplate.titleArtist);
      expect(DownloadService.nameTemplateFromStored('artist-title'),
          DownloadNameTemplate.artistTitle);
      expect(DownloadService.nameTemplateFromStored(null),
          DownloadNameTemplate.artistTitle);
      expect(DownloadService.nameTemplateFromStored('garbage'),
          DownloadNameTemplate.artistTitle);
    });

    test('storedNameTemplateValue 与 nameTemplateFromStored 互逆', () {
      for (final t in DownloadNameTemplate.values) {
        expect(DownloadService.nameTemplateFromStored(
            DownloadService.storedNameTemplateValue(t)), t);
      }
    });

    test('loadNameTemplate 读 prefs', () async {
      SharedPreferences.setMockInitialValues({
        DownloadService.downloadNameTemplateKey: 'title-artist',
      });
      expect(await DownloadService.loadNameTemplate(),
          DownloadNameTemplate.titleArtist);
      SharedPreferences.setMockInitialValues({});
      expect(await DownloadService.loadNameTemplate(),
          DownloadNameTemplate.artistTitle);
    });
  });

  group('fileNameForTask 按任务类型分流', () {
    test('playCache 恒默认模板（prefs 里设了 title-artist 也不影响）', () async {
      SharedPreferences.setMockInitialValues({
        DownloadService.downloadNameTemplateKey: 'title-artist',
      });
      final service = DownloadService();
      expect(
        await service.fileNameForTask(
            song, AudioQuality.standard, DownloadTaskKind.playCache),
        '周杰伦-晴天.mp3',
      );
    });

    test('download 按设置模板', () async {
      SharedPreferences.setMockInitialValues({
        DownloadService.downloadNameTemplateKey: 'title-artist',
      });
      final service = DownloadService();
      expect(
        await service.fileNameForTask(
            song, AudioQuality.lossless, DownloadTaskKind.download),
        '晴天-周杰伦.flac',
      );
    });
  });
}
