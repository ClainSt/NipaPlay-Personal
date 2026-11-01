import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_models.dart';
import 'package:nipaplay/services/dandanplay_service.dart';
import 'package:nipaplay/services/tmdb_metadata_service.dart';
import 'package:path/path.dart' as p;

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
  }) : _tmdbMetadataServiceFactory =
            tmdbMetadataServiceFactory ?? TmdbMetadataService.new;

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
  }) async {
    final works = <String, List<CloudMediaAsset>>{};
    for (final asset in assets) {
      works.putIfAbsent(asset.workKey, () => <CloudMediaAsset>[]).add(asset);
    }
    var matched = 0;
    var failed = 0;
    final tmdbMetadata = _tmdbMetadataServiceFactory();
    for (final entry in works.entries) {
      final workKey = entry.key;
      final workAssets = entry.value;
      final identified = workAssets.where((asset) => asset.tmdbId != null);
      final idAsset = identified.isEmpty ? null : identified.first;
      final title = _fallbackTitle(workKey, workAssets, rootPath: rootPath);
      if (idAsset == null) {
        // Keep non-ID folders visible and editable instead of leaving their
        // assets stranded outside the work catalog.
        await CloudMediaIndexDatabase.instance.upsertUnmatchedWork(
          sourceId: sourceId,
          workKey: workKey,
          title: title,
        );
        failed++;
        continue;
      }
      final tmdbId = idAsset.tmdbId!;
      final tmdbType = idAsset.tmdbType.name;
      await CloudMediaIndexDatabase.instance.upsertPendingWork(
        sourceId: sourceId,
        workKey: workKey,
        tmdbId: tmdbId,
        tmdbType: tmdbType,
        title: title,
      );
      if (tmdbType == 'movie') {
        if (await _scrapeTmdbFallback(
          tmdbMetadata,
          sourceId: sourceId,
          workKey: workKey,
          tmdbId: tmdbId,
          type: tmdbType,
        )) {
          matched++;
        } else {
          failed++;
        }
        continue;
      }
      try {
        final response = await DandanplayService.getBangumiByTmdbId(tmdbId);
        final bangumi = response?['bangumi'];
        if (response == null || bangumi is! Map<String, dynamic>) {
          if (await _scrapeTmdbFallback(
            tmdbMetadata,
            sourceId: sourceId,
            workKey: workKey,
            tmdbId: tmdbId,
            type: tmdbType,
          )) {
            matched++;
          } else {
            failed++;
          }
          continue;
        }
        final anime = BangumiAnime.fromDandanplayDetail(bangumi);
        if (anime.id <= 0 || anime.name.trim().isEmpty) {
          failed++;
          continue;
        }
        await CloudMediaIndexDatabase.instance.upsertWorkMetadata(
          sourceId: sourceId,
          workKey: workKey,
          tmdbId: tmdbId,
          tmdbType: 'tv',
          response: response,
          anime: anime,
        );
        matched++;
      } catch (_) {
        if (await _scrapeTmdbFallback(
          tmdbMetadata,
          sourceId: sourceId,
          workKey: workKey,
          tmdbId: tmdbId,
          type: tmdbType,
        )) {
          matched++;
        } else {
          // Metadata failure does not discard the already indexed media assets.
          failed++;
        }
      }
    }
    tmdbMetadata.close();
    return CloudMediaScrapeResult(matched: matched, failed: failed);
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
    } catch (_) {
      return false;
    }
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
        .trim();
    if (title.isNotEmpty && title != '.') return title;
    final filename = assets.isEmpty ? 'Unknown title' : assets.first.name;
    return p.basenameWithoutExtension(filename);
  }
}
