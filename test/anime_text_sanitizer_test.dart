import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/utils/anime_text_sanitizer.dart';

void main() {
  test('provider translation credits are removed from synopsis endings', () {
    const summary = '简介正文。\r\n\r\n(由 弹弹play AI 辅助翻译)';
    expect(AnimeTextSanitizer.cleanSummary(summary), '简介正文。');
    expect(
      AnimeTextSanitizer.cleanSummary('另一段正文。\n（由弹弹play AI辅助翻译）'),
      '另一段正文。',
    );
    expect(
      AnimeTextSanitizer.cleanSummary('正文。  由 弹弹 play AI 辅助翻译'),
      '正文。',
    );
    expect(AnimeTextSanitizer.cleanSummary(null), isNull);
  });

  test('Dandanplay detail parsing stores the cleaned synopsis', () {
    final anime = BangumiAnime.fromDandanplayDetail({
      'animeId': 17802,
      'animeTitle': '16bit的感动 ANOTHER LAYER',
      'imageUrl': 'https://example.com/cover.jpg',
      'summary': '简介正文。\n\n(由 弹弹play AI 辅助翻译)',
    });
    expect(anime.summary, '简介正文。');
  });
}
