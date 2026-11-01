class CloudMediaScanResult {
  const CloudMediaScanResult({
    required this.rootPath,
    required this.assets,
    this.matchedWorks = 0,
    this.failedWorks = 0,
  });

  final String rootPath;
  final List<CloudMediaAsset> assets;
  final int matchedWorks;
  final int failedWorks;

  CloudMediaScanResult copyWith({int? matchedWorks, int? failedWorks}) =>
      CloudMediaScanResult(
        rootPath: rootPath,
        assets: assets,
        matchedWorks: matchedWorks ?? this.matchedWorks,
        failedWorks: failedWorks ?? this.failedWorks,
      );
}

class CloudMediaAsset {
  const CloudMediaAsset({
    required this.sourceId,
    required this.relativePath,
    required this.workKey,
    required this.name,
    required this.kind,
    required this.category,
    this.size,
    this.modified,
    this.tmdbId,
    this.episodeNumber,
  });

  final String sourceId;
  final String relativePath;
  final String workKey;
  final String name;
  final String kind;
  final String category;
  final int? size;
  final DateTime? modified;
  final int? tmdbId;
  final int? episodeNumber;
}
