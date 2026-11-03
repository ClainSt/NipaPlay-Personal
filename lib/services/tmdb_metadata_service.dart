import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/utils/cloud_media_asset_presentation.dart';

/// Fetches TMDB metadata without ever putting the user's token in the catalog
/// snapshot. The token stays in the platform's secure local storage.
class TmdbMetadataService {
  TmdbMetadataService({
    http.Client? client,
    Future<String?> Function()? tokenReader,
  })  : _client = client ?? http.Client(),
        _tokenReader = tokenReader ?? _readStoredToken;

  static const _tokenKey = 'cloud_media_tmdb_read_access_token';
  static const _specialMappingVersion = 3;
  static const _storage = FlutterSecureStorage();
  static Future<bool>? _hasTokenCache;
  final http.Client _client;
  final Future<String?> Function() _tokenReader;

  static Future<String?> _readStoredToken() => _storage.read(key: _tokenKey);

  static Future<void> saveReadAccessToken(String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      await _storage.delete(key: _tokenKey);
    } else {
      await _storage.write(key: _tokenKey, value: normalized);
    }
    _hasTokenCache = Future.value(normalized.isNotEmpty);
  }

  static Future<bool> hasReadAccessToken() => _hasTokenCache ??=
      _readStoredToken().then((token) => token?.trim().isNotEmpty == true);

  Future<bool> scrapeWork({
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required String type,
  }) async {
    final token = (await _tokenReader())?.trim();
    if (token == null || token.isEmpty) {
      debugPrint(
        '[CloudMediaScraper][TMDB] 跳过 ID $tmdbId：本设备未配置 TMDB API 凭据',
      );
      return false;
    }

    // TMDB v3 accepts either an API Read Access Token as Bearer auth or the
    // legacy 32-character API key as the api_key query parameter. Accept both
    // because users commonly copy either credential from their TMDB account.
    final isV3ApiKey = RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(token);

    final types = switch (type) {
      'tv' => const ['tv'],
      'movie' => const ['movie'],
      _ => const ['tv', 'movie'],
    };
    for (final candidateType in types) {
      final query = <String, String>{'language': 'zh-CN'};
      if (isV3ApiKey) query['api_key'] = token;
      final headers = <String, String>{'Accept': 'application/json'};
      if (!isV3ApiKey) headers['Authorization'] = 'Bearer $token';
      final response = await _client
          .get(
            Uri.https(
              'api.themoviedb.org',
              '/3/$candidateType/$tmdbId',
              query,
            ),
            headers: headers,
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 404 && type == 'unknown') continue;
      if (response.statusCode != 200) {
        final body = utf8.decode(response.bodyBytes, allowMalformed: true);
        debugPrint(
          '[CloudMediaScraper][TMDB] ID $tmdbId ($candidateType) 请求失败：'
          'HTTP ${response.statusCode}${body.isEmpty ? '' : ' - ${body.substring(0, body.length > 240 ? 240 : body.length)}'}',
        );
        return false;
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> ||
          int.tryParse(decoded['id']?.toString() ?? '') != tmdbId) {
        debugPrint('[CloudMediaScraper][TMDB] ID $tmdbId 响应 ID 不一致');
        return false;
      }
      final title =
          (candidateType == 'movie' ? decoded['title'] : decoded['name'])
              ?.toString()
              .trim();
      if (title == null || title.isEmpty) {
        debugPrint('[CloudMediaScraper][TMDB] ID $tmdbId 没有可用标题');
        return false;
      }
      final posterPath = decoded['poster_path']?.toString();
      if (posterPath == null || posterPath.trim().isEmpty) {
        debugPrint(
          '[CloudMediaScraper][TMDB] ID $tmdbId ($candidateType) 没有海报，继续尝试其他来源',
        );
        return false;
      }
      final overview = decoded['overview']?.toString() ?? '';
      final rating = num.tryParse(decoded['vote_average']?.toString() ?? '');
      await CloudMediaIndexDatabase.instance.upsertTmdbWorkMetadata(
        sourceId: sourceId,
        workKey: workKey,
        tmdbId: tmdbId,
        tmdbType: candidateType,
        title: title,
        originalTitle: (candidateType == 'movie'
                    ? decoded['original_title']
                    : decoded['original_name'])
                ?.toString() ??
            title,
        overview: overview,
        posterUrl: 'https://image.tmdb.org/t/p/w500$posterPath',
        rating: rating?.toDouble(),
        metadataJson: jsonEncode(decoded),
      );
      return true;
    }
    debugPrint('[CloudMediaScraper][TMDB] ID $tmdbId 未找到对应的 $types 条目');
    return false;
  }

  /// Loads seasons represented by playable episodes and TMDB specials when
  /// OVA/OAD/SP files exist. Failed requests are not cached, so opening the
  /// detail again can retry without a library scan.
  Future<Map<String, dynamic>> loadEpisodeSeasons({
    required String sourceId,
    required Map<String, Object?> work,
    required List<Map<String, Object?>> assets,
  }) async {
    assets = assets
        .map((asset) => <String, Object?>{
              'work_key': work['work_key'],
              'work_title': work['title_cn'] ?? work['title'],
              ...asset,
            })
        .toList();
    final seasons = <String, dynamic>{};
    try {
      final metadata = jsonDecode(work['metadata_json']?.toString() ?? '{}');
      if (metadata is Map && metadata['tmdb_episode_seasons'] is Map) {
        seasons.addAll(
            Map<String, dynamic>.from(metadata['tmdb_episode_seasons']));
      }
    } catch (_) {/* Missing metadata can be fetched below. */}
    final id = int.tryParse(
        '${work['tmdb_tv_id'] ?? (work['tmdb_type'] == 'tv' ? work['tmdb_id'] : '')}');
    if (id == null) return seasons;
    // The parent catalog may still hold the work snapshot from before the last
    // visit. Read the persisted cache before requesting the same season again.
    final works =
        await CloudMediaIndexDatabase.instance.getWorks(sourceId: sourceId);
    for (final saved in works) {
      if (saved['work_key'] != work['work_key'] || saved['tmdb_tv_id'] != id) {
        continue;
      }
      try {
        final metadata = jsonDecode(saved['metadata_json']?.toString() ?? '{}');
        if (metadata is Map && metadata['tmdb_episode_seasons'] is Map) {
          seasons.addAll(
              Map<String, dynamic>.from(metadata['tmdb_episode_seasons']));
        }
      } catch (_) {/* A malformed cache can be fetched again. */}
    }
    final specialAssets = assets
        .where(CloudMediaAssetPresentation.isSpecialMappingCandidate)
        .toList(growable: false);
    final previousSpecialMapping = seasons.containsKey('special_assets')
        ? jsonEncode(seasons['special_assets'])
        : null;

    void attachSpecialMapping() {
      if (specialAssets.isEmpty || seasons['0'] is! List) return;
      final specials = (seasons['0'] as List)
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList(growable: false);
      seasons['special_assets'] =
          CloudMediaAssetPresentation.mapSpecialEpisodes(
        assets: assets,
        specials: specials,
        yearHint: work['work_key']?.toString(),
      );
    }

    attachSpecialMapping();
    final currentSpecialMapping = seasons.containsKey('special_assets')
        ? jsonEncode(seasons['special_assets'])
        : null;
    final mappingNeedsCache = currentSpecialMapping != null &&
        currentSpecialMapping != previousSpecialMapping;
    final needed = <int>{
      ...assets
          .where((a) =>
              CloudMediaAssetPresentation.category(a) == 'episode' &&
              a['episode_number'] != null)
          .map((asset) => CloudMediaAssetPresentation.seasonNumber({
                'work_key': work['work_key'],
                'work_title': work['title_cn'] ?? work['title'],
                ...asset,
              }))
          .where((s) => !seasons.containsKey('$s')),
      if (specialAssets.isNotEmpty && !seasons.containsKey('0')) 0,
      if (specialAssets.isNotEmpty &&
          seasons['special_mapping_version'] != _specialMappingVersion)
        0,
    };
    final token = (await _tokenReader())?.trim();
    if (token == null || token.isEmpty) {
      if (mappingNeedsCache) {
        await CloudMediaIndexDatabase.instance.cacheTmdbEpisodeSeasons(
          sourceId: sourceId,
          workKey: work['work_key']?.toString() ?? '.',
          tmdbId: id,
          seasons: {
            'special_assets': seasons['special_assets'],
          },
        );
      }
      return seasons;
    }
    final apiKey = RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(token);
    final fetched = <String, dynamic>{};
    Future<void> fetchSeasons(Set<int> requested) async {
      for (final season in requested) {
        try {
          final response = await _client.get(
            Uri.https('api.themoviedb.org', '/3/tv/$id/season/$season', {
              'language': 'zh-CN',
              if (apiKey) 'api_key': token,
            }),
            headers: {
              'Accept': 'application/json',
              if (!apiKey) 'Authorization': 'Bearer $token',
            },
          ).timeout(const Duration(seconds: 15));
          if (response.statusCode != 200) continue;
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is! Map ||
              decoded['season_number'] != season ||
              decoded['episodes'] is! List) {
            continue;
          }
          fetched['$season'] = (decoded['episodes'] as List)
              .whereType<Map>()
              .map((e) => {
                    'episode_number': e['episode_number'],
                    'name': e['name'],
                    'still_path': e['still_path'],
                    'air_date': e['air_date'],
                  })
              .toList();
        } catch (_) {
          debugPrint('[TMDB] 第 $season 季剧集信息暂时不可用');
        }
      }
    }

    await fetchSeasons(needed);
    seasons.addAll(fetched);
    final unseasoned = assets
        .where((asset) =>
            CloudMediaAssetPresentation.category(asset) == 'episode' &&
            CloudMediaAssetPresentation.explicitSeasonNumber(asset) == null &&
            (int.tryParse('${asset['episode_number']}') ?? 0) > 0)
        .toList();
    // A cached season 1 must not prevent later absolute episodes from loading.
    if (seasons['1'] is List &&
        seasons['season_episode_counts'] is! Map &&
        unseasoned.any((asset) =>
            CloudMediaAssetPresentation.episode(asset, seasons) == null)) {
      try {
        final response = await _client.get(
          Uri.https('api.themoviedb.org', '/3/tv/$id', {
            'language': 'zh-CN',
            if (apiKey) 'api_key': token,
          }),
          headers: {
            'Accept': 'application/json',
            if (!apiKey) 'Authorization': 'Bearer $token'
          },
        ).timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final details = jsonDecode(utf8.decode(response.bodyBytes));
          if (details is Map &&
              details['id'] == id &&
              details['seasons'] is List) {
            final counts = <String, int>{};
            for (final season
                in (details['seasons'] as List).whereType<Map>()) {
              final number = int.tryParse('${season['season_number']}');
              final count = int.tryParse('${season['episode_count']}');
              if (number != null && number > 0 && count != null && count > 0) {
                counts['$number'] = count;
              }
            }
            if (counts.containsKey('1')) {
              seasons['season_episode_counts'] = counts;
              fetched['season_episode_counts'] = counts;
            }
          }
        }
      } catch (_) {
        debugPrint('[TMDB] 连续集号的季度信息暂时不可用');
      }
    }
    final additional = <int>{};
    for (final asset in unseasoned) {
      final coordinates =
          CloudMediaAssetPresentation.episodeCoordinates(asset, seasons);
      if (coordinates != null &&
          !needed.contains(coordinates.season) &&
          !seasons.containsKey('${coordinates.season}')) {
        additional.add(coordinates.season);
      }
    }
    await fetchSeasons(additional);
    seasons.addAll(fetched);
    attachSpecialMapping();
    if (specialAssets.isNotEmpty && fetched.containsKey('0')) {
      fetched['special_mapping_version'] = _specialMappingVersion;
    }
    if (specialAssets.isNotEmpty && seasons.containsKey('special_assets')) {
      fetched['special_assets'] = seasons['special_assets'];
    }
    if (fetched.isNotEmpty) {
      await CloudMediaIndexDatabase.instance.cacheTmdbEpisodeSeasons(
        sourceId: sourceId,
        workKey: work['work_key']?.toString() ?? '.',
        tmdbId: id,
        seasons: fetched,
      );
    }
    return seasons;
  }

  /// Returns a landscape image for a movie or TV work. The images endpoint
  /// supplies both movie thumbnails and the wide artwork used by the detail
  /// page background. Only the URL is cached.
  Future<String?> loadWorkArtwork({
    required String sourceId,
    required Map<String, Object?> work,
  }) async {
    final movieId = int.tryParse('${work['tmdb_movie_id'] ?? ''}');
    final tvId = int.tryParse('${work['tmdb_tv_id'] ?? ''}');
    final tmdbType = tvId != null
        ? 'tv'
        : movieId != null
            ? 'movie'
            : work['tmdb_type']?.toString();
    final id = tvId ??
        movieId ??
        int.tryParse(
          '${work['tmdb_id'] ?? ''}',
        );
    if (id == null || (tmdbType != 'tv' && tmdbType != 'movie')) return null;

    Map<String, dynamic> metadata = {};
    try {
      final decoded = jsonDecode(work['metadata_json']?.toString() ?? '{}');
      if (decoded is Map) metadata = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    final cached = metadata['tmdb_${tmdbType}_artwork'];
    if (cached is Map) {
      final url = cached['backdrop_url']?.toString().trim();
      if (cached['version'] == 1 && url?.isNotEmpty == true) return url;
    }
    final cachedBackdrop = metadata['backdrop_url']?.toString().trim();
    if (cachedBackdrop?.isNotEmpty == true) return cachedBackdrop;
    final path = metadata['backdrop_path']?.toString().trim();
    if (path?.isNotEmpty == true) {
      return 'https://image.tmdb.org/t/p/w780$path';
    }

    final token = (await _tokenReader())?.trim();
    if (token == null || token.isEmpty) return null;
    final apiKey = RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(token);
    final response = await _client.get(
      Uri.https('api.themoviedb.org', '/3/$tmdbType/$id/images', {
        'include_image_language': 'zh,ja,en,null',
        if (apiKey) 'api_key': token,
      }),
      headers: {
        'Accept': 'application/json',
        if (!apiKey) 'Authorization': 'Bearer $token',
      },
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['backdrops'] is! List) return null;
    final backdrops = (decoded['backdrops'] as List).whereType<Map>().toList();
    if (backdrops.isEmpty) return null;
    backdrops.sort((a, b) {
      final score = (num.tryParse('${b['vote_average']}') ?? 0)
          .compareTo(num.tryParse('${a['vote_average']}') ?? 0);
      if (score != 0) return score;
      return (num.tryParse('${b['width']}') ?? 0)
          .compareTo(num.tryParse('${a['width']}') ?? 0);
    });
    final artworkPath = backdrops.first['file_path']?.toString().trim();
    if (artworkPath == null || artworkPath.isEmpty) return null;
    final url = 'https://image.tmdb.org/t/p/w780$artworkPath';
    await CloudMediaIndexDatabase.instance.cacheTmdbWorkArtwork(
      sourceId: sourceId,
      workKey: work['work_key']?.toString() ?? '.',
      tmdbId: id,
      tmdbType: tmdbType!,
      artworkUrl: url,
    );
    return url;
  }

  /// Backwards-compatible movie-only wrapper.
  Future<String?> loadMovieArtwork({
    required String sourceId,
    required Map<String, Object?> work,
  }) async {
    if (work['tmdb_movie_id'] == null && work['tmdb_type'] != 'movie') {
      return null;
    }
    return loadWorkArtwork(sourceId: sourceId, work: work);
  }

  void close() => _client.close();
}
