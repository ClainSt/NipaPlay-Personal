import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_scanner.dart';
import 'package:nipaplay/services/webdav_service.dart';

class _FakeWebDavService extends WebDAVService {
  _FakeWebDavService() : super.forTesting();

  final List<String> listedPaths = [];

  @override
  Future<List<WebDAVFile>> listDirectoryAll(
    WebDAVConnection connection,
    String path, {
    bool forceRefresh = false,
  }) async {
    listedPaths.add(path);
    if (path == '/library') {
      return [
        WebDAVFile(
          name: '{tmdbid=100565}',
          path: '/library/{tmdbid=100565}',
          isDirectory: true,
        ),
      ];
    }
    return [
      WebDAVFile(
        name: '[VCB-Studio] Anime Title [01].mkv',
        path: '$path/[VCB-Studio] Anime Title [01].mkv',
        isDirectory: false,
        size: 1024,
      ),
    ];
  }
}

void main() {
  group('CloudMediaScanner filename metadata', () {
    test('recursive scan only enumerates WebDAV directories', () async {
      final webDav = _FakeWebDavService();
      final scanner = CloudMediaScanner(webDav: webDav);
      final result = await scanner.scan(
        connection: WebDAVConnection(
          name: 'test',
          url: 'https://example.invalid/dav',
          username: '',
          password: '',
        ),
        rootPath: '/library',
      );

      expect(webDav.listedPaths, ['/library', '/library/{tmdbid=100565}']);
      expect(result.assets, hasLength(1));
      expect(result.assets.single.tmdbId, 100565);
      expect(result.assets.single.episodeNumber, 1);
      expect(result.assets.single.relativePath,
          '{tmdbid=100565}/[VCB-Studio] Anime Title [01].mkv');
    });

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
