import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_scraper.dart';
import 'package:nipaplay/services/tmdb_metadata_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:nipaplay/utils/cloud_media_asset_presentation.dart';

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

  test('original cover is verified before its independent IDs are saved',
      () async {
    await database.upsertPendingWork(
        sourceId: 'original-cover',
        workKey: 'Show',
        tmdbId: 1234,
        tmdbType: 'tv',
        title: 'Show');
    var verified = false;
    final scraper = CloudMediaScraper(
      originalCoverLookup: (id) async {
        expect(id, 1234);
        return {
          'success': true,
          'bangumi': {
            'animeId': 5678,
            'animeTitle': 'Show',
            'imageUrl': 'https://images.example/cover.jpg'
          }
        };
      },
      coverLoader: (url) async {
        expect(url, 'https://images.example/cover.jpg');
        final before =
            (await database.getWorks(sourceId: 'original-cover')).single;
        expect(before['dandanplay_anime_id'], isNull);
        verified = true;
      },
    );
    expect(
        await scraper.rescrapeWork(sourceId: 'original-cover', workKey: 'Show'),
        isTrue);
    expect(verified, isTrue);
    final saved = (await database.getWorks(sourceId: 'original-cover')).single;
    expect(saved['tmdb_tv_id'], 1234);
    expect(saved['dandanplay_anime_id'], 5678);
    expect(saved['poster_url'], 'https://images.example/cover.jpg');
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

  test(
      'cached season one discovers absolute episodes 13 to 24 and caches season two',
      () async {
    final first = [
      for (var i = 1; i <= 12; i++) {'episode_number': i, 'name': 'First $i'}
    ];
    await database.upsertTmdbWorkMetadata(
        sourceId: 'absolute',
        workKey: '3D Kanojo',
        tmdbId: 999,
        tmdbType: 'tv',
        title: '3D彼女',
        originalTitle: '3D Kanojo',
        overview: '',
        posterUrl: '/poster.jpg',
        rating: null,
        metadataJson: jsonEncode({
          'tmdb_episode_seasons': {'1': first}
        }));
    final work = (await database.getWorks(sourceId: 'absolute')).single;
    final requests = <String>[];
    var failSeasonTwo = true;
    final service = TmdbMetadataService(
        tokenReader: () async => 'token',
        client: MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path == '/3/tv/999') {
            return http.Response(
                jsonEncode({
                  'id': 999,
                  'seasons': [
                    {'season_number': 0, 'episode_count': 5},
                    {'season_number': 1, 'episode_count': 12},
                    {'season_number': 2, 'episode_count': 12},
                  ]
                }),
                200);
          }
          expect(request.url.path, '/3/tv/999/season/2');
          if (failSeasonTwo) return http.Response('', 503);
          return http.Response(
              jsonEncode({
                'season_number': 2,
                'episodes': [
                  for (var i = 1; i <= 12; i++)
                    {
                      'episode_number': i,
                      'name': 'Second $i',
                      'still_path': '/second$i.jpg'
                    }
                ]
              }),
              200);
        }));
    addTearDown(service.close);
    final assets = <Map<String, Object?>>[
      for (var i = 1; i <= 24; i++)
        {
          'category': 'episode',
          'name': i == 13
              ? '[Moozzi2] 3D Kanojo Real Girl - 13 (BD 1920x1080 x.264 Flac).mkv'
              : '3D Kanojo [$i].mkv',
          'episode_number': i
        }
    ];
    final failed = await service.loadEpisodeSeasons(
        sourceId: 'absolute', work: work, assets: assets);
    expect(failed.containsKey('2'), isFalse);
    failSeasonTwo = false;
    final seasons = await service.loadEpisodeSeasons(
        sourceId: 'absolute', work: work, assets: assets);
    expect(
        CloudMediaAssetPresentation.episode(assets[12], seasons)?['still_path'],
        '/second1.jpg');
    expect(CloudMediaAssetPresentation.episode(assets[23], seasons)?['name'],
        'Second 12');
    final cached = await service.loadEpisodeSeasons(
        sourceId: 'absolute', work: work, assets: assets);
    expect(cached, seasons);
    expect(requests, ['/3/tv/999', '/3/tv/999/season/2', '/3/tv/999/season/2']);
  });

  test('movie artwork lookup caches a landscape TMDB backdrop', () async {
    await database.upsertTmdbWorkMetadata(
      sourceId: 'movie-artwork-library',
      workKey: 'Movie',
      tmdbId: 532067,
      tmdbType: 'movie',
      title: 'Movie',
      originalTitle: 'Movie',
      overview: '',
      posterUrl: '/poster.jpg',
      rating: null,
      metadataJson: '{}',
    );
    final work =
        (await database.getWorks(sourceId: 'movie-artwork-library')).single;
    final requests = <http.Request>[];
    final service = TmdbMetadataService(
      tokenReader: () async => 'secret-token',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'backdrops': [
              {
                'file_path': '/low.jpg',
                'vote_average': 5,
                'width': 1280,
              },
              {
                'file_path': '/best.jpg',
                'vote_average': 8,
                'width': 1920,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(service.close);

    final first = await service.loadMovieArtwork(
      sourceId: 'movie-artwork-library',
      work: work,
    );
    expect(first, 'https://image.tmdb.org/t/p/w780/best.jpg');
    expect(requests.single.url.path, '/3/movie/532067/images');

    final saved =
        (await database.getWorks(sourceId: 'movie-artwork-library')).single;
    final savedWork = await service.loadMovieArtwork(
      sourceId: 'movie-artwork-library',
      work: saved,
    );
    expect(savedWork, first);
    expect(requests, hasLength(1));
    final metadata = jsonDecode(saved['metadata_json'] as String);
    expect(
      metadata['tmdb_movie_artwork']['backdrop_url'],
      'https://image.tmdb.org/t/p/w780/best.jpg',
    );
  });

  test('TV artwork lookup caches the detail-page background', () async {
    await database.upsertTmdbWorkMetadata(
      sourceId: 'tv-artwork-library',
      workKey: 'TV Show',
      tmdbId: 65844,
      tmdbType: 'tv',
      title: 'TV Show',
      originalTitle: 'TV Show',
      overview: '',
      posterUrl: '/poster.jpg',
      rating: null,
      metadataJson: '{}',
    );
    final work =
        (await database.getWorks(sourceId: 'tv-artwork-library')).single;
    final requests = <http.Request>[];
    final service = TmdbMetadataService(
      tokenReader: () async => 'secret-token',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'backdrops': [
              {
                'file_path': '/tv-backdrop.jpg',
                'vote_average': 9,
                'width': 1920,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(service.close);

    final artwork = await service.loadWorkArtwork(
      sourceId: 'tv-artwork-library',
      work: work,
    );
    expect(artwork, 'https://image.tmdb.org/t/p/w780/tv-backdrop.jpg');
    expect(requests.single.url.path, '/3/tv/65844/images');
    final saved =
        (await database.getWorks(sourceId: 'tv-artwork-library')).single;
    final metadata = jsonDecode(saved['metadata_json'] as String);
    expect(
      metadata['tmdb_tv_artwork']['backdrop_url'],
      'https://image.tmdb.org/t/p/w780/tv-backdrop.jpg',
    );
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

  test('high-resolution mapped cover replaces the Dandanplay thumbnail',
      () async {
    await database.upsertPendingWork(
      sourceId: 'high-resolution-cover',
      workKey: 'Show',
      tmdbId: 4321,
      tmdbType: 'tv',
      title: 'Show',
    );
    final loaded = <String>[];
    final scraper = CloudMediaScraper(
      originalCoverLookup: (_) async => {
        'success': true,
        'bangumi': {
          'animeId': 9876,
          'animeTitle': 'Show',
          'imageUrl':
              'https://assets.anixplayer.net/image/poster/medium/show.jpg',
          'bangumiUrl': 'https://bangumi.tv/subject/123',
        },
      },
      highResolutionCoverLookup: (_) async =>
          'https://lain.bgm.tv/pic/cover/l/show.jpg',
      coverLoader: (url) async => loaded.add(url),
    );

    expect(
      await scraper.rescrapeWork(
        sourceId: 'high-resolution-cover',
        workKey: 'Show',
      ),
      isTrue,
    );
    expect(loaded, ['https://lain.bgm.tv/pic/cover/l/show.jpg']);
    final saved =
        (await database.getWorks(sourceId: 'high-resolution-cover')).single;
    expect(saved['poster_url'], 'https://lain.bgm.tv/pic/cover/l/show.jpg');
  });

  test('legacy medium Dandanplay covers upgrade without a full rescrape',
      () async {
    const sourceId = 'legacy-medium-cover';
    await database.upsertPendingWork(
      sourceId: sourceId,
      workKey: 'Show',
      tmdbId: 777,
      tmdbType: 'tv',
      title: 'Show',
    );
    final db = await database.database;
    await db.update(
      'cloud_media_work',
      {
        'poster_url':
            'https://assets.anixplayer.net/image/poster/medium/show.jpg',
        'metadata_json': jsonEncode({
          'bangumi': {
            'animeId': 888,
            'animeTitle': 'Show',
            'bangumiUrl': 'https://bangumi.tv/subject/123',
          },
        }),
      },
      where: 'source_id = ? AND work_key = ?',
      whereArgs: [sourceId, 'Show'],
    );
    final loaded = <String>[];
    final scraper = CloudMediaScraper(
      highResolutionCoverLookup: (_) async =>
          'https://lain.bgm.tv/pic/cover/l/show.jpg',
      coverLoader: (url) async => loaded.add(url),
    );

    expect(
      await scraper.upgradeLegacyDandanplayCovers(sourceId: sourceId),
      1,
    );
    expect(loaded, ['https://lain.bgm.tv/pic/cover/l/show.jpg']);
    final saved = (await database.getWorks(sourceId: sourceId)).single;
    expect(saved['poster_url'], 'https://lain.bgm.tv/pic/cover/l/show.jpg');
  });

  test('OVA assets fetch season zero and persist the special mapping',
      () async {
    const sourceId = 'ova-special-library';
    await database.upsertTmdbWorkMetadata(
      sourceId: sourceId,
      workKey: 'Show (2024) {tmdb-321}',
      tmdbId: 321,
      tmdbType: 'tv',
      title: '作品',
      originalTitle: 'Show',
      overview: '',
      posterUrl: '/poster.jpg',
      rating: null,
      metadataJson: '{}',
    );
    final work = (await database.getWorks(sourceId: sourceId)).single;
    final requests = <http.Request>[];
    final service = TmdbMetadataService(
      tokenReader: () async => 'token',
      client: MockClient((request) async {
        requests.add(request);
        expect(request.url.path, '/3/tv/321/season/0');
        return http.Response(
          jsonEncode({
            'season_number': 0,
            'episodes': [
              {
                'episode_number': 1,
                'name': 'OVA 1: First Special',
                'still_path': '/ova-one.jpg',
                'air_date': '2024-03-01',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(service.close);
    const assets = <Map<String, Object?>>[
      {
        'name': 'Show OVA.mkv',
        'relative_path': 'Show/Show OVA.mkv',
        'category': 'extra',
      },
    ];

    final seasons = await service.loadEpisodeSeasons(
      sourceId: sourceId,
      work: work,
      assets: assets,
    );
    expect(requests, hasLength(1));
    expect(seasons['0'][0]['name'], 'OVA 1: First Special');
    expect(
      seasons['special_assets']['Show/Show OVA.mkv']['name'],
      'OVA 1: First Special',
    );
    expect(
      CloudMediaAssetPresentation.specialEpisode(
          assets.single, seasons)?['still_path'],
      '/ova-one.jpg',
    );
    expect(seasons['special_mapping_version'], isNull);

    final saved = (await database.getWorks(sourceId: sourceId)).single;
    final metadata = jsonDecode(saved['metadata_json'] as String);
    expect(
      metadata['tmdb_episode_seasons']['special_assets']['Show/Show OVA.mkv']
          ['episode_number'],
      1,
    );
    expect(metadata['tmdb_episode_seasons']['special_mapping_version'], 3);
  });
}
