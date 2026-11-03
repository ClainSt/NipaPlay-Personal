/// Removes provider-added credits that are not part of the source synopsis.
abstract final class AnimeTextSanitizer {
  static final RegExp _translationCredit = RegExp(
    r'\s*(?:[（(]\s*)?由\s*弹弹\s*play\s*AI\s*辅助翻译\s*(?:[)）])?\s*$',
    caseSensitive: false,
  );

  static String? cleanSummary(String? value) {
    if (value == null) return null;
    var result = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    result = result.replaceFirst(_translationCredit, '').trimRight();
    result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return result.trim();
  }
}
