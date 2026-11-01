import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Private, app-local catalog database used by the cloud library feature.
/// It is separate from NipaPlay's hash-oriented metadata database.
class CloudMediaIndexDatabase {
  CloudMediaIndexDatabase._();
  static final CloudMediaIndexDatabase instance = CloudMediaIndexDatabase._();

  Future<Database>? _opening;
  Future<Database> get database => _opening ??= _open();

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
      version: 1,
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
      },
    );
  }

  Future<void> upsertAssets(List<Map<String, Object?>> assets) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      for (final asset in assets) {
        await txn.rawInsert(
          '''
          INSERT INTO cloud_media_asset
            (source_id, relative_path, name, kind, category, episode_number,
             work_key, size, modified_at, tmdb_id, last_seen_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(source_id, relative_path) DO UPDATE SET
            name=excluded.name, kind=excluded.kind,
            episode_number=excluded.episode_number,
            work_key=excluded.work_key,
            category=CASE WHEN cloud_media_asset.relation_locked=1
                          THEN cloud_media_asset.category ELSE excluded.category END,
            size=excluded.size, modified_at=excluded.modified_at,
            tmdb_id=COALESCE(cloud_media_asset.tmdb_id, excluded.tmdb_id),
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
            asset['tmdb_id'],
            now,
          ],
        );
      }
    });
  }

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
}
