import 'dart:async';
import 'dart:io' as io;

import 'package:path/path.dart' as p;
import 'package:nipaplay/services/webdav_service.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_scraper.dart';
import 'package:nipaplay/services/cloud_media_models.dart';
import 'package:nipaplay/services/auto_sync_service.dart';
import 'package:nipaplay/services/cloud_media_scan_progress.dart';

export 'package:nipaplay/services/cloud_media_models.dart';

/// Read-only WebDAV catalog scan. It only enumerates directories via PROPFIND;
/// it never opens media files or requests video byte ranges.
class CloudMediaScanner {
  CloudMediaScanner({WebDAVService? webDav})
      : _webDav = webDav ?? WebDAVService.instance;

  final WebDAVService _webDav;

  static const videoExtensions = <String>{
    'mkv',
    'mp4',
    'avi',
    'mov',
    'wmv',
    'flv',
    'webm',
    'm4v',
    'ts',
    'm2ts',
  };

  static const _deferredDirectoryNames = {'cd', 'cds', 'scan', 'scans'};

  /// CD audio and scans are deferred features; don't recurse into them during
  /// video library scans (some WebDAV servers also reject these directories).
  static bool isDeferredDirectory(String name) =>
      _deferredDirectoryNames.contains(name.trim().toLowerCase());

  Future<CloudMediaScanResult> scan({
    required WebDAVConnection connection,
    required String rootPath,
    String? sourceId,
    bool recursive = true,
    void Function(int directoriesVisited)? onProgress,
    void Function(int directoriesVisited, int videosFound)? onDetailedProgress,
  }) async {
    final root = _normalize(rootPath);
    final pending = <String>[root];
    final visited = <String>{};
    final files = <CloudMediaAsset>[];
    var videosFound = 0;
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      if (!visited.add(directory)) continue;
      // listDirectoryAll is PROPFIND metadata listing; do not replace with GET.
      final entries = await _listDirectoryWithTransientRetry(
        connection,
        directory,
      );
      onProgress?.call(visited.length);
      for (final entry in entries) {
        if (entry.isDirectory) {
          if (recursive && !isDeferredDirectory(entry.name)) {
            pending.add(_normalize(entry.path));
          }
          continue;
        }
        final kind = _kind(entry.name);
        if (kind == null) continue;
        if (kind == 'video') videosFound++;
        files.add(
          CloudMediaAsset(
            sourceId: sourceId ?? connection.id,
            relativePath: _relativeToRoot(root, entry.path),
            workKey: _workKey(root, directory),
            name: entry.name,
            size: entry.size,
            modified: entry.lastModified,
            kind: kind,
            tmdbId: parseTmdbId('$root/$directory'),
            tmdbType: parseTmdbType('$root/$directory'),
            category: classifyAsset(directory, entry.name, kind),
            episodeNumber: episodeNumberFromName(entry.name),
          ),
        );
      }
      onDetailedProgress?.call(visited.length, videosFound);
    }
    return CloudMediaScanResult(
      rootPath: root,
      assets: List.unmodifiable(files),
    );
  }

  Future<List<WebDAVFile>> _listDirectoryWithTransientRetry(
    WebDAVConnection connection,
    String directory,
  ) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _webDav.listDirectoryAll(
          connection,
          directory,
          forceRefresh: true,
        );
      } catch (error) {
        final message = error.toString().toLowerCase();
        final transient = message.contains('broken pipe') ||
            message.contains('connection reset') ||
            message.contains('socketexception') ||
            message.contains('connectionerror');
        if (!transient || attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
  }

  Future<CloudMediaScanResult> scanAndIndex({
    required WebDAVConnection connection,
    required String rootPath,
    bool recursive = true,
    void Function(int directoriesVisited)? onProgress,
  }) async {
    final progress = CloudMediaScanProgress.instance;
    progress.start(source: 'WebDAV', rootPath: rootPath);
    try {
      final database = CloudMediaIndexDatabase.instance;
      final libraryId = await database.ensureLibraryRoot(
        connectionId: connection.id,
        rootPath: rootPath,
      );
      final result = await scan(
        connection: connection,
        rootPath: rootPath,
        sourceId: libraryId,
        recursive: recursive,
        onProgress: onProgress,
        onDetailedProgress: (directoriesVisited, videosFound) {
          progress.updateListing(
            directoriesVisited: directoriesVisited,
            videosFound: videosFound,
          );
        },
      );
      progress.updateIndexing(
        filesIndexed: 0,
        totalFiles: result.assets.length,
      );
      final indexedResult = await _indexAssets(
        libraryId,
        result,
        onScrapeProgress: (processed, total, workKey, matched, failed) {
          progress.updateMatching(
            processed: processed,
            total: total,
            currentWork: workKey,
            matched: matched,
            failed: failed,
          );
        },
      );
      final videoCount =
          result.assets.where((asset) => asset.kind == 'video').length;
      progress.complete(
        message: videoCount == 0
            ? '扫描完成：未找到可展示的视频文件'
            : '扫描完成：发现 $videoCount 个视频，匹配 ${indexedResult.matchedWorks} 部作品'
                '${indexedResult.failedWorks == 0 ? '' : '，${indexedResult.failedWorks} 部待确认'}',
        directoriesVisited: progress.directoriesVisited,
        videosFound: videoCount,
        matchedWorks: indexedResult.matchedWorks,
        failedWorks: indexedResult.failedWorks,
        totalFiles: result.assets.length,
      );
      return indexedResult;
    } catch (error) {
      progress.fail(error);
      rethrow;
    }
  }

  /// Local counterpart of [scanAndIndex]. It stats directory entries only and
  /// never opens the video files.
  Future<CloudMediaScanResult> scanLocalAndIndex({
    required String rootPath,
    bool recursive = true,
    void Function(int directoriesVisited)? onProgress,
  }) async {
    final root = p.normalize(p.absolute(rootPath));
    final rootDirectory = io.Directory(root);
    if (!await rootDirectory.exists()) {
      throw io.FileSystemException('媒体库目录不存在', root);
    }
    final connectionId = 'local:$root';
    final database = CloudMediaIndexDatabase.instance;
    final libraryId = await database.ensureLibraryRoot(
      connectionId: connectionId,
      rootPath: root,
    );
    final pending = <String>[root];
    final visited = <String>{};
    final assets = <CloudMediaAsset>[];
    while (pending.isNotEmpty) {
      final directoryPath = pending.removeLast();
      if (!visited.add(directoryPath)) continue;
      final directory = io.Directory(directoryPath);
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is io.Directory) {
          if (recursive && !isDeferredDirectory(p.basename(entity.path))) {
            pending.add(entity.path);
          }
          continue;
        }
        if (entity is! io.File) continue;
        final name = p.basename(entity.path);
        final kind = _kind(name);
        if (kind == null) continue;
        final stat = await entity.stat();
        final relativePath = p.relative(entity.path, from: root);
        final relativeDirectory = p.dirname(relativePath);
        final normalizedDirectory = relativeDirectory == '.'
            ? ''
            : relativeDirectory.replaceAll('\\', '/');
        assets.add(CloudMediaAsset(
          sourceId: libraryId,
          relativePath: relativePath.replaceAll('\\', '/'),
          workKey: _workKey(root, p.join(root, relativeDirectory)),
          name: name,
          size: stat.size,
          modified: stat.modified,
          kind: kind,
          category: classifyAsset('/$normalizedDirectory', name, kind),
          tmdbId: parseTmdbId('$root/$normalizedDirectory'),
          tmdbType: parseTmdbType('$root/$normalizedDirectory'),
          episodeNumber: episodeNumberFromName(name),
        ));
      }
      onProgress?.call(visited.length);
    }
    return _indexAssets(
      libraryId,
      CloudMediaScanResult(rootPath: root, assets: List.unmodifiable(assets)),
    );
  }

  Future<CloudMediaScanResult> _indexAssets(
      String libraryId, CloudMediaScanResult result,
      {void Function(int processed, int total, String workKey, int matched,
              int failed)?
          onScrapeProgress}) async {
    final database = CloudMediaIndexDatabase.instance;
    await database.upsertAssets(
      result.assets
          .map(
            (asset) => {
              'source_id': asset.sourceId,
              'relative_path': asset.relativePath,
              'work_key': asset.workKey,
              'name': asset.name,
              'kind': asset.kind,
              'category': asset.category,
              'episode_number': asset.episodeNumber,
              'size': asset.size,
              'modified_at': asset.modified?.toUtc().toIso8601String(),
              'tmdb_id': asset.tmdbId,
              'tmdb_type': asset.tmdbType.name,
            },
          )
          .toList(),
    );
    if (result.assets.isNotEmpty) {
      CloudMediaScanProgress.instance.updateIndexing(
        filesIndexed: result.assets.length,
        totalFiles: result.assets.length,
      );
    }
    await database.removeMissingAssets(
      sourceId: libraryId,
      seenRelativePaths:
          result.assets.map((asset) => asset.relativePath).toSet(),
    );
    await database.markLibraryRootScanned(libraryId);
    final scrapeResult = await CloudMediaScraper().scrape(
      sourceId: libraryId,
      rootPath: result.rootPath,
      assets: result.assets,
      onProgress: onScrapeProgress,
    );
    await database.removeOrphanedWorks(libraryId);
    unawaited(AutoSyncService.instance.scheduleSyncAfterCatalogChange());
    return result.copyWith(
      libraryId: libraryId,
      matchedWorks: scrapeResult.matched,
      failedWorks: scrapeResult.failed,
    );
  }

  static String? _kind(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    if (videoExtensions.contains(ext)) return 'video';
    if (ext == 'nfo') return 'nfo';
    return null;
  }

  static int? parseTmdbId(String path) {
    final patterns = <RegExp>[
      RegExp(r'\{\s*tmdbtv\s*[-=:]\s*(\d+)\s*\}', caseSensitive: false),
      RegExp(r'\{\s*tmdbmovie\s*[-=:]\s*(\d+)\s*\}', caseSensitive: false),
      RegExp(r'\{\s*tmdb\s*[-=:]\s*(\d+)\s*\}', caseSensitive: false),
      RegExp(r'\{\s*tmdbid\s*[-=:]\s*(\d+)\s*\}', caseSensitive: false),
      RegExp(r'\[\s*tmdb\s*[-=:]\s*(\d+)\s*\]', caseSensitive: false),
      RegExp(
        r'\{\s*\[\s*tmdbid\s*=\s*(\d+)[^\]]*\]\s*\}',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(path);
      final id = int.tryParse(match?.group(1) ?? '');
      if (id != null && id > 0) return id;
    }
    return null;
  }

  static CloudTmdbType parseTmdbType(String path) {
    final lower = path.toLowerCase();
    if (RegExp(r'tmdbmovie\s*[-=:]|type\s*=\s*(movie|film)').hasMatch(lower)) {
      return CloudTmdbType.movie;
    }
    if (RegExp(r'tmdbtv\s*[-=:]|type\s*=\s*tv').hasMatch(lower)) {
      return CloudTmdbType.tv;
    }
    return CloudTmdbType.unknown;
  }

  static String classifyAsset(String directory, String name, String kind) {
    final path = directory.toLowerCase();
    final lower = name.toLowerCase();
    final segments = path.split('/').where((segment) => segment.isNotEmpty);
    if (segments.any(
      (segment) => const {'sp', 'sps', 'specials', 'extras', 'menu', 'menus'}
          .contains(segment),
    )) {
      return 'extra';
    }
    if (RegExp(
      r'(^|[^a-z])(ncoped|ncop|nced|menu|pv|cm|ova|oad|sp|mv|visual commentary)([^a-z]|$)',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return 'extra';
    }
    if (kind == 'video' && episodeNumberFromName(name) != null) {
      return 'episode';
    }
    return kind == 'video' ? 'review' : 'metadata';
  }

  static int? episodeNumberFromName(String name) {
    final patterns = <RegExp>[
      RegExp(r'\bS\d{1,2}\s*E(P)?\s*(\d{1,3})\b', caseSensitive: false),
      RegExp(r'\bEP\s*(\d{1,3})\b', caseSensitive: false),
      RegExp(r'第\s*(\d{1,3})\s*[话話集]'),
      RegExp(r'\[(\d{1,3})(?:v\d+)?\]'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(name);
      final capture = pattern.pattern.startsWith(r'\bS')
          ? match?.group(2)
          : match?.group(1);
      final number = int.tryParse(capture ?? '');
      if (number != null && number > 0) return number;
    }
    return null;
  }

  static String _workKey(String root, String directory) {
    final normalizedRoot = root.replaceAll('\\', '/');
    final relativeDirectory = _relativeToRoot(
      normalizedRoot,
      directory.replaceAll('\\', '/'),
    );
    // A user may select a single work folder (often named with a TMDB ID)
    // instead of its parent library directory. Root and season files belong
    // to that work in this case.
    if (parseTmdbId(normalizedRoot) != null) {
      return normalizedRoot.split('/').where((part) => part.isNotEmpty).last;
    }
    if (relativeDirectory.isEmpty) return '.';
    final firstSegment = relativeDirectory.split('/').first;
    // When a user chooses the series folder itself as the library root, a
    // season/special subdirectory is still part of that root work.
    if (RegExp(
      r'^(?:s\d{1,2}|season\s*\d{1,2}|sp|sps|specials|extras)$',
      caseSensitive: false,
    ).hasMatch(firstSegment.trim())) {
      return '.';
    }
    return firstSegment;
  }

  static String _normalize(String path) {
    var value = path.trim().replaceAll('\\', '/');
    if (!value.startsWith('/')) value = '/$value';
    value = value.replaceAll(RegExp(r'/+'), '/');
    if (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static String _relativeToRoot(String root, String path) {
    final normalizedPath = _normalize(path);
    if (normalizedPath == root) return '';
    return normalizedPath.startsWith('$root/')
        ? normalizedPath.substring(root.length + 1)
        : normalizedPath.replaceFirst(RegExp(r'^/'), '');
  }
}
