import 'dart:io';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/utils/anime_info_parse.dart';
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
      version: 2,
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
        await _createWorkTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createWorkTable(db);
      },
    );
  }

  Future<void> _createWorkTable(DatabaseExecutor db) => db.execute('''
    CREATE TABLE cloud_media_work (
      source_id TEXT NOT NULL,
      work_key TEXT NOT NULL,
      tmdb_id INTEGER,
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

  Future<void> upsertWorkMetadata({
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required Map<String, dynamic> response,
    required BangumiAnime anime,
  }) async {
    final db = await database;
    final bangumi = response['bangumi'];
    final rawAnimeId =
        bangumi is Map ? bangumi['animeId'] : response['animeId'];
    await db.rawInsert('''
      INSERT INTO cloud_media_work
        (source_id, work_key, tmdb_id, dandanplay_anime_id, title, title_cn,
         bangumi_id, overview, poster_url, rating, metadata_json, metadata_status, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'matched', ?)
      ON CONFLICT(source_id, work_key) DO UPDATE SET
        tmdb_id=excluded.tmdb_id,
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
      tmdbId,
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
    required String title,
  }) async {
    final db = await database;
    await db.rawInsert('''
      INSERT INTO cloud_media_work
        (source_id, work_key, tmdb_id, title, title_cn, metadata_status, updated_at)
      VALUES (?, ?, ?, ?, ?, 'pending', ?)
      ON CONFLICT(source_id, work_key) DO UPDATE SET
        tmdb_id=COALESCE(cloud_media_work.tmdb_id, excluded.tmdb_id),
        title=CASE WHEN cloud_media_work.title='' THEN excluded.title ELSE cloud_media_work.title END,
        title_cn=CASE WHEN cloud_media_work.title_cn='' THEN excluded.title_cn ELSE cloud_media_work.title_cn END,
        metadata_status=CASE WHEN cloud_media_work.metadata_status='matched' THEN 'matched' ELSE 'pending' END,
        updated_at=excluded.updated_at
      WHERE cloud_media_work.relation_locked=0
    ''', [
      sourceId,
      workKey,
      tmdbId,
      title,
      title,
      DateTime.now().toUtc().toIso8601String(),
    ]);
  }
}
