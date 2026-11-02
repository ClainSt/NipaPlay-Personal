import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_scanner.dart';
import 'package:nipaplay/services/webdav_service.dart';

class _FakeWebDavService extends WebDAVService {
  _FakeWebDavService() : super.forTesting();

  final List<String> listedPaths = [];
  final List<String> requestedFileBytes = [];

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

  @override
  Future<Uint8List> readFileBytes(
    WebDAVConnection connection,
    String path,
  ) async {
    requestedFileBytes.add(path);
    return Uint8List(0);
  }
}

class _SeriesRootWebDavService extends WebDAVService {
  _SeriesRootWebDavService() : super.forTesting();

  @override
  Future<List<WebDAVFile>> listDirectoryAll(
    WebDAVConnection connection,
    String path, {
    bool forceRefresh = false,
  }) async {
    if (path == '/Series') {
      return [
        WebDAVFile(
          name: 'Season 1',
          path: '/Series/Season 1',
          isDirectory: true,
        ),
      ];
    }
    return [
      WebDAVFile(
        name: 'Show S01E01.mkv',
        path: '$path/Show S01E01.mkv',
        isDirectory: false,
        size: 500,
      ),
    ];
  }
}

String _propfindResource(
  String href, {
  bool isDirectory = false,
  int size = 0,
  String contentType = '',
}) =>
    '''
    <d:response>
      <d:href>$href</d:href>
      <d:propstat>
        <d:prop>
          <d:displayname/>
          <d:resourcetype>${isDirectory ? '<d:collection/>' : ''}</d:resourcetype>
          <d:getcontentlength>$size</d:getcontentlength>
          <d:getcontenttype>$contentType</d:getcontenttype>
          <d:getetag>"sample-etag"</d:getetag>
          <d:getlastmodified>Sun, 01 Nov 2026 00:00:00 GMT</d:getlastmodified>
        </d:prop>
        <d:status>HTTP/1.1 200 OK</d:status>
      </d:propstat>
    </d:response>
  ''';

String _propfindDocument(List<String> resources) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">${resources.join()}</d:multistatus>';

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
      expect(result.assets.single.tmdbType, CloudTmdbType.unknown);
      expect(result.assets.single.episodeNumber, 1);
      expect(result.assets.single.relativePath,
          '{tmdbid=100565}/[VCB-Studio] Anime Title [01].mkv');
      expect(webDav.requestedFileBytes, isEmpty,
          reason: 'catalog scans must not GET video content');
    });

    test('HTTP scan sends PROPFIND metadata requests and no video GET',
        () async {
      final requests = <({String method, String path, String? range})>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        requests.add((
          method: request.method,
          path: Uri.decodeComponent(request.uri.path),
          range: request.headers.value(HttpHeaders.rangeHeader),
        ));
        if (request.method != 'PROPFIND') {
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.response.close();
          return;
        }

        final path = Uri.decodeComponent(request.uri.path);
        final resources = path.endsWith('/library/')
            ? [
                _propfindResource('/dav/library/', isDirectory: true),
                _propfindResource(
                  '/dav/library/{tmdbid=100565}/',
                  isDirectory: true,
                ),
              ]
            : [
                _propfindResource(
                  '/dav/library/{tmdbid=100565}/',
                  isDirectory: true,
                ),
                _propfindResource(
                  '/dav/library/{tmdbid=100565}/[VCB-Studio] Anime Title [01].mkv',
                  size: 2048,
                  contentType: 'video/x-matroska',
                ),
              ];
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write(_propfindDocument(resources));
        await request.response.close();
      });
      addTearDown(() async {
        await serverSubscription.cancel();
        await server.close(force: true);
      });

      final scanner = CloudMediaScanner(webDav: WebDAVService.forTesting());
      final result = await scanner.scan(
        connection: WebDAVConnection(
          name: 'local-test-server',
          url: 'http://${server.address.address}:${server.port}/dav',
          username: '',
          password: '',
        ),
        rootPath: '/library',
      );

      expect(result.assets, hasLength(1));
      expect(result.assets.single.tmdbId, 100565);
      expect(result.assets.single.episodeNumber, 1);
      expect(requests, hasLength(2));
      expect(requests.every((request) => request.method == 'PROPFIND'), isTrue);
      expect(requests.every((request) => request.range == null), isTrue);
      expect(requests.any((request) => request.path.endsWith('.mkv')), isFalse);
    });

    test('a selected series root keeps seasons under one work key', () async {
      final scanner = CloudMediaScanner(webDav: _SeriesRootWebDavService());
      final result = await scanner.scan(
        connection: WebDAVConnection(
          name: 'test',
          url: 'https://example.invalid/dav',
          username: '',
          password: '',
        ),
        rootPath: '/Series',
      );

      expect(result.assets, hasLength(1));
      expect(result.assets.single.workKey, '.');
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
      expect(
        CloudMediaScanner.parseTmdbType('{[tmdbid=100565;type=tv]}'),
        CloudTmdbType.tv,
      );
      expect(
        CloudMediaScanner.parseTmdbType('{[tmdbid=100565;type=movie]}'),
        CloudTmdbType.movie,
      );
      expect(
        CloudMediaScanner.parseTmdbId('{tmdbtv-101}'),
        101,
      );
      expect(
        CloudMediaScanner.parseTmdbType('{tmdbmovie=202}'),
        CloudTmdbType.movie,
      );
      expect(
        CloudMediaScanner.parseTmdbType('{tmdbid=100565}'),
        CloudTmdbType.unknown,
      );
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
          '/Show/Season 1',
          'NCOPED.mkv',
          'video',
        ),
        'extra',
      );
      expect(
        CloudMediaScanner.classifyAsset(
            '/Show/Season 1', 'Show [01].mkv', 'video'),
        'episode',
      );
      for (final marker in [
        'NCOP',
        'NCED',
        'PV',
        'CM',
        'OVA',
        'OAD',
        'SP',
        'MV',
        'Visual Commentary',
      ]) {
        expect(
          CloudMediaScanner.classifyAsset(
            '/Show/Season 1',
            '$marker [01].mkv',
            'video',
          ),
          'extra',
          reason: '$marker markers take priority over bracket episode numbers',
        );
      }
      for (final directory in ['SP', 'SPs', 'Specials', 'Extras']) {
        expect(
          CloudMediaScanner.classifyAsset(
            '/Show/$directory',
            'Clip [01].mkv',
            'video',
          ),
          'extra',
          reason: '$directory directory classification takes priority',
        );
      }
      expect(
        CloudMediaScanner.classifyAsset('/Show/Scans', 'cover.jpg', 'image'),
        'scan',
      );
      expect(
        CloudMediaScanner.classifyAsset('/Show/CDs', 'track.flac', 'audio'),
        'cd',
      );
      expect(
        CloudMediaScanner.classifyAsset('/Show/CDs', 'album.cue', 'cue'),
        'cd',
      );
    });
  });
}
