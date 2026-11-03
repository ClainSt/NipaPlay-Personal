import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/dandanplay_service.dart';

void main() {
  const konosuba = <Map<String, dynamic>>[
    {'animeId': 11261, 'animeTitle': '为美好的世界献上祝福！'},
    {'animeId': 11854, 'animeTitle': '为美好的世界献上祝福! OAD'},
    {'animeId': 11992, 'animeTitle': '为美好的世界献上祝福!  第二季'},
    {'animeId': 13317, 'animeTitle': '为美好的世界献上祝福! 第二季 OVA'},
    {'animeId': 17431, 'animeTitle': '为美好的世界献上祝福！第三季'},
    {'animeId': 18865, 'animeTitle': '为美好的世界献上祝福！第三季 ーBONUS STAGEー'},
  ];

  test('matching title chooses the requested season from many candidates', () {
    expect(
      DandanplayService.selectTmdbCandidateIndex(
        konosuba,
        titleHint: '为美好的世界献上祝福！ 第二季 (2017) {tmdb-65844}',
      ),
      2,
    );
    expect(
      DandanplayService.selectTmdbCandidateIndex(
        konosuba,
        titleHint: '为美好的世界献上祝福！第三季 (2024) {tmdb-65844}',
      ),
      4,
    );
  });

  test('base title keeps the original series when seasons share an ID', () {
    const candidates = <Map<String, dynamic>>[
      {'animeId': 15441, 'animeTitle': '86 -不存在的战区-'},
      {'animeId': 16172, 'animeTitle': '86 -不存在的战区- 第二季'},
    ];
    expect(
      DandanplayService.selectTmdbCandidateIndex(
        candidates,
        titleHint: '86 -不存在的战区- (2021) {tmdb-100565}',
      ),
      0,
    );
  });

  test('callers without a title hint retain season-number selection', () {
    expect(
      DandanplayService.selectTmdbCandidateIndex(
        konosuba,
        seasonNumber: 1,
      ),
      0,
    );
    expect(
      DandanplayService.selectTmdbCandidateIndex(konosuba),
      0,
    );
    expect(
      DandanplayService.selectTmdbCandidateIndex(const []),
      isNull,
    );
  });
}
