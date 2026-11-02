import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_scanner.dart';
import 'package:nipaplay/services/webdav_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FailingWebDavService extends WebDAVService {
  _FailingWebDavService() : super.forTesting();

  @override
  Future<List<WebDAVFile>> listDirectoryAll(
    WebDAVConnection connection,
    String path, {
    bool forceRefresh = false,
  }) async {
    if (path == '/Anime') {
      return [
        WebDAVFile(
          name: 'Season 1',
          path: '/Anime/Season 1',
          isDirectory: true,
        ),
        WebDAVFile(
          name: 'Special.mkv',
          path: '/Anime/Special.mkv',
          isDirectory: false,
          size: 128,
        ),
      ];
    }
    throw const SocketException('simulated WebDAV subdirectory failure');
  }
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('failed recursive listing leaves the existing media index untouched',
      () async {
    final temp = await Directory.systemTemp.createTemp('cloud_scan_failure_');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    final database = CloudMediaIndexDatabase.instance;
    addTearDown(() async {
      await database.close();
      PathProviderPlatform.instance = previousPaths;
      await temp.delete(recursive: true);
    });

    final connection = WebDAVConnection(
      name: 'simulated-server',
      url: 'https://example.invalid/dav',
      username: '',
      password: '',
    );
    final sourceId = await database.ensureLibraryRoot(
      connectionId: connection.id,
      rootPath: '/Anime',
    );
    await database.upsertAssets([
      {
        'source_id': sourceId,
        'relative_path': 'Season 1/Episode 01.mkv',
        'name': 'Episode 01.mkv',
        'kind': 'video',
        'category': 'episode',
        'work_key': 'Anime',
      },
      {
        'source_id': sourceId,
        'relative_path': 'Season 1/Episode 02.mkv',
        'name': 'Episode 02.mkv',
        'kind': 'video',
        'category': 'episode',
        'work_key': 'Anime',
      },
    ]);

    final scanner = CloudMediaScanner(webDav: _FailingWebDavService());
    await expectLater(
      scanner.scanAndIndex(connection: connection, rootPath: '/Anime'),
      throwsA(isA<SocketException>()),
    );

    final assets = await database.getAssets(sourceId: sourceId);
    expect(assets.map((asset) => asset['relative_path']).toSet(), {
      'Season 1/Episode 01.mkv',
      'Season 1/Episode 02.mkv',
    });
  });
}
