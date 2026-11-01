import 'dart:io';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/utils/anime_info_parse.dart';
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
            tmdb_type=CASE WHEN cloud_media_asset.relation_locked=1
                           THEN cloud_media_asset.tmdb_type ELSE excluded.tmdb_type END,
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
      if (parts.length != 2) throw FormatException('无效的媒体资源同步键');
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
            work_key=CASE WHEN cloud_media_asset.relation_locked=1
                          THEN cloud_media_asset.work_key ELSE excluded.work_key END,
            category=CASE WHEN cloud_media_asset.relation_locked=1
                          THEN cloud_media_asset.category ELSE excluded.category END,
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
      if (parts.length != 2) throw FormatException('无效的作品同步键');
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
    return db.query(
      'cloud_media_asset',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'relative_path COLLATE NOCASE',
    );
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

  Future<List<Map<String, Object?>>> getWorks({String? sourceId}) async {
    final db = await database;
    return db.query(
      'cloud_media_work',
      where: sourceId == null ? null : 'source_id = ?',
      whereArgs: sourceId == null ? null : [sourceId],
      orderBy: 'title_cn COLLATE NOCASE, title COLLATE NOCASE',
    );
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
