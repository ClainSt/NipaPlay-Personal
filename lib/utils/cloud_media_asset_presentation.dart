/// Filename tokens are used only for matching and short extra labels.
class CloudMediaAssetPresentation {
  static final _extraToken = RegExp(
    r'(^|[^a-z])(NCOPED|NCOP|NCED|MENU|OVA|OAD|PV|CM|SP|MV)(?:[ ._-]?(\d+(?:[ ._-]?[a-z])?))?(?=[^a-z0-9]|$)',
    caseSensitive: false,
  );

  static String? extraTitle(Map<String, Object?> asset) {
    final match = _extraToken.firstMatch(asset['name']?.toString() ?? '');
    if (match == null) return null;
    final number = (match.group(3) ?? '').replaceAll(RegExp(r'[ ._-]'), '');
    return '${match.group(2)}$number'.toUpperCase();
  }

  static String extraType(Map<String, Object?> asset) {
    final match = _extraToken.firstMatch(asset['name']?.toString() ?? '');
    if (match != null) return match.group(2)!.toUpperCase();
    final path = '${asset['relative_path'] ?? ''}'.replaceAll('\\', '/');
    if (RegExp(r'(^|/)menus?(/|$)', caseSensitive: false).hasMatch(path)) {
      return 'MENU';
    }
    return '其他';
  }

  static String category(Map<String, Object?> asset) =>
      extraType(asset) == 'MENU' ? 'extra' : '${asset['category']}';

  static int seasonNumber(Map<String, Object?> asset) {
    final explicit = int.tryParse('${asset['season_number'] ?? ''}');
    if (explicit != null) return explicit;
    final path = '${asset['relative_path'] ?? asset['name'] ?? ''}'
        .replaceAll('\\', '/');
    final episode =
        RegExp(r'\bS(\d{1,2})\s*E(?:P)?\s*\d+', caseSensitive: false)
            .firstMatch(path);
    if (episode != null) return int.parse(episode.group(1)!);
    final directory =
        RegExp(r'(?:^|/)(?:S|Season\s*)(\d{1,2})(?:/|$)', caseSensitive: false)
            .firstMatch(path);
    return int.tryParse(directory?.group(1) ?? '') ?? 1;
  }

  static Map? episode(
      Map<String, Object?> asset, Map<String, dynamic> seasons) {
    if (category(asset) != 'episode') return null;
    final entries = seasons['${seasonNumber(asset)}'];
    if (entries is! List) return null;
    final number = int.tryParse('${asset['episode_number'] ?? ''}');
    if (number == null) return null;
    for (final entry in entries.whereType<Map>()) {
      if (entry['episode_number'] == number) return entry;
    }
    return null;
  }
}
