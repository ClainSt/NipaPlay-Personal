import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_scanner.dart';

void main() {
  group('CloudMediaScanner filename metadata', () {
    test('recognizes supported TMDB folder markers', () {
      const samples = <String>[
        '{tmdb-100565}',
        '{tmdbid=100565}',
        '[tmdb-100565]',
        '{tmdbid-100565}',
        '{[tmdbid=100565;type=tv]}',
      ];
      for (final sample in samples) {
        expect(CloudMediaScanner.parseTmdbId(sample), 100565, reason: sample);
      }
    });

    test('extracts common episode numbering without renaming', () {
      expect(
        CloudMediaScanner.episodeNumberFromName(
          '[VCB-Studio] Anime Title [01][Ma10p_1080p][x265_flac].mkv',
        ),
        1,
      );
      expect(CloudMediaScanner.episodeNumberFromName('Anime S01E23.mkv'), 23);
      expect(CloudMediaScanner.episodeNumberFromName('Anime EP02.mkv'), 2);
      expect(CloudMediaScanner.episodeNumberFromName('Anime 第03话.mkv'), 3);
    });

    test('special directory classification wins over episode numbering', () {
      expect(
        CloudMediaScanner.classifyAsset('/Show/SPs', 'SP [01].mkv', 'video'),
        'extra',
      );
      expect(
        CloudMediaScanner.classifyAsset(
            '/Show/Season 1', 'Show [01].mkv', 'video'),
        'episode',
      );
      expect(
        CloudMediaScanner.classifyAsset('/Show/Scans', 'cover.jpg', 'image'),
        'scan',
      );
      expect(
        CloudMediaScanner.classifyAsset('/Show/CDs', 'track.flac', 'audio'),
        'cd',
      );
    });
  });
}
