import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/auto_sync_service.dart';
import 'package:nipaplay/services/backup_category.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/incremental_sync_transport.dart';
import 'package:nipaplay/utils/auto_sync_settings.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _MemorySyncTransport implements IncrementalSyncTransport {
  final Map<String, Uint8List> files = {};

  @override
  Future<void> ensureDirectory(String path) async {}

  @override
  Future<List<String>> listFileNames(String path) async => files.keys
      .where((file) => file.startsWith('$path/'))
      .map((file) => file.substring(path.length + 1))
      .toList();

  @override
  Future<Uint8List?> read(String path) async {
    final bytes = files[path];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  @override
  Future<void> write(String path, Uint8List bytes,
      {bool atomic = false}) async {
    files[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cloud catalog sync restores work and assets without device paths',
      () async {
    SharedPreferences.setMockInitialValues({});
    AutoSyncSettings.resetForTesting();
    final previousPaths = PathProviderPlatform.instance;
    final deviceA = await Directory.systemTemp.createTemp('sync_device_a_');
    final deviceB = await Directory.systemTemp.createTemp('sync_device_b_');
    final database = CloudMediaIndexDatabase.instance;
    final transport = _MemorySyncTransport();
    addTearDown(() async {
      await database.close();
      PathProviderPlatform.instance = previousPaths;
      AutoSyncSettings.resetForTesting();
      await deviceA.delete(recursive: true);
      await deviceB.delete(recursive: true);
    });

    PathProviderPlatform.instance = _TestPaths(deviceA.path);
    await database.ensureLibraryRoot(
      connectionId: 'device-a-webdav-connection',
      rootPath: '/private/cloud-drive/anime',
    );
    final root = (await database.getLibraryRoots()).single;
    final sourceId = root['id']! as String;
    final db = await database.database;
    await db.insert('cloud_media_work', {
      'source_id': sourceId,
      'work_key': 'tmdb-tv-100565',
      'tmdb_id': 100565,
      'tmdb_type': 'tv',
      'tmdb_tv_id': 100565,
      'title': 'Synced Work',
      'title_cn': '已同步作品',
      'overview': 'Shared synopsis',
      'poster_url': 'https://image.tmdb.org/t/p/w500/poster.jpg',
      'metadata_json': jsonEncode({'tmdbId': 100565}),
      'metadata_status': 'matched',
      'relation_locked': 0,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    await database.upsertAssets([
      {
        'source_id': sourceId,
        'relative_path': 'Show/SPs/NCOP.mkv',
        'name': 'NCOP.mkv',
        'kind': 'video',
        'category': 'special',
        'episode_number': null,
        'work_key': 'tmdb-tv-100565',
        'size': 4096,
        'modified_at': '2026-11-01T00:00:00Z',
        'tmdb_id': 100565,
        'tmdb_type': 'tv',
      },
    ]);

    await AutoSyncSettings.saveWebDavConfiguration(
      serverUrl: 'https://sync.example.invalid/dav',
      username: 'sync-user',
      password: 'sync-secret',
      remotePath: '/private-sync',
      intervalMinutes: 30,
      categories: {BackupCategory.mediaLibraries},
      syncOnRecordChange: false,
    );
    await AutoSyncSettings.setEnabled(true);
    final deviceAService = AutoSyncService.forTesting(
      transportFactory: ({
        required serverUrl,
        required username,
        required password,
      }) =>
          transport,
    );
    final publishResult = await deviceAService.manualSync();
    expect(publishResult.createdRepository, isTrue);
    deviceAService.dispose();

    final sharedBytes = transport.files.values
        .map((bytes) => utf8.decode(bytes, allowMalformed: true))
        .join('\n');
    for (final deviceOnlyValue in [
      'device-a-webdav-connection',
      '/private/cloud-drive/anime',
      'sync-user',
      'sync-secret',
    ]) {
      expect(sharedBytes, isNot(contains(deviceOnlyValue)));
    }
    expect(sharedBytes, contains('Show/SPs/NCOP.mkv'));
    expect(sharedBytes, contains('Shared synopsis'));

    await database.close();
    PathProviderPlatform.instance = _TestPaths(deviceB.path);
    final deviceBService = AutoSyncService.forTesting(
      transportFactory: ({
        required serverUrl,
        required username,
        required password,
      }) =>
          transport,
    );
    final restoreResult = await deviceBService.manualSync();
    expect(restoreResult.createdRepository, isFalse);
    expect(restoreResult.restoredOperations, greaterThan(0));
    final restoredRoot = (await database.getLibraryRoots()).single;
    expect(restoredRoot['id'], sourceId);
    expect(restoredRoot['connection_id'], 'unmapped:$sourceId');
    expect(restoredRoot['root_path'], '/');
    expect(await database.getWorks(sourceId: sourceId), hasLength(1));
    final restoredAsset = (await database.getAssets(sourceId: sourceId)).single;
    expect(restoredAsset['relative_path'], 'Show/SPs/NCOP.mkv');
    expect(restoredAsset['category'], 'special');
    await database.mapLibraryRoot(
      libraryId: sourceId,
      connectionId: 'device-b-webdav-connection',
      rootPath: '/android/mounted/anime',
    );
    final mapping = await database.getLibraryRoot(sourceId);
    expect(mapping?['connection_id'], 'device-b-webdav-connection');
    expect(mapping?['root_path'], '/android/mounted/anime');
    final manualWorkKey = await database.createManualWork(
      sourceId: sourceId,
      title: 'Manually linked work on device B',
    );
    await database.updateAssetRelation(
      sourceId: sourceId,
      relativePath: 'Show/SPs/NCOP.mkv',
      workKey: manualWorkKey,
      category: 'extra',
    );
    await deviceBService.manualSync();
    final republishedBytes = transport.files.values
        .map((bytes) => utf8.decode(bytes, allowMalformed: true))
        .join('\n');
    expect(republishedBytes, isNot(contains('device-b-webdav-connection')));
    expect(republishedBytes, isNot(contains('/android/mounted/anime')));
    deviceBService.dispose();

    await database.close();
    PathProviderPlatform.instance = _TestPaths(deviceA.path);
    await database.upsertAssets([
      {
        'source_id': sourceId,
        'relative_path': 'Show/SPs/NCOP.mkv',
        'name': 'NCOP.mkv',
        'kind': 'video',
        'category': 'episode',
        'work_key': 'tmdb-tv-100565',
        'size': 4096,
        'modified_at': '2026-11-01T00:00:00Z',
        'tmdb_id': 100565,
        'tmdb_type': 'tv',
      },
    ]);
    final deviceARefresh = AutoSyncService.forTesting(
      transportFactory: ({
        required serverUrl,
        required username,
        required password,
      }) =>
          transport,
    );
    await deviceARefresh.manualSync();
    final mergedAsset = (await database.getAssets(sourceId: sourceId)).single;
    expect(mergedAsset['work_key'], manualWorkKey);
    expect(mergedAsset['category'], 'extra');
    expect(mergedAsset['relation_locked'], 1);
    expect(await database.getWorks(sourceId: sourceId), hasLength(2));
    deviceARefresh.dispose();
  });
}
