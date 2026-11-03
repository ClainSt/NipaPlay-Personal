import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/bangumi_api_service.dart';

void main() {
  test('principals precede support and cameos with stable provider order', () {
    final sorted = BangumiApiService.sortSubjectCharacters([
      {'name': '客串', 'relation': '客串'},
      {'name': '主角二', 'relation': '主角', 'order': 2},
      {'name': '配角', 'relation': '配角'},
      {'name': '主角一', 'relation': '主角', 'order': 1},
    ]);
    expect(sorted.map((c) => c['name']), ['主角一', '主角二', '配角', '客串']);
    final stable = BangumiApiService.sortSubjectCharacters([
      {'name': '甲', 'relation': '主角'},
      {'name': '乙', 'relation': '主角'},
    ]);
    expect(stable.map((c) => c['name']), ['甲', '乙']);
  });

  test('extracts simplified Chinese names from character or person infobox',
      () {
    expect(
      BangumiApiService.extractSimplifiedChineseName({
        'name': 'めぐみん',
        'name_cn': '',
        'infobox': [
          {
            'key': '简体中文名',
            'value': ['惠惠'],
          },
        ],
      }),
      '惠惠',
    );
    expect(
      BangumiApiService.extractSimplifiedChineseName({
        'name': '高橋李依',
        'name_cn': '',
        'infobox': [
          {'key': '简体中文名', 'value': '高桥李依'},
        ],
      }),
      '高桥李依',
    );
    expect(
      BangumiApiService.extractSimplifiedChineseName({
        'name': 'めぐみん',
        'name_cn': '惠惠',
      }),
      '惠惠',
    );
    expect(
      BangumiApiService.extractSimplifiedChineseName({'name': 'めぐみん'}),
      isNull,
    );
  });
}
