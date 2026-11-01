import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'package:nipaplay/services/cloud_media_index_database.dart';

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
    if (token == null || token.isEmpty) return false;

    final types = switch (type) {
      'tv' => const ['tv'],
      'movie' => const ['movie'],
      _ => const ['tv', 'movie'],
    };
    for (final candidateType in types) {
      final response = await _client.get(
        Uri.https('api.themoviedb.org', '/3/$candidateType/$tmdbId', {
          'language': 'zh-CN',
        }),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );
      if (response.statusCode == 404 && type == 'unknown') continue;
      if (response.statusCode != 200) return false;

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> ||
          int.tryParse(decoded['id']?.toString() ?? '') != tmdbId) {
        return false;
      }
      final title =
          (candidateType == 'movie' ? decoded['title'] : decoded['name'])
              ?.toString()
              .trim();
      if (title == null || title.isEmpty) return false;
      final posterPath = decoded['poster_path']?.toString();
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
        posterUrl: posterPath == null || posterPath.isEmpty
            ? null
            : 'https://image.tmdb.org/t/p/w500$posterPath',
        rating: rating?.toDouble(),
        metadataJson: jsonEncode(decoded),
      );
      return true;
    }
    return false;
  }

  void close() => _client.close();
}
