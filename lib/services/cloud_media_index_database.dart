import 'package:nipaplay/utils/cloud_media_file_classifier.dart';
import 'dart:io';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/utils/anime_info_parse.dart';
import 'package:nipaplay/utils/anime_text_sanitizer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

/// Private, app-local catalog database used by the cloud library feature.
/// It is separate from NipaPlay's hash-oriented metadata database.
class CloudMediaIndexDatabase {
  CloudMediaIndexDatabase._();
  static final CloudMediaIndexDatabase instance = CloudMediaIndexDatabase._();

  Future<Database>? _opening;
  Future<Database> get database => _opening ??= _open();

  /// Close the app-local index connection, for orderly shutdown and isolated
  /// tests that use a temporary application-support directory.
  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening == null) return;
    try {
      final db = await opening;
      if (db.isOpen) await db.close();
    } catch (_) {
      // A failed open has no live connection to close.
    }
  }

  Future<Database> _open() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final support = await getApplicationSupportDirectory();
    final path =
        '${support.path}${Platform.pathSeparator}cloud_media_library.db';
    return openDatabase(
      path,
      version: 5,
      onCreate: (db, _) async {
        await db.execute('''
        CREATE TABLE cloud_media_asset (
          source_id TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          name TEXT NOT NULL,
          kind TEXT NOT NULL,
          category TEXT NOT NULL,
          episode_number INTEGER,
          work_key TEXT NOT NULL DEFAULT '.',
          size INTEGER,
          modified_at TEXT,
          tmdb_id INTEGER,
          tmdb_type TEXT NOT NULL DEFAULT 'unknown',
          tmdb_tv_id INTEGER,
          tmdb_movie_id INTEGER,
          tmdb_unknown_id INTEGER,
          work_id TEXT,
          relation_locked INTEGER NOT NULL DEFAULT 0,
          last_seen_at TEXT NOT NULL,
          PRIMARY KEY (source_id, relative_path)
        )
      ''');
        await db.execute(
          'CREATE INDEX cloud_media_asset_tmdb_id_index '
          'ON cloud_media_asset(tmdb_id)',
        );
        await db.execute(
          'CREATE INDEX cloud_media_asset_work_key_index '
          'ON cloud_media_asset(source_id, work_key)',
        );
        await _createWorkTable(db);
        await _createLibraryRootTable(db);
        await _createRelationHistoryTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createWorkTable(db);
        if (oldVersion < 3) {
          await _ensureColumn(db, 'cloud_media_asset', 'tmdb_type',
              "TEXT NOT NULL DEFAULT 'unknown'");
          await _ensureColumn(db, 'cloud_media_asset', 'tmdb_tv_id', 'INTEGER');
          await _ensureColumn(
              db, 'cloud_media_asset', 'tmdb_movie_id', 'INTEGER');
          await _ensureColumn(
              db, 'cloud_media_asset', 'tmdb_unknown_id', 'INTEGER');
          await _ensureColumn(db, 'cloud_media_work', 'tmdb_type',
              "TEXT NOT NULL DEFAULT 'unknown'");
          await _ensureColumn(db, 'cloud_media_work', 'tmdb_tv_id', 'INTEGER');
          await _ensureColumn(
              db, 'cloud_media_work', 'tmdb_movie_id', 'INTEGER');
          await _ensureColumn(
              db, 'cloud_media_work', 'tmdb_unknown_id', 'INTEGER');
          await db.execute('''
            UPDATE cloud_media_asset SET tmdb_unknown_id=tmdb_id
            WHERE tmdb_id IS NOT NULL AND tmdb_unknown_id IS NULL
          ''');
          await db.execute('''
            UPDATE cloud_media_work SET tmdb_unknown_id=tmdb_id
            WHERE tmdb_id IS NOT NULL AND tmdb_unknown_id IS NULL
          ''');
        }
        if (oldVersion < 4) await _createLibraryRootTable(db);
        if (oldVersion < 5) await _createRelationHistoryTable(db);
      },
    );
  }

  Future<void> _createWorkTable(DatabaseExecutor db) => db.execute('''
    CREATE TABLE cloud_media_work (
      source_id TEXT NOT NULL,
      work_key TEXT NOT NULL,
      tmdb_id INTEGER,
      tmdb_type TEXT NOT NULL DEFAULT 'unknown',
      tmdb_tv_id INTEGER,
      tmdb_movie_id INTEGER,
      tmdb_unknown_id INTEGER,
      dandanplay_anime_id INTEGER,
      bangumi_id INTEGER,
      title TEXT NOT NULL,
      title_cn TEXT NOT NULL,
      overview TEXT,
      poster_url TEXT,
      rating REAL,
      metadata_json TEXT,
      metadata_status TEXT NOT NULL DEFAULT 'pending',
      relation_locked INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (source_id, work_key)
    )
  ''');

  Future<void> upsertAssets(List<Map<String, Object?>> assets) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      for (final asset in assets) {
        await txn.rawInsert(
          '''
          INSERT INTO cloud_media_asset
            (source_id, relative_path, name, kind, category, episode_number,
             work_key, size, modified_at, tmdb_id, tmdb_type, tmdb_unknown_id,
             tmdb_tv_id, tmdb_movie_id, last_seen_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)
          ON CONFLICT(source_id, relative_path) DO UPDATE SET
            name=excluded.name, kind=excluded.kind,
            episode_number=excluded.episode_number,
            work_key=CASE WHEN cloud_media_asset.relation_locked=1
                          THEN cloud_media_asset.work_key ELSE excluded.work_key END,
            category=CASE WHEN cloud_media_asset.relation_locked=1
                          THEN cloud_media_asset.category ELSE excluded.category END,
            size=excluded.size, modified_at=excluded.modified_at,
            tmdb_type=CASE WHEN excluded.relation_locked=1
                                 OR cloud_media_asset.relation_locked=0
                           THEN excluded.tmdb_type ELSE cloud_media_asset.tmdb_type END,
            tmdb_unknown_id=COALESCE(cloud_media_asset.tmdb_unknown_id, excluded.tmdb_unknown_id),
            tmdb_tv_id=COALESCE(cloud_media_asset.tmdb_tv_id, excluded.tmdb_tv_id),
            tmdb_movie_id=COALESCE(cloud_media_asset.tmdb_movie_id, excluded.tmdb_movie_id),
            last_seen_at=excluded.last_seen_at
        ''',
          [
            asset['source_id'],
            asset['relative_path'],
            asset['name'],
            asset['kind'],
            asset['category'],
            asset['episode_number'],
            asset['work_key'],
            asset['size'],
            asset['modified_at'],
            asset['tmdb_type'] ?? 'unknown',
            asset['tmdb_type'] == 'tv' ? asset['tmdb_id'] : null,
            asset['tmdb_type'] == 'movie' ? asset['tmdb_id'] : null,
            (asset['tmdb_type'] ?? 'unknown') == 'unknown'
                ? asset['tmdb_id']
                : null,
            now,
          ],
        );
      }
    });
  }

  Future<String> ensureLibraryRoot({
    required String connectionId,
    required String rootPath,
  }) async {
    final db = await database;
    final normalizedPath = _normalizeRootPath(rootPath);
    final existing = await db.query(
      'cloud_media_library_root',
      columns: ['id'],
      where: 'connection_id = ? AND root_path = ?',
      whereArgs: [connectionId, normalizedPath],
      limit: 1,
    );
    if (existing.isNotEmpty) return existing.first['id']! as String;

    final segments = normalizedPath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    await db.insert(
      'cloud_media_library_root',
      {
        'id': const Uuid().v4(),
        'connection_id': connectionId,
        'root_path': normalizedPath,
        'name': segments.isEmpty ? '/' : segments.last,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final created = await db.query(
      'cloud_media_library_root',
      columns: ['id'],
      where: 'connection_id = ? AND root_path = ?',
      whereArgs: [connectionId, normalizedPath],
      limit: 1,
    );
    if (created.isEmpty) {
      throw StateError('Could not register cloud library root');
    }
    return created.first['id']! as String;
  }

  Future<String?> getLibraryRootId({
    required String connectionId,
    required String rootPath,
  }) async {
    final db = await database;
    final rows = await db.query(
      'cloud_media_library_root',
      columns: ['id'],
      where: 'connection_id = ? AND root_path = ?',
      whereArgs: [connectionId, _normalizeRootPath(rootPath)],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<void> markLibraryRootScanned(String libraryId) async {
    final db = await database;
    await db.update(
      'cloud_media_library_root',
      {'last_scanned_at': DateTime.now().toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: [libraryId],
    );
  }

  /// Finds an existing logical library for a completed scan.
  ///
  /// CloudDrive mounts can expose the same folder under different root paths.
  /// When the relative inventory, root folder name and connection match, the
  /// existing library is reused and its root path is updated instead of
  /// creating a second poster wall.
  Future<String> resolveLibraryRootFromScan({
    required String connectionId,
    required String rootPath,
    required Iterable<Map<String, Object?>> scannedAssets,
  }) async {
    final db = await database;
    final normalizedPath = _normalizeRootPath(rootPath);
    final rootName = _rootName(normalizedPath);
    final signature = assetInventorySignature(scannedAssets);

    final direct = await db.query(
      'cloud_media_library_root',
      where: 'connection_id = ? AND root_path = ?',
      whereArgs: [connectionId, normalizedPath],
      limit: 1,
    );
    if (direct.isNotEmpty) return direct.first['id']! as String;

    final candidates = await db.query(
      'cloud_media_library_root',
      where: 'connection_id = ? AND name = ?',
      whereArgs: [connectionId, rootName],
    );
    for (final candidate in candidates) {
      final id = candidate['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final assets = await getAssets(sourceId: id);
      if (assetInventorySignature(assets) != signature) continue;
      await db.update(
        'cloud_media_library_root',
        {'root_path': normalizedPath},
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    }

    return ensureLibraryRoot(
      connectionId: connectionId,
      rootPath: normalizedPath,
    );
  }

  /// Collapses library roots that point at the same cloud inventory.
  ///
  /// This repairs catalogs created before root-path aliases were recognized.
  /// It never merges roots with different file inventories or root names.
  Future<int> deduplicateEquivalentLibraryRoots({String? connectionId}) async {
    final db = await database;
    final roots = await db.query(
      'cloud_media_library_root',
      where: connectionId == null ? null : 'connection_id = ?',
      whereArgs: connectionId == null ? null : [connectionId],
    );
    final groups = <String, List<Map<String, Object?>>>{};
    for (final root in roots) {
      final id = root['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final assets = await getAssets(sourceId: id);
      if (assets.isEmpty) continue;
      final groupKey =
          '${root['connection_id']}\n${root['name']}\n${assetInventorySignature(assets)}';
      groups.putIfAbsent(groupKey, () => []).add(root);
    }

    var removed = 0;
    await db.transaction((txn) async {
      for (final group in groups.values) {
        if (group.length < 2) continue;
        if (await _hasConflictingLocks(txn, group)) continue;
        final ranked = await _rankLibraryRoots(txn, group);
        final canonical = ranked.first;
        final canonicalId = canonical['id']! as String;
        for (final duplicate in ranked.skip(1)) {
          final duplicateId = duplicate['id']! as String;
          await _mergeLibraryRootData(
            txn,
            canonicalId: canonicalId,
            duplicateId: duplicateId,
          );
          removed++;
        }
      }
    });
    return removed;
  }

  Future<bool> _hasConflictingLocks(
    DatabaseExecutor db,
    List<Map<String, Object?>> roots,
  ) async {
    final workOwners = <String, Set<String>>{};
    final assetOwners = <String, Set<String>>{};
    for (final root in roots) {
      final sourceId = root['id']?.toString() ?? '';
      final works = await db.query(
        'cloud_media_work',
        columns: ['work_key'],
        where: 'source_id = ? AND relation_locked = 1',
        whereArgs: [sourceId],
      );
      for (final work in works) {
        final workKey = work['work_key']?.toString() ?? '';
        workOwners.putIfAbsent(workKey, () => {}).add(sourceId);
      }
      final assets = await db.query(
        'cloud_media_asset',
        columns: ['relative_path'],
        where: 'source_id = ? AND relation_locked = 1',
        whereArgs: [sourceId],
      );
      for (final asset in assets) {
        final relativePath = asset['relative_path']?.toString() ?? '';
        assetOwners.putIfAbsent(relativePath, () => {}).add(sourceId);
      }
    }
    return workOwners.values.any((owners) => owners.length > 1) ||
        assetOwners.values.any((owners) => owners.length > 1);
  }

  /// Stable inventory key used to distinguish file add/remove from a plain
  /// rescan. Work/category are derived metadata and must not prevent a root
  /// alias from being recognized after classification rules change.
  static String assetInventorySignature(
    Iterable<Map<String, Object?>> assets,
  ) {
    final entries = assets
        .map((asset) => [
              asset['relative_path']?.toString() ?? '',
              asset['kind']?.toString() ?? '',
              asset['size']?.toString() ?? '',
            ].join('\u0001'))
        .toList()
      ..sort();
    return entries.join('\u0002');
  }

  String _rootName(String rootPath) {
    final normalized = _normalizeRootPath(rootPath);
    final segments =
        normalized.split('/').where((segment) => segment.isNotEmpty).toList();
    return segments.isEmpty ? '/' : segments.last;
  }

  Future<List<Map<String, Object?>>> _rankLibraryRoots(
    DatabaseExecutor db,
    List<Map<String, Object?>> roots,
  ) async {
    final ranked = <({Map<String, Object?> root, int score, String updated})>[];
    for (final root in roots) {
      final id = root['id']?.toString() ?? '';
      final works = await db.query(
        'cloud_media_work',
        columns: [
          'metadata_status',
          'dandanplay_anime_id',
          'bangumi_id',
          'relation_locked',
          'updated_at',
        ],
        where: 'source_id = ?',
        whereArgs: [id],
      );
      var score = 0;
      var latest = '';
      final lockedAssetRows = await db.rawQuery(
        '''
            SELECT COUNT(*) FROM cloud_media_asset
            WHERE source_id = ? AND relation_locked = 1
            ''',
        [id],
      );
      final lockedAssets = int.tryParse(
            lockedAssetRows.first.values.first?.toString() ?? '',
          ) ??
          0;
      score += lockedAssets * 50000;
      for (final work in works) {
        if (work['relation_locked'] == 1) score += 100000;
        if (work['dandanplay_anime_id'] != null) score += 10000;
        if (work['bangumi_id'] != null) score += 1000;
        if (work['metadata_status']?.toString() == 'matched') score += 500;
        final updated = work['updated_at']?.toString() ?? '';
        if (updated.compareTo(latest) > 0) latest = updated;
      }
      ranked.add((root: root, score: score, updated: latest));
    }
    ranked.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      final updated = b.updated.compareTo(a.updated);
      if (updated != 0) return updated;
      return a.root['id'].toString().compareTo(b.root['id'].toString());
    });
    return ranked.map((entry) => entry.root).toList(growable: false);
  }

  Future<void> _mergeLibraryRootData(
    Transaction txn, {
    required String canonicalId,
    required String duplicateId,
  }) async {
    final duplicateWorks = await txn.query(
      'cloud_media_work',
      where: 'source_id = ?',
      whereArgs: [duplicateId],
    );
    for (final work in duplicateWorks) {
      final workKey = work['work_key']?.toString() ?? '';
      final existing = await txn.query(
        'cloud_media_work',
        where: 'source_id = ? AND work_key = ?',
        whereArgs: [canonicalId, workKey],
        limit: 1,
      );
      if (existing.isNotEmpty &&
          _workMetadataScore(existing.first) >= _workMetadataScore(work)) {
        continue;
      }
      final merged = Map<String, Object?>.from(work)
        ..['source_id'] = canonicalId;
      await txn.insert(
        'cloud_media_work',
        merged,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final duplicateAssets = await txn.query(
      'cloud_media_asset',
      where: 'source_id = ?',
      whereArgs: [duplicateId],
    );
    for (final asset in duplicateAssets) {
      final relativePath = asset['relative_path']?.toString() ?? '';
      await txn.rawUpdate(
        '''
        UPDATE cloud_media_asset SET
          tmdb_id=COALESCE(tmdb_id, ?),
          tmdb_tv_id=COALESCE(tmdb_tv_id, ?),
          tmdb_movie_id=COALESCE(tmdb_movie_id, ?),
          tmdb_unknown_id=COALESCE(tmdb_unknown_id, ?),
          work_id=COALESCE(work_id, ?)
        WHERE source_id = ? AND relative_path = ?
        ''',
        [
          asset['tmdb_id'],
          asset['tmdb_tv_id'],
          asset['tmdb_movie_id'],
          asset['tmdb_unknown_id'],
          asset['work_id'],
          canonicalId,
          relativePath,
        ],
      );
    }

    await txn.update(
      'cloud_media_relation_history',
      {'source_id': canonicalId},
      where: 'source_id = ?',
      whereArgs: [duplicateId],
    );
    await txn.delete(
      'cloud_media_asset',
      where: 'source_id = ?',
      whereArgs: [duplicateId],
    );
    await txn.delete(
      'cloud_media_work',
      where: 'source_id = ?',
      whereArgs: [duplicateId],
    );
    await txn.delete(
      'cloud_media_library_root',
      where: 'id = ?',
      whereArgs: [duplicateId],
    );
  }

  int _workMetadataScore(Map<String, Object?> work) {
    var score = 0;
    if (work['relation_locked'] == 1) score += 100000;
    if (work['dandanplay_anime_id'] != null) score += 10000;
    if (work['bangumi_id'] != null) score += 1000;
    if (work['metadata_status']?.toString() == 'matched') score += 500;
    score += work['poster_url']?.toString().length ?? 0;
    return score;
  }

  /// Repairs old scans of a library root that is itself a TMDB work folder.
  /// Older indexes could keep its videos under the synthetic unassociated key
  /// even though the root name already identifies their only work.
  Future<void> assignUnassociatedVideosToWork({
    required String sourceId,
    required String workKey,
  }) async {
    final normalizedWorkKey = workKey.trim();
    if (normalizedWorkKey.isEmpty || normalizedWorkKey == '.') return;
    final db = await database;
    await db.update(
      'cloud_media_asset',
      {'work_key': normalizedWorkKey},
      where: "source_id = ? AND kind = 'video' AND work_key = '.'",
      whereArgs: [sourceId],
    );
  }

  /// Prunes catalog rows that disappeared during a completed, successful
  /// scan. Callers must never invoke this when remote enumeration failed.
  Future<void> removeMissingAssets({
    required String sourceId,
    required Set<String> seenRelativePaths,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'cloud_media_asset',
        columns: ['relative_path'],
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      final missing = rows
          .map((row) => row['relative_path']?.toString() ?? '')
          .where((path) => !seenRelativePaths.contains(path))
          .toList();
      for (final path in missing) {
        await txn.delete(
          'cloud_media_asset',
          where: 'source_id = ? AND relative_path = ?',
          whereArgs: [sourceId, path],
        );
      }
      await txn.rawDelete('''
        DELETE FROM cloud_media_work
        WHERE source_id = ? AND NOT EXISTS (
          SELECT 1 FROM cloud_media_asset
          WHERE cloud_media_asset.source_id = cloud_media_work.source_id
            AND cloud_media_asset.work_key = cloud_media_work.work_key
        )
      ''', [sourceId]);
    });
  }

  /// Removes automatically-created work rows after assets are reassigned.
  /// User-locked manual works are kept even while empty.
  Future<void> removeOrphanedWorks(String sourceId) async {
    final db = await database;
    await db.delete(
      'cloud_media_work',
      where: '''source_id = ? AND relation_locked = 0 AND NOT EXISTS (
        SELECT 1 FROM cloud_media_asset
        WHERE cloud_media_asset.source_id = cloud_media_work.source_id
          AND cloud_media_asset.work_key = cloud_media_work.work_key
      )''',
      whereArgs: [sourceId],
    );
  }

  Future<Map<String, Object?>?> getLibraryRoot(String libraryId) async {
    final db = await database;
    final rows = await db.query(
      'cloud_media_library_root',
      where: 'id = ?',
      whereArgs: [libraryId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> getLibraryRoots({
    String? connectionId,
  }) async {
    final db = await database;
    return db.query(
      'cloud_media_library_root',
      where: connectionId == null ? null : 'connection_id = ?',
      whereArgs: connectionId == null ? null : [connectionId],
      orderBy: 'name COLLATE NOCASE',
    );
  }

  Future<void> deleteLibraryRoot(String libraryId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'cloud_media_relation_history',
        where: 'source_id = ?',
        whereArgs: [libraryId],
      );
      await txn.delete(
        'cloud_media_asset',
        where: 'source_id = ?',
        whereArgs: [libraryId],
      );
      await txn.delete(
        'cloud_media_work',
        where: 'source_id = ?',
        whereArgs: [libraryId],
      );
      await txn.delete(
        'cloud_media_library_root',
        where: 'id = ?',
        whereArgs: [libraryId],
      );
    });
  }

  /// Returns entity-level records for the incremental shared catalog sync.
  /// Connection IDs and absolute root paths are deliberately excluded so a
  /// receiving device must map each logical source to its own WebDAV target.
  Future<Map<String, Map<String, Object?>>> exportSyncRecords() async {
    final db = await database;
    final result = <String, Map<String, Object?>>{};
    final roots = await db.query('cloud_media_library_root');
    final localOnlySourceIds = <String>{};
    for (final row in roots) {
      final id = row['id']?.toString();
      if (id == null) continue;
      if (row['connection_id']?.toString().startsWith('local:') == true) {
        localOnlySourceIds.add(id);
        continue;
      }
      result['root:$id'] = {
        'id': id,
        'name': row['name'],
        'created_at': row['created_at'],
      };
    }
    for (final row in await db.query('cloud_media_asset')) {
      final sourceId = row['source_id']?.toString() ?? '';
      if (localOnlySourceIds.contains(sourceId)) continue;
      final relativePath = row['relative_path']?.toString() ?? '';
      final key = base64Url.encode(utf8.encode('$sourceId\n$relativePath'));
      result['asset:$key'] = Map<String, Object?>.from(row)
        ..remove('last_seen_at');
    }
    for (final row in await db.query('cloud_media_work')) {
      if (localOnlySourceIds.contains(row['source_id']?.toString())) continue;
      final key = base64Url.encode(utf8.encode(
        '${row['source_id']}\n${row['work_key']}',
      ));
      result['work:$key'] = Map<String, Object?>.from(row);
    }
    for (final row in await db.query('cloud_media_relation_history')) {
      if (localOnlySourceIds.contains(row['source_id']?.toString())) continue;
      final id = row['id']?.toString();
      if (id != null) result['relation:$id'] = Map<String, Object?>.from(row);
    }
    return result;
  }

  /// Applies one idempotent entity operation received from the shared catalog.
  Future<void> applySyncRecord({
    required String key,
    required Map<String, Object?>? value,
  }) async {
    final db = await database;
    final deleted = value == null;
    if (key.startsWith('root:')) {
      final id = key.substring('root:'.length);
      if (deleted) {
        // Keep a mapped root while assets still reference it; its catalog rows
        // are removed by their own explicit delete operations.
        final assets = await db.query('cloud_media_asset',
            columns: ['source_id'],
            where: 'source_id = ?',
            whereArgs: [id],
            limit: 1);
        if (assets.isEmpty) {
          await db.delete('cloud_media_library_root',
              where: 'id = ?', whereArgs: [id]);
        }
      } else {
        await db.rawInsert('''
          INSERT INTO cloud_media_library_root (id, connection_id, root_path, name, created_at)
          VALUES (?, ?, '/', ?, ?)
          ON CONFLICT(id) DO UPDATE SET name=excluded.name
        ''', [
          id,
          'unmapped:$id',
          value['name'] ?? '媒体库',
          value['created_at'] ?? DateTime.now().toUtc().toIso8601String()
        ]);
      }
      return;
    }
    if (key.startsWith('asset:')) {
      final encoded = key.substring('asset:'.length);
      final decoded =
          utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      final parts = decoded.split('\n');
      if (parts.length != 2) throw const FormatException('无效的媒体资源同步键');
      if (deleted) {
        await db.delete('cloud_media_asset',
            where: 'source_id = ? AND relative_path = ?', whereArgs: parts);
      } else {
        final sourceId = value['source_id']?.toString() ?? parts[0];
        final relativePath = value['relative_path']?.toString() ?? parts[1];
        await db.rawInsert('''
          INSERT INTO cloud_media_asset
            (source_id, relative_path, name, kind, category, episode_number,
             work_key, size, modified_at, tmdb_id, tmdb_type, tmdb_tv_id,
             tmdb_movie_id, tmdb_unknown_id, work_id, relation_locked, last_seen_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(source_id, relative_path) DO UPDATE SET
            name=excluded.name, kind=excluded.kind, size=excluded.size,
            modified_at=excluded.modified_at,
            tmdb_id=excluded.tmdb_id,
            tmdb_type=CASE WHEN cloud_media_asset.relation_locked=1
                           THEN cloud_media_asset.tmdb_type ELSE excluded.tmdb_type END,
            tmdb_tv_id=COALESCE(cloud_media_asset.tmdb_tv_id, excluded.tmdb_tv_id),
            tmdb_movie_id=COALESCE(cloud_media_asset.tmdb_movie_id, excluded.tmdb_movie_id),
            tmdb_unknown_id=COALESCE(cloud_media_asset.tmdb_unknown_id, excluded.tmdb_unknown_id),
            work_key=CASE WHEN excluded.relation_locked=1
                                OR cloud_media_asset.relation_locked=0
                          THEN excluded.work_key ELSE cloud_media_asset.work_key END,
            category=CASE WHEN excluded.relation_locked=1
                               OR cloud_media_asset.relation_locked=0
                          THEN excluded.category ELSE cloud_media_asset.category END,
            relation_locked=MAX(cloud_media_asset.relation_locked, excluded.relation_locked),
            work_id=COALESCE(cloud_media_asset.work_id, excluded.work_id),
            last_seen_at=excluded.last_seen_at
        ''', [
          sourceId,
          relativePath,
          value['name'] ?? '',
          value['kind'] ?? 'video',
          value['category'] ?? 'review',
          value['episode_number'],
          value['work_key'] ?? '.',
          value['size'],
          value['modified_at'],
          value['tmdb_id'],
          value['tmdb_type'] ?? 'unknown',
          value['tmdb_tv_id'],
          value['tmdb_movie_id'],
          value['tmdb_unknown_id'],
          value['work_id'],
          value['relation_locked'] ?? 0,
          DateTime.now().toUtc().toIso8601String(),
        ]);
      }
      return;
    }
    if (key.startsWith('work:')) {
      final encoded = key.substring('work:'.length);
      final decoded =
          utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      final parts = decoded.split('\n');
      if (parts.length != 2) throw const FormatException('无效的作品同步键');
      if (deleted) {
        await db.delete('cloud_media_work',
            where: 'source_id = ? AND work_key = ?', whereArgs: parts);
      } else {
        await db.rawInsert('''
          INSERT INTO cloud_media_work
            (source_id, work_key, tmdb_id, tmdb_type, tmdb_tv_id, tmdb_movie_id,
             tmdb_unknown_id, dandanplay_anime_id, bangumi_id, title, title_cn,
             overview, poster_url, rating, metadata_json, metadata_status,
             relation_locked, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(source_id, work_key) DO UPDATE SET
            tmdb_id=excluded.tmdb_id, tmdb_type=excluded.tmdb_type,
            tmdb_tv_id=excluded.tmdb_tv_id, tmdb_movie_id=excluded.tmdb_movie_id,
            tmdb_unknown_id=excluded.tmdb_unknown_id,
            dandanplay_anime_id=excluded.dandanplay_anime_id,
            bangumi_id=excluded.bangumi_id, title=excluded.title,
            title_cn=excluded.title_cn, overview=excluded.overview,
            poster_url=excluded.poster_url, rating=excluded.rating,
            metadata_json=excluded.metadata_json,
            metadata_status=excluded.metadata_status,
            relation_locked=MAX(cloud_media_work.relation_locked, excluded.relation_locked),
            updated_at=excluded.updated_at
        ''', [
          value['source_id'] ?? parts[0],
          value['work_key'] ?? parts[1],
          value['tmdb_id'],
          value['tmdb_type'] ?? 'unknown',
          value['tmdb_tv_id'],
          value['tmdb_movie_id'],
          value['tmdb_unknown_id'],
          value['dandanplay_anime_id'],
          value['bangumi_id'],
          value['title'] ?? '',
          value['title_cn'] ?? '',
          value['overview'],
          value['poster_url'],
          value['rating'],
          value['metadata_json'],
          value['metadata_status'] ?? 'pending',
          value['relation_locked'] ?? 0,
          value['updated_at'] ?? DateTime.now().toUtc().toIso8601String(),
        ]);
      }
      return;
    }
    if (key.startsWith('relation:')) {
      final id = key.substring('relation:'.length);
      if (deleted) {
        await db.delete('cloud_media_relation_history',
            where: 'id = ?', whereArgs: [id]);
      } else {
        await db.insert('cloud_media_relation_history', value,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  Future<void> mapLibraryRoot({
    required String libraryId,
    required String connectionId,
    required String rootPath,
  }) async {
    final db = await database;
    final normalized = _normalizeRootPath(rootPath);
    await db.update(
      'cloud_media_library_root',
      {'connection_id': connectionId, 'root_path': normalized},
      where: 'id = ?',
      whereArgs: [libraryId],
    );
  }

  String _normalizeRootPath(String path) {
    var normalized = path.trim().replaceAll('\\', '/');
    if (!normalized.startsWith('/')) normalized = '/$normalized';
    normalized = normalized.replaceAll(RegExp(r'/+'), '/');
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  Future<void> _createLibraryRootTable(DatabaseExecutor db) => db.execute('''
    CREATE TABLE cloud_media_library_root (
      id TEXT PRIMARY KEY,
      connection_id TEXT NOT NULL,
      root_path TEXT NOT NULL,
      name TEXT NOT NULL,
      created_at TEXT NOT NULL,
      last_scanned_at TEXT,
      UNIQUE(connection_id, root_path)
    )
  ''');

  Future<void> _createRelationHistoryTable(DatabaseExecutor db) =>
      db.execute('''
    CREATE TABLE cloud_media_relation_history (
      id TEXT PRIMARY KEY,
      source_id TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      before_work_key TEXT NOT NULL,
      before_category TEXT NOT NULL,
      before_locked INTEGER NOT NULL,
      after_work_key TEXT NOT NULL,
      after_category TEXT NOT NULL,
      created_at TEXT NOT NULL,
      undone INTEGER NOT NULL DEFAULT 0
    )
  ''');

  Future<List<Map<String, Object?>>> getAssets({
    String? sourceId,
    String? workKey,
  }) async {
    final db = await database;
    final clauses = <String>[];
    final args = <Object?>[];
    if (sourceId != null) {
      clauses.add('source_id = ?');
      args.add(sourceId);
    }
    if (workKey != null) {
      clauses.add('work_key = ?');
      args.add(workKey);
    }
    final rows = await db.query(
      'cloud_media_asset',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'relative_path COLLATE NOCASE',
    );
    final result = <Map<String, Object?>>[];
    final batch = db.batch();
    var changed = false;
    for (final row in rows) {
      final path = '${row['relative_path']}'.replaceAll('\\', '/');
      final directory =
          path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
      final name = '${row['name']}';
      if (row['kind'] == 'video' &&
          row['category'] == 'review' &&
          row['relation_locked'] != 1 &&
          CloudMediaFileClassifier.classifyAsset(directory, name, 'video') ==
              'episode') {
        final values = <String, Object?>{
          'category': 'episode',
          'episode_number':
              CloudMediaFileClassifier.episodeNumberFromName(name),
        };
        batch.update('cloud_media_asset', values,
            where:
                'source_id = ? AND relative_path = ? AND relation_locked = 0 AND category = ?',
            whereArgs: [row['source_id'], row['relative_path'], 'review']);
        result.add({...row, ...values});
        changed = true;
      } else {
        result.add(row);
      }
    }
    if (changed) await batch.commit(noResult: true);
    return result;
  }

  Future<void> updateAssetRelation({
    required String sourceId,
    required String relativePath,
    required String workKey,
    required String category,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'cloud_media_asset',
        columns: ['work_key', 'category', 'relation_locked'],
        where: 'source_id = ? AND relative_path = ?',
        whereArgs: [sourceId, relativePath],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('媒体文件已不在索引中');
      final before = rows.first;
      await txn.insert('cloud_media_relation_history', {
        'id': const Uuid().v4(),
        'source_id': sourceId,
        'relative_path': relativePath,
        'before_work_key': before['work_key'],
        'before_category': before['category'],
        'before_locked': before['relation_locked'],
        'after_work_key': workKey,
        'after_category': category,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await txn.update(
        'cloud_media_asset',
        {'work_key': workKey, 'category': category, 'relation_locked': 1},
        where: 'source_id = ? AND relative_path = ?',
        whereArgs: [sourceId, relativePath],
      );
    });
  }

  Future<bool> undoLastAssetRelationChange({
    required String sourceId,
    required String relativePath,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final changes = await txn.query(
        'cloud_media_relation_history',
        where: 'source_id = ? AND relative_path = ? AND undone = 0',
        whereArgs: [sourceId, relativePath],
        orderBy: 'created_at DESC, rowid DESC',
        limit: 1,
      );
      if (changes.isEmpty) return false;
      final change = changes.first;
      await txn.update(
        'cloud_media_asset',
        {
          'work_key': change['before_work_key'],
          'category': change['before_category'],
          'relation_locked': change['before_locked'],
        },
        where: 'source_id = ? AND relative_path = ?',
        whereArgs: [sourceId, relativePath],
      );
      await txn.update(
        'cloud_media_relation_history',
        {'undone': 1},
        where: 'id = ?',
        whereArgs: [change['id']],
      );
      return true;
    });
  }

  Future<void> upsertWorkMetadata({
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required String tmdbType,
    required Map<String, dynamic> response,
    required BangumiAnime anime,
  }) async {
    final db = await database;
    final bangumi = response['bangumi'];
    final rawAnimeId =
        bangumi is Map ? bangumi['animeId'] : response['animeId'];
    await db.transaction((txn) async {
      await txn.rawInsert('''
      INSERT INTO cloud_media_work
        (source_id, work_key, tmdb_id, tmdb_type, tmdb_tv_id, tmdb_movie_id,
         tmdb_unknown_id, dandanplay_anime_id, title, title_cn,
         bangumi_id, overview, poster_url, rating, metadata_json, metadata_status, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'matched', ?)
      ON CONFLICT(source_id, work_key) DO UPDATE SET
        tmdb_type=excluded.tmdb_type,
        tmdb_tv_id=excluded.tmdb_tv_id,
        tmdb_movie_id=excluded.tmdb_movie_id,
        tmdb_unknown_id=excluded.tmdb_unknown_id,
        dandanplay_anime_id=excluded.dandanplay_anime_id,
        bangumi_id=excluded.bangumi_id,
        title=excluded.title, title_cn=excluded.title_cn,
        overview=excluded.overview, poster_url=excluded.poster_url,
        rating=excluded.rating, metadata_json=excluded.metadata_json,
        metadata_status='matched', updated_at=excluded.updated_at
      WHERE cloud_media_work.relation_locked=0
      ''', [
        sourceId,
        workKey,
        null,
        'tv',
        tmdbId,
        null,
        null,
        int.tryParse(rawAnimeId?.toString() ?? ''),
        anime.name,
        anime.nameCn,
        bangumi is Map<String, dynamic>
            ? AnimeInfoParse.getBangumiTvId(bangumi)
            : null,
        anime.summary,
        anime.imageUrl,
        anime.rating,
        jsonEncode(response),
        DateTime.now().toUtc().toIso8601String(),
      ]);
      if (tmdbType == 'tv') {
        await txn.update(
          'cloud_media_asset',
          {
            'tmdb_type': 'tv',
            'tmdb_tv_id': tmdbId,
            'tmdb_unknown_id': null,
          },
          where: '''
            source_id = ? AND work_key = ? AND relation_locked = 0
            AND tmdb_unknown_id = ?
          ''',
          whereArgs: [sourceId, workKey, tmdbId],
        );
      }
    });
  }

  Future<void> upsertTmdbWorkMetadata({
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required String tmdbType,
    required String title,
    required String originalTitle,
    required String overview,
    required String? posterUrl,
    required double? rating,
    required String metadataJson,
  }) async {
    if (tmdbType != 'tv' && tmdbType != 'movie') {
      throw ArgumentError.value(tmdbType, 'tmdbType');
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.rawInsert('''
        INSERT INTO cloud_media_work
          (source_id, work_key, tmdb_id, tmdb_type, tmdb_tv_id,
           tmdb_movie_id, tmdb_unknown_id, title, title_cn, overview,
           poster_url, rating, metadata_json, metadata_status, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, 'matched', ?)
        ON CONFLICT(source_id, work_key) DO UPDATE SET
          tmdb_id=excluded.tmdb_id, tmdb_type=excluded.tmdb_type,
          tmdb_tv_id=excluded.tmdb_tv_id,
          tmdb_movie_id=excluded.tmdb_movie_id,
          tmdb_unknown_id=NULL, title=excluded.title,
          title_cn=excluded.title_cn, overview=excluded.overview,
          poster_url=excluded.poster_url, rating=excluded.rating,
          metadata_json=excluded.metadata_json,
          metadata_status='matched', updated_at=excluded.updated_at
        WHERE cloud_media_work.relation_locked=0
      ''', [
        sourceId,
        workKey,
        tmdbId,
        tmdbType,
        tmdbType == 'tv' ? tmdbId : null,
        tmdbType == 'movie' ? tmdbId : null,
        originalTitle,
        title,
        overview,
        posterUrl,
        rating,
        metadataJson,
        DateTime.now().toUtc().toIso8601String(),
      ]);
      await txn.update(
        'cloud_media_asset',
        {
          'tmdb_id': tmdbId,
          'tmdb_type': tmdbType,
          'tmdb_tv_id': tmdbType == 'tv' ? tmdbId : null,
          'tmdb_movie_id': tmdbType == 'movie' ? tmdbId : null,
          'tmdb_unknown_id': null,
        },
        where: '''
          source_id = ? AND work_key = ? AND relation_locked=0
          AND (tmdb_unknown_id = ? OR tmdb_id = ?)
        ''',
        whereArgs: [sourceId, workKey, tmdbId, tmdbId],
      );
    });
  }

  Future<void> cacheTmdbEpisodeSeasons({
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required Map<String, dynamic> seasons,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('cloud_media_work',
          where: 'source_id = ? AND work_key = ? AND tmdb_tv_id = ?',
          whereArgs: [sourceId, workKey, tmdbId]);
      if (rows.isEmpty) return;
      Map<String, dynamic> metadata;
      try {
        metadata = Map<String, dynamic>.from(
            jsonDecode(rows.single['metadata_json']?.toString() ?? '{}')
                as Map);
      } catch (_) {
        metadata = {};
      }
      final previous = metadata['tmdb_episode_seasons'];
      metadata['tmdb_episode_seasons'] = {
        if (previous is Map) ...previous,
        ...seasons,
      };
      await txn.update(
          'cloud_media_work',
          {
            'metadata_json': jsonEncode(metadata),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'source_id = ? AND work_key = ? AND tmdb_tv_id = ?',
          whereArgs: [sourceId, workKey, tmdbId]);
    });
  }

  Future<void> cacheTmdbMovieArtwork({
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required String artworkUrl,
  }) =>
      cacheTmdbWorkArtwork(
        sourceId: sourceId,
        workKey: workKey,
        tmdbId: tmdbId,
        tmdbType: 'movie',
        artworkUrl: artworkUrl,
      );

  Future<void> cacheTmdbWorkArtwork({
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required String tmdbType,
    required String artworkUrl,
  }) async {
    if (tmdbType != 'tv' && tmdbType != 'movie') {
      throw ArgumentError.value(tmdbType, 'tmdbType');
    }
    final idColumn = tmdbType == 'tv' ? 'tmdb_tv_id' : 'tmdb_movie_id';
    final artworkKey = 'tmdb_${tmdbType}_artwork';
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('cloud_media_work',
          where: 'source_id = ? AND work_key = ? AND $idColumn = ?',
          whereArgs: [sourceId, workKey, tmdbId]);
      if (rows.isEmpty) return;
      Map<String, dynamic> metadata;
      try {
        metadata = Map<String, dynamic>.from(
          jsonDecode(rows.single['metadata_json']?.toString() ?? '{}') as Map,
        );
      } catch (_) {
        metadata = {};
      }
      metadata['backdrop_url'] = artworkUrl;
      metadata[artworkKey] = {
        'version': 1,
        'backdrop_url': artworkUrl,
      };
      await txn.update(
        'cloud_media_work',
        {
          'metadata_json': jsonEncode(metadata),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'source_id = ? AND work_key = ? AND $idColumn = ?',
        whereArgs: [sourceId, workKey, tmdbId],
      );
    });
  }

  Future<List<Map<String, Object?>>> getWorks({String? sourceId}) async {
    final db = await database;
    final rows = (await db.query(
      'cloud_media_work',
      where: sourceId == null ? null : 'source_id = ?',
      whereArgs: sourceId == null ? null : [sourceId],
      orderBy: 'title_cn COLLATE NOCASE, title COLLATE NOCASE',
    ))
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    for (final row in rows) {
      final overview = row['overview']?.toString();
      final cleaned = AnimeTextSanitizer.cleanSummary(overview);
      if (cleaned != overview) row['overview'] = cleaned;
    }
    return rows;
  }

  /// Removes provider translation credits from indexes created by older
  /// versions. The display reader also sanitizes, so this repair can wait for
  /// the next catalog load or scan without exposing the credit in the UI.
  Future<int> repairProviderTranslationCredits({String? sourceId}) async {
    final db = await database;
    final rows = await db.query(
      'cloud_media_work',
      columns: ['source_id', 'work_key', 'overview'],
      where: sourceId == null ? null : 'source_id = ?',
      whereArgs: sourceId == null ? null : [sourceId],
    );
    var repaired = 0;
    await db.transaction((txn) async {
      for (final row in rows) {
        final overview = row['overview']?.toString();
        final cleaned = AnimeTextSanitizer.cleanSummary(overview);
        if (cleaned == overview) continue;
        await txn.update(
          'cloud_media_work',
          {
            'overview': cleaned,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'source_id = ? AND work_key = ?',
          whereArgs: [row['source_id'], row['work_key']],
        );
        repaired++;
      }
    });
    return repaired;
  }

  Future<void> updateWorkPoster({
    required String sourceId,
    required String workKey,
    required String posterUrl,
    int? bangumiId,
  }) async {
    final db = await database;
    await db.update(
      'cloud_media_work',
      {
        'poster_url': posterUrl,
        if (bangumiId != null) 'bangumi_id': bangumiId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'source_id = ? AND work_key = ? AND relation_locked = 0',
      whereArgs: [sourceId, workKey],
    );
  }

  Future<void> upsertBangumiWorkMetadata({
    required String sourceId,
    required String workKey,
    required int bangumiId,
    required String title,
    required String titleCn,
    required String overview,
    required String posterUrl,
    required String metadataJson,
    int? tmdbId,
    String tmdbType = 'unknown',
    double? rating,
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.rawInsert('''
      INSERT INTO cloud_media_work
        (source_id, work_key, tmdb_id, tmdb_type, tmdb_tv_id,
         tmdb_movie_id, tmdb_unknown_id, bangumi_id, title, title_cn,
         overview, poster_url, rating, metadata_json, metadata_status, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'matched', ?)
      ON CONFLICT(source_id, work_key) DO UPDATE SET
        tmdb_id=COALESCE(excluded.tmdb_id, cloud_media_work.tmdb_id),
        tmdb_type=CASE WHEN excluded.tmdb_id IS NULL
                       THEN cloud_media_work.tmdb_type ELSE excluded.tmdb_type END,
        tmdb_tv_id=COALESCE(excluded.tmdb_tv_id, cloud_media_work.tmdb_tv_id),
        tmdb_movie_id=COALESCE(excluded.tmdb_movie_id, cloud_media_work.tmdb_movie_id),
        tmdb_unknown_id=COALESCE(excluded.tmdb_unknown_id, cloud_media_work.tmdb_unknown_id),
        bangumi_id=excluded.bangumi_id, title=excluded.title,
        title_cn=excluded.title_cn, overview=excluded.overview,
        poster_url=excluded.poster_url, rating=excluded.rating,
        metadata_json=excluded.metadata_json, metadata_status='matched',
        updated_at=excluded.updated_at
      WHERE cloud_media_work.relation_locked=0
    ''', [
      sourceId,
      workKey,
      tmdbId,
      tmdbId == null ? 'unknown' : tmdbType,
      tmdbType == 'tv' ? tmdbId : null,
      tmdbType == 'movie' ? tmdbId : null,
      tmdbId != null && tmdbType == 'unknown' ? tmdbId : null,
      bangumiId,
      title,
      titleCn,
      overview,
      posterUrl,
      rating,
      metadataJson,
      now,
    ]);
  }

  Future<void> upsertPendingWork({
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required String tmdbType,
    required String title,
  }) async {
    final db = await database;
    await db.rawInsert('''
      INSERT INTO cloud_media_work
        (source_id, work_key, tmdb_id, tmdb_type, tmdb_tv_id, tmdb_movie_id,
         tmdb_unknown_id, title, title_cn, metadata_status, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)
      ON CONFLICT(source_id, work_key) DO UPDATE SET
        tmdb_type=excluded.tmdb_type,
        tmdb_tv_id=COALESCE(cloud_media_work.tmdb_tv_id, excluded.tmdb_tv_id),
        tmdb_movie_id=COALESCE(cloud_media_work.tmdb_movie_id, excluded.tmdb_movie_id),
        tmdb_unknown_id=COALESCE(cloud_media_work.tmdb_unknown_id, excluded.tmdb_unknown_id),
        title=CASE WHEN cloud_media_work.title='' THEN excluded.title ELSE cloud_media_work.title END,
        title_cn=CASE WHEN cloud_media_work.title_cn='' THEN excluded.title_cn ELSE cloud_media_work.title_cn END,
        metadata_status=CASE WHEN cloud_media_work.metadata_status='matched' THEN 'matched' ELSE 'pending' END,
        updated_at=excluded.updated_at
      WHERE cloud_media_work.relation_locked=0
    ''', [
      sourceId,
      workKey,
      null,
      tmdbType,
      tmdbType == 'tv' ? tmdbId : null,
      tmdbType == 'movie' ? tmdbId : null,
      tmdbType == 'unknown' ? tmdbId : null,
      title,
      title,
      DateTime.now().toUtc().toIso8601String(),
    ]);
  }

  Future<void> upsertUnmatchedWork({
    required String sourceId,
    required String workKey,
    required String title,
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.rawInsert('''
      INSERT INTO cloud_media_work
        (source_id, work_key, title, title_cn, tmdb_type,
         metadata_status, updated_at)
      VALUES (?, ?, ?, ?, 'unknown', 'pending', ?)
      ON CONFLICT(source_id, work_key) DO UPDATE SET
        title=CASE WHEN cloud_media_work.relation_locked=1
                   THEN cloud_media_work.title ELSE excluded.title END,
        title_cn=CASE WHEN cloud_media_work.relation_locked=1
                      THEN cloud_media_work.title_cn ELSE excluded.title_cn END,
        updated_at=excluded.updated_at
    ''', [sourceId, workKey, title, title, now]);
  }

  Future<void> upsertDandanplayWorkMetadata({
    required String sourceId,
    required String workKey,
    required Map<String, dynamic> response,
    required BangumiAnime anime,
  }) async {
    final db = await database;
    final bangumi = response['bangumi'];
    final rawAnimeId =
        bangumi is Map ? bangumi['animeId'] : response['animeId'];
    final tmdbId = bangumi is Map
        ? int.tryParse(
            (bangumi['tmdbId'] ?? bangumi['tmdb_id'])?.toString() ?? '')
        : int.tryParse(
            (response['tmdbId'] ?? response['tmdb_id'])?.toString() ?? '');
    await db.rawInsert('''
      INSERT INTO cloud_media_work
        (source_id, work_key, tmdb_id, tmdb_type, tmdb_tv_id,
         dandanplay_anime_id, bangumi_id, title, title_cn, overview,
         poster_url, rating, metadata_json, metadata_status, updated_at)
      VALUES (?, ?, ?, 'tv', ?, ?, ?, ?, ?, ?, ?, ?, ?, 'matched', ?)
      ON CONFLICT(source_id, work_key) DO UPDATE SET
        tmdb_id=COALESCE(excluded.tmdb_id, cloud_media_work.tmdb_id),
        tmdb_type=CASE WHEN excluded.tmdb_id IS NULL THEN cloud_media_work.tmdb_type ELSE 'tv' END,
        tmdb_tv_id=COALESCE(excluded.tmdb_tv_id, cloud_media_work.tmdb_tv_id),
        dandanplay_anime_id=excluded.dandanplay_anime_id,
        bangumi_id=excluded.bangumi_id, title=excluded.title,
        title_cn=excluded.title_cn, overview=excluded.overview,
        poster_url=excluded.poster_url, rating=excluded.rating,
        metadata_json=excluded.metadata_json, metadata_status='matched',
        updated_at=excluded.updated_at
      WHERE cloud_media_work.relation_locked=0
    ''', [
      sourceId,
      workKey,
      tmdbId,
      tmdbId,
      int.tryParse(rawAnimeId?.toString() ?? ''),
      bangumi is Map<String, dynamic>
          ? AnimeInfoParse.getBangumiTvId(bangumi)
          : null,
      anime.name,
      anime.nameCn,
      anime.summary,
      anime.imageUrl,
      anime.rating,
      jsonEncode(response),
      DateTime.now().toUtc().toIso8601String(),
    ]);
  }

  Future<String> createManualWork({
    required String sourceId,
    required String title,
  }) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) throw ArgumentError('作品名称不能为空');
    final workKey = 'manual:${const Uuid().v4()}';
    final db = await database;
    await db.insert('cloud_media_work', {
      'source_id': sourceId,
      'work_key': workKey,
      'tmdb_type': 'unknown',
      'title': normalizedTitle,
      'title_cn': normalizedTitle,
      'metadata_status': 'manual',
      'relation_locked': 1,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    return workKey;
  }

  Future<void> _ensureColumn(
    DatabaseExecutor db,
    String table,
    String column,
    String declaration,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (!columns.any((entry) => entry['name'] == column)) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $declaration');
    }
  }
}
