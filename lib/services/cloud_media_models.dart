enum CloudTmdbType { unknown, tv, movie }

class CloudMediaScanResult {
  const CloudMediaScanResult({
    required this.rootPath,
    required this.assets,
    this.libraryId,
    this.matchedWorks = 0,
    this.failedWorks = 0,
    this.inventoryChanged = false,
    this.addedFiles = 0,
    this.removedFiles = 0,
    this.reusedWorks = 0,
  });

  final String rootPath;
  final List<CloudMediaAsset> assets;
  final String? libraryId;
  final int matchedWorks;
  final int failedWorks;
  final bool inventoryChanged;
  final int addedFiles;
  final int removedFiles;
  final int reusedWorks;

  CloudMediaScanResult copyWith({
    String? libraryId,
    int? matchedWorks,
    int? failedWorks,
    bool? inventoryChanged,
    int? addedFiles,
    int? removedFiles,
    int? reusedWorks,
  }) =>
      CloudMediaScanResult(
        rootPath: rootPath,
        assets: assets,
        libraryId: libraryId ?? this.libraryId,
        matchedWorks: matchedWorks ?? this.matchedWorks,
        failedWorks: failedWorks ?? this.failedWorks,
        inventoryChanged: inventoryChanged ?? this.inventoryChanged,
        addedFiles: addedFiles ?? this.addedFiles,
        removedFiles: removedFiles ?? this.removedFiles,
        reusedWorks: reusedWorks ?? this.reusedWorks,
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
    this.tmdbType = CloudTmdbType.unknown,
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
  final CloudTmdbType tmdbType;
  final int? episodeNumber;
}
