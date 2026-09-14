import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/player/player_comment_button.dart';

class _FakeCommentApi implements MusicApi {
  _FakeCommentApi({this.count});
  final int? count;
  int calls = 0;

  @override
  Future<MusicCommentResponse> musicComments(
    String mixsongid, {
    int page = 1,
    int pageSize = 30,
  }) async {
    calls++;
    if (count == null) {
      throw Exception('评论服务不可用');
    }
    return MusicCommentResponse(count: count, list: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  _FakePlayerController({this.commentApi});
  final MusicApi? commentApi;

  @override
  Song? currentSong;

  @override
  MusicApi get api => commentApi ?? (throw Exception('api 未注入'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    clearCommentCountCacheForTest();
  });

  group('formatCommentCount', () {
    test('formats correctly across boundaries', () {
      expect(formatCommentCount(0), '0');
      expect(formatCommentCount(-5), '0');
      expect(formatCommentCount(12), '12');
      expect(formatCommentCount(999), '999');
      expect(formatCommentCount(1000), '999+');
      expect(formatCommentCount(9999), '999+');
      expect(formatCommentCount(10000), '1w+');
      expect(formatCommentCount(16500), '1w+');
      expect(formatCommentCount(989999), '98w+');
      expect(formatCommentCount(990000), '99w+');
      expect(formatCommentCount(1500000), '99w+');
    });
  });

  group('PlayerCommentButton', () {
    testWidgets('renders disabled when song is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlayerCommentButton(
              player: null,
              song: null,
            ),
          ),
        ),
      );

      final iconBtn = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconBtn.onPressed, isNull);
      expect(iconBtn.tooltip, '暂无评论');
    });

    testWidgets('renders disabled when song source is not kugou', (tester) async {
      const song = Song(
        id: 'local_1',
        hash: 'hash_local',
        title: 'Local',
        artist: 'Artist',
        source: SongSource.local,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlayerCommentButton(
              player: null,
              song: song,
            ),
          ),
        ),
      );

      final iconBtn = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconBtn.onPressed, isNull);
    });

    testWidgets('fetches comment count and displays badge', (tester) async {
      const song = Song(
        id: 'kg_1',
        hash: 'hash_kg_1',
        albumAudioId: 'mix_123',
        title: 'Kugou Song',
        artist: 'Artist',
        source: SongSource.kugou,
      );
      final api = _FakeCommentApi(count: 88);
      final player = _FakePlayerController(commentApi: api);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerCommentButton(
              player: player,
              song: song,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(api.calls, 1);
      expect(find.text('88'), findsOneWidget);
    });

    testWidgets('triggers onOpenComment when clicked', (tester) async {
      const song = Song(
        id: 'kg_2',
        hash: 'hash_kg_2',
        albumAudioId: 'mix_456',
        title: 'Kugou Song 2',
        artist: 'Artist',
        source: SongSource.kugou,
      );
      final api = _FakeCommentApi(count: 15);
      final player = _FakePlayerController(commentApi: api);

      String? openedId;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerCommentButton(
              player: player,
              song: song,
              onOpenComment: (id) => openedId = id,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.tap(find.byType(IconButton));
      await tester.pump();

      expect(openedId, 'mix_456');
    });
  });
}
