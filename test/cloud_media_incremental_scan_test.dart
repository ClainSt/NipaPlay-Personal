import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_scanner.dart';
import 'package:nipaplay/services/cloud_media_scraper.dart';
import 'package:nipaplay/services/webdav_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _MutableWebDavService extends WebDAVService {
  _MutableWebDavService() : super.forTesting();

  final Set<String> files = {
    'Show/Episode 01.mkv',
  };

  @override
  Future<List<WebDAVFile>> listDirectoryAll(
    WebDAVConnection connection,
    String path, {
    bool forceRefresh = false,
  }) async {
    if (path == '/library') {
      return [
        WebDAVFile(
          name: 'Show',
          path: '/library/Show',
          isDirectory: true,
        ),
      ];
    }
    if (path == '/library/Show') {
      return [
        for (final relative in files)
          if (relative.startsWith('Show/'))
            WebDAVFile(
              name: relative.substring('Show/'.length),
              path: '/library/$relative',
              isDirectory: false,
              size: 1000 + relative.length,
            ),
      ];
    }
    return const [];
  }

  @override
  Future<Uint8List> readFileBytes(
    WebDAVConnection connection,
    String path,
  ) async =>
      Uint8List(0);
}

class _CapturingScraper extends CloudMediaScraper {
  int scrapeCalls = 0;

  @override
  Future<CloudMediaScrapeResult> scrape({
    required String sourceId,
    required List<CloudMediaAsset> assets,
    String? rootPath,
    void Function(
      int processed,
      int total,
      String workKey,
      int matched,
      int failed,
    )? onProgress,
  }) async {
    scrapeCalls++;
    final workKeys = assets.map((asset) => asset.workKey).toSet();
    for (final workKey in workKeys) {
      await CloudMediaIndexDatabase.instance.upsertUnmatchedWork(
        sourceId: sourceId,
        workKey: workKey,
        title: workKey,
      );
    }
    return CloudMediaScrapeResult(matched: workKeys.length, failed: 0);
  }
}

Map<String, Object?> _asset(
  String sourceId, {
  String path = 'Show/Episode 01.mkv',
  int size = 1010,
  String category = 'episode',
}) =>
    {
      'source_id': sourceId,
      'relative_path': path,
      'work_key': 'Show',
      'name': path.split('/').last,
      'kind': 'video',
      'category': category,
      'size': size,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late PathProviderPlatform previousPaths;
  final database = CloudMediaIndexDatabase.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('cloud_media_incremental_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    await database.database;
  });

  tearDownAll(() async {
    await database.close();
    PathProviderPlatform.instance = previousPaths;
    await temp.delete(recursive: true);
  });

  test('unchanged inventory reuses metadata; only file changes trigger scrape',
      () async {
    final webDav = _MutableWebDavService();
    final scraper = _CapturingScraper();
    final scanner = CloudMediaScanner(
      webDav: webDav,
      scraperFactory: () => scraper,
    );
    final connection = WebDAVConnection(
      id: 'incremental-connection',
      name: 'Cloud',
      url: 'https://example.invalid/dav',
      username: '',
      password: '',
    );

    final first = await scanner.scanAndIndex(
      connection: connection,
      rootPath: '/library',
    );
    expect(first.inventoryChanged, isTrue);
    expect(first.addedFiles, 1);
    expect(scraper.scrapeCalls, 1);
    final firstWork =
        (await database.getWorks(sourceId: first.libraryId!)).single;
    final firstUpdatedAt = firstWork['updated_at'];

    final unchanged = await scanner.scanAndIndex(
      connection: connection,
      rootPath: '/library',
    );
    expect(unchanged.inventoryChanged, isFalse);
    expect(unchanged.reusedWorks, 1);
    expect(scraper.scrapeCalls, 1);
    final unchangedWork =
        (await database.getWorks(sourceId: first.libraryId!)).single;
    expect(unchangedWork['updated_at'], firstUpdatedAt);

    webDav.files.add('Show/Episode 02.mkv');
    final added = await scanner.scanAndIndex(
      connection: connection,
      rootPath: '/library',
    );
    expect(added.inventoryChanged, isTrue);
    expect(added.addedFiles, 1);
    expect(added.removedFiles, 0);
    expect(scraper.scrapeCalls, 2);

    webDav.files.remove('Show/Episode 02.mkv');
    final removed = await scanner.scanAndIndex(
      connection: connection,
      rootPath: '/library',
    );
    expect(removed.inventoryChanged, isTrue);
    expect(removed.addedFiles, 0);
    expect(removed.removedFiles, 1);
    expect(scraper.scrapeCalls, 2,
        reason: 'Removing a file updates the inventory without re-scraping '
            'an otherwise unchanged work.');
  });

  test('equivalent root aliases reuse the existing logical library', () async {
    final oldId = await database.ensureLibraryRoot(
      connectionId: 'alias-connection',
      rootPath: '/OldMount/Show',
    );
    await database.upsertAssets([_asset(oldId)]);

    final resolved = await database.resolveLibraryRootFromScan(
      connectionId: 'alias-connection',
      rootPath: '/NewMount/Show',
      scannedAssets: [_asset('scan')],
    );

    expect(resolved, oldId);
    expect(
      (await database.getLibraryRoot(oldId))?['root_path'],
      '/NewMount/Show',
    );
  });

  test('duplicate stored roots collapse while preserving Dandanplay metadata',
      () async {
    final publicId = await database.ensureLibraryRoot(
      connectionId: 'duplicate-connection',
      rootPath: '/A/Show',
    );
    final dandanplayId = await database.ensureLibraryRoot(
      connectionId: 'duplicate-connection',
      rootPath: '/B/Show',
    );
    await database.upsertAssets([
      _asset(publicId),
      _asset(dandanplayId, category: 'review'),
    ]);
    await database.upsertUnmatchedWork(
      sourceId: publicId,
      workKey: 'Show',
      title: 'Public',
    );
    await database.upsertUnmatchedWork(
      sourceId: dandanplayId,
      workKey: 'Show',
      title: 'Dandanplay',
    );
    final db = await database.database;
    await db.update(
      'cloud_media_work',
      {
        'dandanplay_anime_id': 1234,
        'poster_url': 'https://assets.anixplayer.net/poster.jpg',
        'metadata_status': 'matched',
      },
      where: 'source_id = ? AND work_key = ?',
      whereArgs: [dandanplayId, 'Show'],
    );

    expect(
      await database.deduplicateEquivalentLibraryRoots(
        connectionId: 'duplicate-connection',
      ),
      1,
    );
    final roots = await database.getLibraryRoots(
      connectionId: 'duplicate-connection',
    );
    expect(roots, hasLength(1));
    final work = (await database.getWorks(
      sourceId: roots.single['id'] as String,
    ))
        .single;
    expect(work['dandanplay_anime_id'], 1234);
  });

  test('legacy provider translation credit is hidden and repaired', () async {
    const sourceId = 'summary-repair';
    await database.upsertUnmatchedWork(
      sourceId: sourceId,
      workKey: 'Show',
      title: 'Show',
    );
    final db = await database.database;
    await db.update(
      'cloud_media_work',
      {
        'overview': '简介正文。\n\n(由 弹弹play AI 辅助翻译)',
      },
      where: 'source_id = ? AND work_key = ?',
      whereArgs: [sourceId, 'Show'],
    );

    final displayed = (await database.getWorks(sourceId: sourceId)).single;
    expect(displayed['overview'], '简介正文。');
    expect(
      await database.repairProviderTranslationCredits(sourceId: sourceId),
      1,
    );
    final stored = await db.query(
      'cloud_media_work',
      columns: ['overview'],
      where: 'source_id = ? AND work_key = ?',
      whereArgs: [sourceId, 'Show'],
    );
    expect(stored.single['overview'], '简介正文。');
  });
}
