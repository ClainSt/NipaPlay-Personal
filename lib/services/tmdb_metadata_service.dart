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

  /// Loads only seasons represented by playable episodes. Failed requests are
  /// not cached, so opening the detail again can retry without a library scan.
  Future<Map<String, dynamic>> loadEpisodeSeasons({
    required String sourceId,
    required Map<String, Object?> work,
    required List<Map<String, Object?>> assets,
  }) async {
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
    final needed = assets
        .where((a) =>
            CloudMediaAssetPresentation.category(a) == 'episode' &&
            a['episode_number'] != null)
        .map(CloudMediaAssetPresentation.seasonNumber)
        .toSet()
        .where((s) => !seasons.containsKey('$s'));
    if (needed.isEmpty) return seasons;
    final token = (await _tokenReader())?.trim();
    if (token == null || token.isEmpty) return seasons;
    final apiKey = RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(token);
    final fetched = <String, dynamic>{};
    for (final season in needed) {
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
                })
            .toList();
      } catch (_) {
        debugPrint('[TMDB] 第 $season 季剧集信息暂时不可用');
      }
    }
    seasons.addAll(fetched);
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

  void close() => _client.close();
}
