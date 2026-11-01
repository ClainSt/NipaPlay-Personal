import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
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

    await database.deleteLibraryRoot(first);
    expect(await database.getLibraryRoot(first), isNull);
    expect(await database.getAssets(sourceId: first), isEmpty);
    expect(await database.getWorks(sourceId: first), isEmpty);
  });
}
