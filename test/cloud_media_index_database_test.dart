import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_models.dart';
import 'package:nipaplay/services/cloud_media_scraper.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('selected WebDAV roots have stable and independent library IDs',
      () async {
    final temp = await Directory.systemTemp.createTemp('cloud_library_roots_');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    final database = CloudMediaIndexDatabase.instance;
    final db = await database.database;
    addTearDown(() async {
      await db.close();
      PathProviderPlatform.instance = previousPaths;
      await temp.delete(recursive: true);
    });

    final first = await database.ensureLibraryRoot(
      connectionId: 'device-connection-a',
      rootPath: '/Anime/TV/',
    );
    final firstAgain = await database.ensureLibraryRoot(
      connectionId: 'device-connection-a',
      rootPath: r'\Anime\TV',
    );
    final second = await database.ensureLibraryRoot(
      connectionId: 'device-connection-a',
      rootPath: '/Anime/Movies',
    );

    expect(firstAgain, first);
    expect(second, isNot(first));
    expect(
      await database.getLibraryRootId(
        connectionId: 'device-connection-a',
        rootPath: '/Anime/TV',
      ),
      first,
    );
    expect(
        (await database.getLibraryRoots(connectionId: 'device-connection-a')),
        hasLength(2));

    final scrapeResult = await CloudMediaScraper().scrape(
      sourceId: second,
      rootPath: '/Anime/Series Root',
      assets: const [
        CloudMediaAsset(
          sourceId: 'unused',
          relativePath: 'Season 1/episode.mkv',
          workKey: '.',
          name: 'episode.mkv',
          kind: 'video',
          category: 'episode',
        ),
      ],
    );
    expect(scrapeResult.matched, 0);
    expect(scrapeResult.failed, 1);
    expect((await database.getWorks(sourceId: second)).single['title'],
        'Series Root');
    await database.upsertAssets([
      {
        'source_id': second,
        'relative_path': 'Season 1/episode.mkv',
        'work_key': '.',
        'name': 'episode.mkv',
        'kind': 'video',
        'category': 'episode',
      },
      {
        'source_id': second,
        'relative_path': 'Season 1/removed.mkv',
        'work_key': '.',
        'name': 'removed.mkv',
        'kind': 'video',
        'category': 'episode',
      },
    ]);
    await database.removeMissingAssets(
      sourceId: second,
      seenRelativePaths: {'Season 1/episode.mkv'},
    );
    expect(
        (await database.getAssets(sourceId: second)).map(
          (row) => row['relative_path'],
        ),
        ['Season 1/episode.mkv']);
    expect((await database.getWorks(sourceId: second)).single['title'],
        'Series Root');
    await database.removeMissingAssets(
      sourceId: second,
      seenRelativePaths: const {},
    );
    expect(await database.getAssets(sourceId: second), isEmpty);
    expect(await database.getWorks(sourceId: second), isEmpty);

    await database.upsertAssets([
      {
        'source_id': first,
        'relative_path': 'Show/SPs/clip [01].mkv',
        'work_key': 'Show',
        'name': 'clip [01].mkv',
        'kind': 'video',
        'category': 'extra',
      },
    ]);
    const relativePath = 'Show/SPs/clip [01].mkv';
    final manualWorkKey = await database.createManualWork(
      sourceId: first,
      title: 'Manually matched work',
    );
    await database.updateAssetRelation(
      sourceId: first,
      relativePath: relativePath,
      workKey: manualWorkKey,
      category: 'extra',
    );
    await database.upsertAssets([
      {
        'source_id': first,
        'relative_path': relativePath,
        'work_key': 'Show',
        'name': 'clip [01].mkv',
        'kind': 'video',
        'category': 'episode',
      },
    ]);
    var asset = (await database.getAssets(sourceId: first)).single;
    expect(asset['work_key'], manualWorkKey);
    expect(asset['category'], 'extra');
    expect(asset['relation_locked'], 1);

    expect(
      await database.undoLastAssetRelationChange(
        sourceId: first,
        relativePath: relativePath,
      ),
      isTrue,
    );
    asset = (await database.getAssets(sourceId: first)).single;
    expect(asset['work_key'], 'Show');
    expect(asset['category'], 'extra');
    expect(asset['relation_locked'], 0);

    await database.mapLibraryRoot(
      libraryId: first,
      connectionId: 'windows-webdav',
      rootPath: '/Windows/Mounted/Anime',
    );
    final shared = await database.exportSyncRecords();
    final sharedRoot = shared['root:$first']!;
    expect(sharedRoot.containsKey('connection_id'), isFalse);
    expect(sharedRoot.containsKey('root_path'), isFalse);
    expect(sharedRoot.containsValue('/Windows/Mounted/Anime'), isFalse);

    const androidSourceId = 'logical-cloud-source-1';
    await database.applySyncRecord(
      key: 'root:$androidSourceId',
      value: {
        'id': androidSourceId,
        'name': 'Anime',
        'created_at': DateTime.utc(2026).toIso8601String(),
      },
    );
    final syncedAsset = <String, Object?>{
      'source_id': androidSourceId,
      'relative_path': 'Show/SPs/clip [01].mkv',
      'work_key': manualWorkKey,
      'name': 'clip [01].mkv',
      'kind': 'video',
      'category': 'extra',
      'relation_locked': 1,
    };
    final syncKey = shared.keys.firstWhere((key) => key.startsWith('asset:'));
    await database.applySyncRecord(
      key: syncKey,
      value: {...syncedAsset, 'source_id': first},
    );
    await database.applySyncRecord(
      key: syncKey,
      value: {
        ...syncedAsset,
        'source_id': first,
        'work_key': 'Auto',
        'category': 'episode',
        'relation_locked': 0,
      },
    );
    final retainedLock = (await database.getAssets(sourceId: first))
        .singleWhere((row) => row['relative_path'] == 'Show/SPs/clip [01].mkv');
    expect(retainedLock['work_key'], manualWorkKey);
    expect(retainedLock['category'], 'extra');
    expect(retainedLock['relation_locked'], 1);

    await database.mapLibraryRoot(
      libraryId: androidSourceId,
      connectionId: 'android-webdav',
      rootPath: '/Android/Anime',
    );
    final mapped = await database.getLibraryRoot(androidSourceId);
    expect(mapped?['connection_id'], 'android-webdav');
    expect(mapped?['root_path'], '/Android/Anime');

    await database.deleteLibraryRoot(first);
    expect(await database.getLibraryRoot(first), isNull);
    expect(await database.getAssets(sourceId: first), isEmpty);
    expect(await database.getWorks(sourceId: first), isEmpty);
  });
}
