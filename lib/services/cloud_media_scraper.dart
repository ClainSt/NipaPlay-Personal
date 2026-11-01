import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_models.dart';
import 'package:nipaplay/services/dandanplay_service.dart';

class CloudMediaScrapeResult {
  const CloudMediaScrapeResult({required this.matched, required this.failed});

  final int matched;
  final int failed;
}

/// Metadata-only scraper. It sends TMDB IDs to the existing NipaPlay metadata
/// provider and never receives a media path or opens a video file.
class CloudMediaScraper {
  Future<CloudMediaScrapeResult> scrape({
    required String sourceId,
    required List<CloudMediaAsset> assets,
  }) async {
    final works = <(String, int)>{
      for (final asset in assets)
        if (asset.tmdbId != null) (asset.workKey, asset.tmdbId!),
    };
    var matched = 0;
    var failed = 0;
    for (final (workKey, tmdbId) in works) {
      await CloudMediaIndexDatabase.instance.upsertPendingWork(
        sourceId: sourceId,
        workKey: workKey,
        tmdbId: tmdbId,
        title: _fallbackTitle(workKey, assets),
      );
      try {
        final response = await DandanplayService.getBangumiByTmdbId(tmdbId);
        final bangumi = response?['bangumi'];
        if (response == null || bangumi is! Map<String, dynamic>) {
          failed++;
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
          response: response,
          anime: anime,
        );
        matched++;
      } catch (_) {
        // Metadata failure does not discard the already indexed media assets.
        failed++;
      }
    }
    return CloudMediaScrapeResult(matched: matched, failed: failed);
  }

  String _fallbackTitle(String workKey, List<CloudMediaAsset> assets) {
    if (workKey != '.') {
      return workKey
          .replaceAll(
            RegExp(r'\{\s*\[?\s*tmdb(?:id)?\s*[-=:].*?[\]}]',
                caseSensitive: false),
            '',
          )
          .replaceAll(RegExp(r'[\[\]{}()]'), '')
          .replaceAll(RegExp(r'[._]+'), ' ')
          .trim();
    }
    final filename = assets.isEmpty ? 'Unknown title' : assets.first.name;
    final extension = filename.lastIndexOf('.');
    return extension < 0 ? filename : filename.substring(0, extension);
  }
}
