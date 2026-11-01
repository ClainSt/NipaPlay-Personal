import 'package:nipaplay/services/webdav_service.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';

/// Read-only WebDAV catalog scan. It only enumerates directories via PROPFIND;
/// it never opens media files or requests video byte ranges.
class CloudMediaScanner {
  CloudMediaScanner({WebDAVService? webDav}) : _webDav = webDav ?? WebDAVService.instance;

  final WebDAVService _webDav;

  static const videoExtensions = <String>{
    'mkv', 'mp4', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'ts', 'm2ts',
  };
  static const audioExtensions = <String>{'flac', 'mp3', 'wav', 'm4a', 'aac', 'ogg'};
  static const imageExtensions = <String>{'jpg', 'jpeg', 'png', 'webp'};

  Future<CloudMediaScanResult> scan({
    required WebDAVConnection connection,
    required String rootPath,
    bool recursive = true,
    void Function(int directoriesVisited)? onProgress,
  }) async {
    final root = _normalize(rootPath);
    final pending = <String>[root];
    final visited = <String>{};
    final files = <CloudMediaAsset>[];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      if (!visited.add(directory)) continue;
      // listDirectoryAll is PROPFIND metadata listing; do not replace with GET.
      final entries = await _webDav.listDirectoryAll(
        connection,
        directory,
        forceRefresh: true,
      );
      onProgress?.call(visited.length);
      for (final entry in entries) {
        if (entry.isDirectory) {
          if (recursive) pending.add(_normalize(entry.path));
          continue;
        }
        final kind = _kind(entry.name);
        if (kind == null) continue;
        files.add(CloudMediaAsset(
          sourceId: connection.id,
          relativePath: _relativeToRoot(root, entry.path),
          workKey: _workKey(root, directory),
          name: entry.name,
          size: entry.size,
          modified: entry.lastModified,
          kind: kind,
          tmdbId: _tmdbIdFromPath('$root/$directory'),
          category: _category(directory, entry.name, kind),
          episodeNumber: _episodeNumber(entry.name),
        ));
      }
    }
    return CloudMediaScanResult(rootPath: root, assets: List.unmodifiable(files));
  }

  Future<CloudMediaScanResult> scanAndIndex({
    required WebDAVConnection connection,
    required String rootPath,
    bool recursive = true,
    void Function(int directoriesVisited)? onProgress,
  }) async {
    final result = await scan(
      connection: connection,
      rootPath: rootPath,
      recursive: recursive,
      onProgress: onProgress,
    );
    await CloudMediaIndexDatabase.instance.upsertAssets(result.assets.map((asset) => {
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
        }).toList());
    return result;
  }

  static String? _kind(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    if (videoExtensions.contains(ext)) return 'video';
    if (audioExtensions.contains(ext)) return 'audio';
    if (imageExtensions.contains(ext)) return 'image';
    if (ext == 'cue') return 'cue';
    if (ext == 'nfo') return 'nfo';
    return null;
  }

  static int? _tmdbIdFromPath(String path) {
    final patterns = <RegExp>[
      RegExp(r'\{\s*tmdb\s*[-=:]\s*(\d+)\s*\}', caseSensitive: false),
      RegExp(r'\{\s*tmdbid\s*[-=:]\s*(\d+)\s*\}', caseSensitive: false),
      RegExp(r'\[\s*tmdb\s*[-=:]\s*(\d+)\s*\]', caseSensitive: false),
      RegExp(r'\{\s*\[\s*tmdbid\s*=\s*(\d+)[^\]]*\]\s*\}', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(path);
      final id = int.tryParse(match?.group(1) ?? '');
      if (id != null && id > 0) return id;
    }
    return null;
  }

  static String _category(String directory, String name, String kind) {
    final path = directory.toLowerCase();
    final lower = name.toLowerCase();
    final segments = path.split('/').where((segment) => segment.isNotEmpty);
    if (segments.any((segment) => segment == 'cds' || segment == 'ost')) return 'cd';
    if (segments.any((segment) => segment == 'scans' || segment == 'booklet')) return 'scan';
    if (segments.any((segment) => const {'sp', 'sps', 'specials', 'extras'}.contains(segment))) return 'extra';
    if (kind == 'audio') return 'cd';
    if (kind == 'image') return 'scan';
    if (RegExp(r'(^|[^a-z])(ncop|nced|pv|cm|ova|oad|sp|mv|visual commentary)([^a-z]|$)', caseSensitive: false).hasMatch(lower)) return 'extra';
    if (kind == 'video' && _episodeNumber(name) != null) return 'episode';
    return kind == 'video' ? 'review' : 'metadata';
  }

  static int? _episodeNumber(String name) {
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
    final relativeDirectory = _relativeToRoot(root, directory);
    if (relativeDirectory.isEmpty) return '.';
    return relativeDirectory.split('/').first;
  }

  static String _normalize(String path) {
    var value = path.trim().replaceAll('\\', '/');
    if (!value.startsWith('/')) value = '/$value';
    return value.replaceAll(RegExp(r'/+'), '/').replaceFirst(RegExp(r'/$'), '');
  }

  static String _relativeToRoot(String root, String path) {
    final normalizedPath = _normalize(path);
    if (normalizedPath == root) return '';
    return normalizedPath.startsWith('$root/')
        ? normalizedPath.substring(root.length + 1)
        : normalizedPath.replaceFirst(RegExp(r'^/'), '');
  }
}

class CloudMediaScanResult {
  const CloudMediaScanResult({required this.rootPath, required this.assets});
  final String rootPath;
  final List<CloudMediaAsset> assets;
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
