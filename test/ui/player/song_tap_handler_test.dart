import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/player/song_tap_handler.dart';

Song _song({required String id, required String hash}) => Song(
  id: id,
  hash: hash,
  title: 't',
  artist: 'a',
);

void main() {
  group('isSameSong', () {
    test('hash 相同时判同首', () {
      expect(
        isSameSong(
          _song(id: '1', hash: 'h1'),
          _song(id: '2', hash: 'h1'),
        ),
        isTrue,
      );
    });

    test('hash 不同判不同首', () {
      expect(
        isSameSong(
          _song(id: '1', hash: 'h1'),
          _song(id: '1', hash: 'h2'),
        ),
        isFalse,
      );
    });

    test('hash 为空时退化用 id 比较', () {
      expect(isSameSong(_song(id: '1', hash: ''), _song(id: '1', hash: '')), isTrue);
      expect(
        isSameSong(_song(id: '1', hash: ''), _song(id: '2', hash: '')),
        isFalse,
      );
    });

    test('current 为空判不同', () {
      expect(isSameSong(null, _song(id: '1', hash: 'h1')), isFalse);
    });
  });
}
