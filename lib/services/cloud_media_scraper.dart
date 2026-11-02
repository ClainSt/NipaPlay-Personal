import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_models.dart';
import 'package:nipaplay/services/dandanplay_service.dart';
import 'package:nipaplay/services/bangumi_api_service.dart';
import 'package:nipaplay/services/tmdb_metadata_service.dart';
import 'package:nipaplay/utils/anime_info_parse.dart';
import 'package:nipaplay/utils/media_filename_parser.dart';
import 'package:path/path.dart' as p;
import 'package:nipaplay/utils/image_cache_manager.dart';

class CloudMediaScrapeResult {
  const CloudMediaScrapeResult({required this.matched, required this.failed});

  final int matched;
  final int failed;
}

/// Metadata-only scraper. It sends TMDB IDs to the existing NipaPlay metadata
/// provider and never receives a media path or opens a video file.
class CloudMediaScraper {
  CloudMediaScraper({
    TmdbMetadataService Function()? tmdbMetadataServiceFactory,
    Future<Map<String, dynamic>?> Function(int)? originalCoverLookup,
    Future<void> Function(String)? coverLoader,
  })  : _tmdbMetadataServiceFactory =
            tmdbMetadataServiceFactory ?? TmdbMetadataService.new,
        _originalCoverLookup = originalCoverLookup,
        _coverLoader = coverLoader;

  final Future<Map<String, dynamic>?> Function(int)? _originalCoverLookup;
  final Future<void> Function(String)? _coverLoader;

  final TmdbMetadataService Function() _tmdbMetadataServiceFactory;

  Future<bool> rescrapeWork({
    required String sourceId,
    required String workKey,
  }) async {
    final database = CloudMediaIndexDatabase.instance;
    final work = (await database.getWorks(sourceId: sourceId)).where(
      (entry) => entry['work_key'] == workKey,
    );
    if (work.isEmpty) return false;
    final record = work.first;
    final tmdbId = int.tryParse(
      (record['tmdb_tv_id'] ??
                  record['tmdb_movie_id'] ??
                  record['tmdb_unknown_id'] ??
                  record['tmdb_id'])
              ?.toString() ??
          '',
    );
    if (tmdbId == null || tmdbId <= 0) return false;

    if (await _restoreOriginalCover(sourceId, workKey, tmdbId,
        record['tmdb_type']?.toString() ?? 'unknown')) return true;

    final service = _tmdbMetadataServiceFactory();
    try {
      return await service.scrapeWork(
        sourceId: sourceId,
        workKey: workKey,
        tmdbId: tmdbId,
        type: record['tmdb_type']?.toString() ?? 'unknown',
      );
    } catch (_) {
      return false;
    } finally {
      service.close();
    }
  }

  Future<CloudMediaScrapeResult> scrape({
    required String sourceId,
    required List<CloudMediaAsset> assets,
    String? rootPath,
    void Function(
      int processed,
      int total,
      String workKey,
      int matched,
      int failed,
    )? onProgress,
  }) async {
    final works = <String, List<CloudMediaAsset>>{};
    for (final asset in assets) {
      works.putIfAbsent(asset.workKey, () => <CloudMediaAsset>[]).add(asset);
    }
    var matched = 0;
    var failed = 0;
    var processed = 0;
    final tmdbMetadata = _tmdbMetadataServiceFactory();
    try {
      for (final entry in works.entries) {
        final workKey = entry.key;
        try {
          final workAssets = entry.value;
          final identified = workAssets.where((asset) => asset.tmdbId != null);
          final idAsset = identified.isEmpty ? null : identified.first;
          final releaseYear = _releaseYear(workKey, rootPath: rootPath);
          final title = _fallbackTitle(workKey, workAssets, rootPath: rootPath);
          if (idAsset == null) {
            if (await _scrapeBangumiByTitle(
                  sourceId: sourceId,
                  workKey: workKey,
                  title: title,
                  assets: workAssets,
                  releaseYear: releaseYear,
                ) ||
                await _scrapeByTitle(
                  sourceId: sourceId,
                  workKey: workKey,
                  title: title,
                  assets: workAssets,
                )) {
              matched++;
            } else {
              await CloudMediaIndexDatabase.instance.upsertUnmatchedWork(
                sourceId: sourceId,
                workKey: workKey,
                title: title,
              );
              failed++;
            }
            continue;
          }
          final tmdbId = idAsset.tmdbId!;
          final tmdbType = idAsset.tmdbType.name;
          if (await _restoreOriginalCover(
              sourceId, workKey, tmdbId, tmdbType)) {
            matched++;
            continue;
          }
          await CloudMediaIndexDatabase.instance.upsertPendingWork(
            sourceId: sourceId,
            workKey: workKey,
            tmdbId: tmdbId,
            tmdbType: tmdbType,
            title: title,
          );
          // Prefer the poster associated with the explicit TMDB ID. This
          // avoids distributor-stamped artwork returned by Dandanplay when a
          // TMDB read token is configured. Dandanplay remains the fallback.
          if (await _scrapeTmdbFallback(
            tmdbMetadata,
            sourceId: sourceId,
            workKey: workKey,
            tmdbId: tmdbId,
            type: tmdbType,
          )) {
            final bangumiPosterApplied = await _applyBangumiPosterForTmdbId(
              sourceId: sourceId,
              workKey: workKey,
              tmdbId: tmdbId,
            );
            if (!bangumiPosterApplied) {
              await _scrapeBangumiByTitle(
                sourceId: sourceId,
                workKey: workKey,
                title: title,
                assets: workAssets,
                releaseYear: releaseYear,
                tmdbId: tmdbId,
                tmdbType: tmdbType,
              );
            }
            matched++;
            continue;
          }
          if (await _scrapeBangumiByTitle(
            sourceId: sourceId,
            workKey: workKey,
            title: title,
            assets: workAssets,
            releaseYear: releaseYear,
            tmdbId: tmdbId,
            tmdbType: tmdbType,
          )) {
            matched++;
            continue;
          }
          if (tmdbType == 'movie') {
            if (await _scrapeByTitle(
              sourceId: sourceId,
              workKey: workKey,
              title: title,
              assets: workAssets,
            )) {
              matched++;
            } else {
              failed++;
            }
            continue;
          }
          try {
            final response = await DandanplayService.getBangumiByTmdbId(tmdbId,
                requireUniqueMatch: true);
            final bangumi = response?['bangumi'];
            if (response == null || bangumi is! Map<String, dynamic>) {
              if (await _scrapeByTitle(
                sourceId: sourceId,
                workKey: workKey,
                title: title,
                assets: workAssets,
              )) {
                matched++;
              } else {
                failed++;
              }
              continue;
            }
            final anime = BangumiAnime.fromDandanplayDetail(bangumi);
            if (anime.id <= 0 || anime.name.trim().isEmpty) {
              if (await _scrapeByTitle(
                sourceId: sourceId,
                workKey: workKey,
                title: title,
                assets: workAssets,
              )) {
                matched++;
              } else {
                failed++;
              }
              continue;
            }
            if (!_isRemoteImage(anime.imageUrl) &&
                await _scrapeByTitle(
                  sourceId: sourceId,
                  workKey: workKey,
                  title: title,
                  assets: workAssets,
                )) {
              matched++;
              continue;
            }
            final bangumiPoster = await _fetchBangumiPoster(bangumi);
            final animeWithBangumiPoster = bangumiPoster == null
                ? anime
                : anime.copyWith(imageUrl: bangumiPoster);
            await CloudMediaIndexDatabase.instance.upsertWorkMetadata(
              sourceId: sourceId,
              workKey: workKey,
              tmdbId: tmdbId,
              tmdbType: 'tv',
              response: response,
              anime: animeWithBangumiPoster,
            );
            matched++;
          } catch (_) {
            if (await _scrapeByTitle(
              sourceId: sourceId,
              workKey: workKey,
              title: title,
              assets: workAssets,
            )) {
              matched++;
            } else {
              // Metadata failure does not discard already indexed media.
              failed++;
            }
          }
        } finally {
          processed++;
          onProgress?.call(processed, works.length, workKey, matched, failed);
        }
      }
    } finally {
      tmdbMetadata.close();
    }
    return CloudMediaScrapeResult(matched: matched, failed: failed);
  }

  Future<bool> _restoreOriginalCover(
      String sourceId, String workKey, int tmdbId, String type) async {
    if (type == 'movie') return false;
    final database = CloudMediaIndexDatabase.instance;
    final existing = (await database.getWorks(sourceId: sourceId))
        .where((w) => w['work_key'] == workKey);
    if (existing.isNotEmpty && existing.first['relation_locked'] == 1) {
      return true;
    }
    try {
      final response = await (_originalCoverLookup?.call(tmdbId) ??
          DandanplayService.getBangumiByTmdbId(tmdbId,
              requireUniqueMatch: true));
      final details = response?['bangumi'];
      if (details is! Map<String, dynamic>) return false;
      final anime = BangumiAnime.fromDandanplayDetail(details);
      if (anime.id <= 0 || !_isRemoteImage(anime.imageUrl)) return false;
      // Use the same download, decoding and persistent cache as the poster
      // widget. Do not publish an unverified URL over an existing good cover.
      if (_coverLoader != null) {
        await _coverLoader(anime.imageUrl);
      } else {
        final cache = ImageCacheManager.instance;
        await cache.loadImage(anime.imageUrl);
        cache.releaseImage(anime.imageUrl);
      }
      await database.upsertWorkMetadata(
          sourceId: sourceId,
          workKey: workKey,
          tmdbId: tmdbId,
          tmdbType: 'tv',
          response: response!,
          anime: anime);
      debugPrint('[CloudMediaScraper] TMDB $tmdbId -> 弹弹play ${anime.id}: '
          '封面解码及缓存成功，域名 ${Uri.parse(anime.imageUrl).host}');
      return true;
    } catch (_) {
      debugPrint('[CloudMediaScraper] TMDB $tmdbId 原版封面链路失败，保留现有记录');
      return existing.isNotEmpty &&
          _isRemoteImage(existing.first['poster_url']?.toString());
    }
  }

  Future<bool> _scrapeByTitle({
    required String sourceId,
    required String workKey,
    required String title,
    required List<CloudMediaAsset> assets,
  }) async {
    try {
      final queries = <String>{};
      // Prefer clean work/folder names over release filenames. The folder is
      // often the best available title, while filenames may start with a
      // fansub group or contain codec/release tags that hurt search ranking.
      _addTitleQueryVariants(queries, title);
      for (final asset in assets.where((asset) => asset.kind == 'video')) {
        final query = MediaFilenameParser.extractAnimeSearchKeyword(
          asset.name,
          episodeNumber: asset.episodeNumber,
        );
        _addTitleQueryVariants(queries, query);
        if (queries.length >= 8) break;
      }
      for (final query in queries) {
        final candidates = await DandanplayService.searchAnime(query);
        for (final candidate in candidates) {
          final animeId = int.tryParse(candidate['animeId']?.toString() ?? '');
          if (animeId == null || animeId <= 0) continue;
          final response = await DandanplayService.getBangumiDetails(animeId);
          final details = response['bangumi'];
          if (response['success'] != true || details is! Map<String, dynamic>) {
            final intro = BangumiAnime.fromDandanplayIntro(candidate);
            if (intro.id > 0 && _isRemoteImage(intro.imageUrl)) {
              final bangumiPoster = await _fetchBangumiPoster(candidate);
              await CloudMediaIndexDatabase.instance
                  .upsertDandanplayWorkMetadata(
                sourceId: sourceId,
                workKey: workKey,
                response: {'success': true, 'bangumi': candidate},
                anime: bangumiPoster == null
                    ? intro
                    : intro.copyWith(imageUrl: bangumiPoster),
              );
              return true;
            }
            continue;
          }
          var anime = BangumiAnime.fromDandanplayDetail(details);
          if (anime.id <= 0 || anime.name.trim().isEmpty) continue;
          final searchPoster = candidate['imageUrl']?.toString().trim();
          if (!_isRemoteImage(anime.imageUrl) && _isRemoteImage(searchPoster)) {
            anime = anime.copyWith(imageUrl: searchPoster);
          }
          final bangumiPoster = await _fetchBangumiPoster(details);
          if (bangumiPoster != null) {
            anime = anime.copyWith(imageUrl: bangumiPoster);
          }
          await CloudMediaIndexDatabase.instance.upsertDandanplayWorkMetadata(
            sourceId: sourceId,
            workKey: workKey,
            response: response,
            anime: anime,
          );
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _scrapeBangumiByTitle({
    required String sourceId,
    required String workKey,
    required String title,
    required List<CloudMediaAsset> assets,
    String? releaseYear,
    int? tmdbId,
    String tmdbType = 'unknown',
  }) async {
    try {
      final queries = <String>{};
      _addTitleQueryVariants(queries, title);
      for (final asset in assets.where((asset) => asset.kind == 'video')) {
        _addTitleQueryVariants(
          queries,
          MediaFilenameParser.extractAnimeSearchKeyword(
            asset.name,
            episodeNumber: asset.episodeNumber,
          ),
        );
        if (queries.length >= 6) break;
      }

      for (final query in queries) {
        List<Map<String, dynamic>> candidates;
        try {
          candidates = await BangumiApiService.searchPublicAnimeSubjects(query);
        } catch (error) {
          debugPrint('[CloudMediaScraper] Bangumi 搜索失败（$query）: $error');
          continue;
        }
        for (final candidate in candidates) {
          final candidateNames = [
            candidate['name_cn']?.toString() ?? '',
            candidate['name']?.toString() ?? '',
          ].where((name) => name.trim().isNotEmpty);
          if (!candidateNames.any((name) => _titlesMatch(query, name))) {
            continue;
          }
          final subjectId = int.tryParse(candidate['id']?.toString() ?? '');
          if (subjectId == null || subjectId <= 0) continue;
          Map<String, dynamic> subject;
          try {
            subject = await BangumiApiService.getPublicSubject(subjectId)
                .timeout(const Duration(seconds: 8));
          } catch (error) {
            debugPrint(
              '[CloudMediaScraper] 获取 Bangumi 条目 $subjectId 失败: $error',
            );
            continue;
          }
          final subjectDate = subject['date']?.toString() ?? '';
          if (releaseYear != null &&
              subjectDate.length >= 4 &&
              subjectDate.substring(0, 4) != releaseYear) {
            continue;
          }
          final infoboxTmdbId = int.tryParse(
            (AnimeInfoParse.getInfoboxValue(
                      subject,
                      (key) => key.toLowerCase().contains('tmdb'),
                    ) ??
                    '')
                .replaceAll(RegExp(r'[^0-9]'), ''),
          );
          if (tmdbId != null &&
              infoboxTmdbId != null &&
              infoboxTmdbId != tmdbId) {
            continue;
          }

          final images = subject['images'] is Map
              ? subject['images'] as Map
              : candidate['images'] is Map
                  ? candidate['images'] as Map
                  : const <Object?, Object?>{};
          String? posterUrl;
          for (final key in const [
            'large',
            'common',
            'medium',
            'small',
            'grid'
          ]) {
            final value = images[key]?.toString().trim();
            if (_isRemoteImage(value)) {
              posterUrl = value;
              break;
            }
          }
          if (posterUrl == null) continue;

          final ratingValue = subject['rating'] is Map
              ? (subject['rating'] as Map)['score']
              : null;
          final subjectName = subject['name']?.toString().trim() ?? '';
          final subjectNameCn = subject['name_cn']?.toString().trim() ?? '';
          await CloudMediaIndexDatabase.instance.upsertBangumiWorkMetadata(
            sourceId: sourceId,
            workKey: workKey,
            bangumiId: subjectId,
            title: subjectName.isEmpty ? title : subjectName,
            titleCn: subjectNameCn.isEmpty
                ? (subjectName.isEmpty ? title : subjectName)
                : subjectNameCn,
            overview: subject['summary']?.toString() ?? '',
            posterUrl: posterUrl,
            metadataJson: jsonEncode(subject),
            tmdbId: tmdbId,
            tmdbType: tmdbType,
            rating: double.tryParse(ratingValue?.toString() ?? ''),
          );
          return true;
        }
      }
    } catch (error) {
      debugPrint('[CloudMediaScraper] Bangumi 刮削失败（$title）: $error');
      // The existing Dandanplay matcher remains the next fallback.
    }
    return false;
  }

  bool _titlesMatch(String query, String candidate) {
    String normalize(String value) => value
        .toLowerCase()
        .replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), '')
        .replaceAll(RegExp(r'[\s\-_—–:：.()（）\[\]【】{}!?！？・·,，、]'), '');

    final normalizedQuery = normalize(query);
    final normalizedCandidate = normalize(candidate);
    if (normalizedQuery.length < 3 || normalizedCandidate.isEmpty) return false;
    return normalizedQuery == normalizedCandidate ||
        normalizedCandidate.contains(normalizedQuery) ||
        normalizedQuery.contains(normalizedCandidate);
  }

  void _addTitleQueryVariants(Set<String> queries, String value) {
    final normalized = value
        .replaceAll(RegExp(r'\[[^\]]*\]|\{[^}]*\}'), ' ')
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return;

    // Keep the release year in the first query: it helps distinguish works
    // with similar names. A year-free variant is only a fallback.
    queries.add(normalized);
    final withoutYear = normalized
        .replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}\s*\)'), ' ')
        .replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (withoutYear.isNotEmpty && withoutYear != normalized) {
      queries.add(withoutYear);
    }
    final withoutLeadingNumber = withoutYear
        .replaceFirst(
          RegExp(r'^\s*\d{1,4}\s*[-:：._、 ]+'),
          '',
        )
        .replaceAll(RegExp(r'^[\s\-–—:：]+|[\s\-–—:：]+$'), '')
        .trim();
    if (withoutLeadingNumber.isNotEmpty && withoutLeadingNumber != normalized) {
      queries.add(withoutLeadingNumber);
    }
    if (queries.length > 8) {
      final retained = queries.take(8).toList();
      queries
        ..clear()
        ..addAll(retained);
    }
  }

  bool _isRemoteImage(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  Future<bool> _scrapeTmdbFallback(
    TmdbMetadataService service, {
    required String sourceId,
    required String workKey,
    required int tmdbId,
    required String type,
  }) async {
    try {
      return await service.scrapeWork(
        sourceId: sourceId,
        workKey: workKey,
        tmdbId: tmdbId,
        type: type,
      );
    } catch (error) {
      debugPrint('[CloudMediaScraper][TMDB] ID $tmdbId 请求异常: $error');
      return false;
    }
  }

  Future<bool> _applyBangumiPosterForTmdbId({
    required String sourceId,
    required String workKey,
    required int tmdbId,
  }) async {
    try {
      final response = await DandanplayService.getBangumiByTmdbId(tmdbId,
          requireUniqueMatch: true);
      final bangumi = response?['bangumi'];
      if (bangumi is! Map) return false;
      final poster = await _fetchBangumiPoster(
        Map<String, dynamic>.from(bangumi),
      );
      if (poster == null) return false;
      final bangumiId = AnimeInfoParse.getBangumiTvId(
        Map<String, dynamic>.from(bangumi),
      );
      await CloudMediaIndexDatabase.instance.updateWorkPoster(
        sourceId: sourceId,
        workKey: workKey,
        posterUrl: poster,
        bangumiId: bangumiId,
      );
      return true;
    } catch (_) {
      // Keep the TMDB poster if the Bangumi lookup is unavailable.
      return false;
    }
  }

  Future<String?> _fetchBangumiPoster(Map<String, dynamic> bangumi) async {
    try {
      final bangumiId = AnimeInfoParse.getBangumiTvId(bangumi);
      if (bangumiId == null) return null;
      final subject = await BangumiApiService.getPublicSubject(bangumiId);
      final images = subject['images'];
      if (images is! Map) return null;
      for (final key in const ['large', 'common', 'medium', 'small', 'grid']) {
        final imageUrl = images[key]?.toString().trim();
        if (_isRemoteImage(imageUrl)) return imageUrl;
      }
    } catch (_) {
      // Cover lookup is optional; preserve the metadata provider's image.
    }
    return null;
  }

  String _fallbackTitle(
    String workKey,
    List<CloudMediaAsset> assets, {
    String? rootPath,
  }) {
    var title = workKey;
    if (workKey != '.') {
      title = workKey;
    } else if (rootPath?.trim().isNotEmpty == true) {
      final normalized = rootPath!.replaceAll('\\', '/').replaceFirst(
            RegExp(r'/+$'),
            '',
          );
      title = normalized.split('/').last;
    }
    title = title
        .replaceAll(
          RegExp(r'\{\s*\[?\s*tmdb(?:id|tv|movie)?\s*[-=:].*?[\]}]',
              caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'[\[\]{}()]'), '')
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'(?<!\d)(?:19|20)\d{2}(?!\d)'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (title.isNotEmpty && title != '.') return title;
    final filename = assets.isEmpty ? 'Unknown title' : assets.first.name;
    return p.basenameWithoutExtension(filename);
  }

  String? _releaseYear(String workKey, {String? rootPath}) {
    final source = workKey == '.' ? (rootPath ?? '') : workKey;
    return RegExp(r'(?<!\d)(?:19|20)\d{2}(?!\d)').firstMatch(source)?.group(0);
  }
}
