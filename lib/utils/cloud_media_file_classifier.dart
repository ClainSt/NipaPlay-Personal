/// Conservative filename classification shared by scans and old index repair.
abstract final class CloudMediaFileClassifier {
  static String classifyAsset(String directory, String name, String kind) {
    final path = directory.replaceAll('\\', '/').toLowerCase();
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
      RegExp(r'\b(?:EP?|Episode)[ ._-]*(\d{1,3})(?:v\d+)?\b',
          caseSensitive: false),
      RegExp(r'第\s*(\d{1,3})\s*[话話集]'),
      RegExp(r'\[(\d{1,3})(?:v\d+)?(?:\]|[ ._])', caseSensitive: false),
      RegExp(r'(?:^|[ ._])[-–—][ ._]*(\d{1,3})(?:v\d+)?(?=[ ._\[(]|$)',
          caseSensitive: false),
      RegExp(r'^(\d{1,3})(?:v\d+)?(?=[ ._\[(]|$)', caseSensitive: false),
      RegExp(r'[（(](\d{1,3})(?:v\d+)?[)）]', caseSensitive: false),
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
}
