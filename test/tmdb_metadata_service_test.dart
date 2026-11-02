import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_scraper.dart';
import 'package:nipaplay/services/tmdb_metadata_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _CapturingTmdbMetadataService extends TmdbMetadataService {
  int? tmdbId;
  String? tmdbType;
  String? sourceId;
  String? workKey;

  @override
  Future<bool> scrapeWork({
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required String type,
  }) async {
    this.sourceId = sourceId;
    this.workKey = workKey;
    this.tmdbId = tmdbId;
    tmdbType = type;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late PathProviderPlatform previousPaths;
  late Future<void> Function() closeDatabase;
  final database = CloudMediaIndexDatabase.instance;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('tmdb_metadata_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    final db = await database.database;
    closeDatabase = db.close;
  });

  tearDownAll(() async {
    await closeDatabase();
    PathProviderPlatform.instance = previousPaths;
    await temp.delete(recursive: true);
  });

  test('TMDB movie ID fetches and stores localized metadata as movie',
      () async {
    final requests = <http.Request>[];
    final service = TmdbMetadataService(
      tokenReader: () async => 'private-test-token',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'id': 550,
            'title': '搏击俱乐部',
            'original_title': 'Fight Club',
            'overview': 'A movie overview',
            'poster_path': '/poster.jpg',
            'vote_average': 8.4,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(service.close);

    const sourceId = 'library-1';
    await database.upsertAssets([
      {
        'source_id': sourceId,
        'relative_path': 'Film {tmdbmovie-550}/film.mkv',
        'work_key': 'Film {tmdbmovie-550}',
        'name': 'film.mkv',
        'kind': 'video',
        'category': 'episode',
        'tmdb_id': 550,
        'tmdb_type': 'movie',
      },
    ]);
    await database.upsertPendingWork(
      sourceId: sourceId,
      workKey: 'Film {tmdbmovie-550}',
      tmdbId: 550,
      tmdbType: 'movie',
      title: 'Film',
    );

    expect(
      await service.scrapeWork(
        sourceId: sourceId,
        workKey: 'Film {tmdbmovie-550}',
        tmdbId: 550,
        type: 'movie',
      ),
      isTrue,
    );
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/3/movie/550');
    expect(requests.single.url.queryParameters['language'], 'zh-CN');
    expect(
        requests.single.headers['Authorization'], 'Bearer private-test-token');

    final work = (await database.getWorks(sourceId: sourceId)).single;
    expect(work['tmdb_id'], 550);
    expect(work['tmdb_type'], 'movie');
    expect(work['tmdb_movie_id'], 550);
    expect(work['tmdb_tv_id'], isNull);
    expect(work['title_cn'], '搏击俱乐部');
    expect(work['title'], 'Fight Club');
    expect(work['poster_url'], 'https://image.tmdb.org/t/p/w500/poster.jpg');
    expect(work['metadata_status'], 'matched');
    final synced = await database.exportSyncRecords();
    expect(jsonEncode(synced), isNot(contains('private-test-token')));
  });

  test('unknown TMDB type falls back from TV to movie details', () async {
    final requests = <http.Request>[];
    final service = TmdbMetadataService(
      tokenReader: () async => 'token',
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/3/tv/901') return http.Response('', 404);
        return http.Response(
          jsonEncode({
            'id': 901,
            'title': 'A movie',
            'original_title': 'A movie',
            'poster_path': '/movie.jpg'
          }),
          200,
        );
      }),
    );
    addTearDown(service.close);
    await database.upsertPendingWork(
      sourceId: 'library-2',
      workKey: 'Unknown',
      tmdbId: 901,
      tmdbType: 'unknown',
      title: 'Unknown',
    );

    expect(
      await service.scrapeWork(
        sourceId: 'library-2',
        workKey: 'Unknown',
        tmdbId: 901,
        type: 'unknown',
      ),
      isTrue,
    );
    expect(requests.map((request) => request.url.path), [
      '/3/tv/901',
      '/3/movie/901',
    ]);
    final work = (await database.getWorks(sourceId: 'library-2')).single;
    expect(work['tmdb_movie_id'], 901);
    expect(work['tmdb_tv_id'], isNull);
  });

  test('TMDB lookup stays local when no token is configured', () async {
    var requested = false;
    final service = TmdbMetadataService(
      tokenReader: () async => null,
      client: MockClient((_) async {
        requested = true;
        return http.Response('', 200);
      }),
    );
    addTearDown(service.close);
    expect(
      await service.scrapeWork(
        sourceId: 'library',
        workKey: 'Film',
        tmdbId: 42,
        type: 'movie',
      ),
      isFalse,
    );
    expect(requested, isFalse);
  });

  test('season lookup stores titles and stills and reuses the persisted cache',
      () async {
    await database.upsertTmdbWorkMetadata(
      sourceId: 'episode-library',
      workKey: 'Show',
      tmdbId: 123,
      tmdbType: 'tv',
      title: '作品',
      originalTitle: 'Show',
      overview: '',
      posterUrl: '/poster.jpg',
      rating: null,
      metadataJson: '{"backdrop_path":"/back.jpg"}',
    );
    final work = (await database.getWorks(sourceId: 'episode-library')).single;
    final requests = <http.Request>[];
    final service = TmdbMetadataService(
        tokenReader: () async => 'token',
        client: MockClient((request) async {
          requests.add(request);
          expect(request.url.path, '/3/tv/123/season/2');
          expect(request.url.queryParameters['language'], 'zh-CN');
          return http.Response(
              jsonEncode({
                'season_number': 2,
                'episodes': [
                  {
                    'episode_number': 1,
                    'name': '第二季第一集',
                    'still_path': '/still.jpg'
                  },
                ]
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    addTearDown(service.close);
    const assets = <Map<String, Object?>>[
      {
        'name': 'Show S02E01.mkv',
        'relative_path': 'Show/S02/Show S02E01.mkv',
        'category': 'episode',
        'episode_number': 1
      },
      {'name': 'NCOP.mkv', 'category': 'extra'},
    ];
    final seasons = await service.loadEpisodeSeasons(
        sourceId: 'episode-library', work: work, assets: assets);
    expect(seasons['2'][0]['name'], '第二季第一集');
    expect(seasons['2'][0]['still_path'], '/still.jpg');
    expect(
        await service.loadEpisodeSeasons(
            sourceId: 'episode-library', work: work, assets: assets),
        seasons);
    expect(requests, hasLength(1));
    final saved = (await database.getWorks(sourceId: 'episode-library')).single;
    final metadata = jsonDecode(saved['metadata_json'] as String);
    expect(metadata['backdrop_path'], '/back.jpg');
    expect(metadata['tmdb_episode_seasons']['2'][0]['name'], '第二季第一集');
  });

  test('manual rescrape uses the stored typed TMDB movie ID', () async {
    final service = _CapturingTmdbMetadataService();
    addTearDown(service.close);
    await database.upsertPendingWork(
      sourceId: 'library-manual-rescrape',
      workKey: 'A Movie',
      tmdbId: 880,
      tmdbType: 'movie',
      title: 'A Movie',
    );

    expect(
      await CloudMediaScraper(
        tmdbMetadataServiceFactory: () => service,
      ).rescrapeWork(
        sourceId: 'library-manual-rescrape',
        workKey: 'A Movie',
      ),
      isTrue,
    );
    expect(service.sourceId, 'library-manual-rescrape');
    expect(service.workKey, 'A Movie');
    expect(service.tmdbId, 880);
    expect(service.tmdbType, 'movie');
  });
}
