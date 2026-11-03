import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/utils/anime_detail_metadata.dart';

void main() {
  test('nested Dandanplay tags use the same limit and omit release dates', () {
    final work = <String, Object?>{
      'work_key': '16bit的感动 ANOTHER LAYER (2023) {tmdb-217512}',
      'metadata_json': jsonEncode({
        'bangumi': {
          'typeDescription': 'TV动画',
          'air_date': '2023-10-05T00:00:00',
          'tags': [
            {'name': '日本'},
            {'name': '奇幻'},
            '原创',
            '穿越',
            '职场',
            '2023年10月',
            {'name': 'galgame'},
            '漫画改',
            '科普',
            '2023',
            '2023年',
            '日本',
          ],
          'metadata': [
            '原作: 若木民喜',
            '动画制作: st.SILVER',
          ],
        },
      }),
    };

    expect(AnimeDetailMetadata.year(work), '2023');
    expect(AnimeDetailMetadata.tags(work), [
      'TV',
      'st.SILVER',
      '原创',
      '日本',
      '奇幻',
      '穿越',
      '职场',
      'galgame',
    ]);
  });

  test('format company and adaptation are prioritized before genres', () {
    final work = <String, Object?>{
      'metadata_json': jsonEncode({
        'bangumi': {
          'typeDescription': 'TV动画',
          'tags': [
            {'name': '恋爱'},
            {'name': '2024年7月'},
            {'name': 'J.C.STAFF'},
            {'name': '校园'},
            {'name': '漫画改'},
            {'name': 'cosplay'},
            {'name': 'TV'},
            {'name': '后宫'},
            {'name': '漫改'},
          ],
        },
      }),
    };

    expect(AnimeDetailMetadata.tags(work), [
      'TV',
      'J.C.STAFF',
      '漫画改',
      '恋爱',
      '校园',
      'cosplay',
      '后宫',
    ]);
  });

  test('structured production infobox supplies the company fallback', () {
    final work = <String, Object?>{
      'metadata_json': jsonEncode({
        'type': 'tv',
        'typeDescription': 'TV动画',
        'infobox': [
          {
            'key': '动画制作',
            'value': [
              {'v': 'KONAMI animation'},
            ],
          },
        ],
        'tags': [
          {'name': '原创'},
        ],
      }),
    };

    expect(AnimeDetailMetadata.tags(work).take(3), [
      'TV',
      'KONAMI animation',
      '原创',
    ]);
  });

  test('TMDB genres are a provider-independent tag fallback', () {
    final work = <String, Object?>{
      'work_key': 'Show (2024) {tmdb-1}',
      'metadata_json': jsonEncode({
        'first_air_date': '2024-07-01',
        'genres': [
          {'name': '动画'},
          {'name': '喜剧'},
        ],
      }),
    };

    expect(AnimeDetailMetadata.year(work), '2024');
    expect(AnimeDetailMetadata.tags(work), ['动画', '喜剧']);
  });

  test('Dandanplay model parses both string and object tag formats', () {
    final anime = BangumiAnime.fromDandanplayDetail({
      'animeId': 17802,
      'animeTitle': '16bit的感动 ANOTHER LAYER',
      'imageUrl': 'https://example.com/cover.jpg',
      'tags': [
        'TV',
        {'name': '日本'},
        2023,
      ],
    });
    expect(anime.tags, ['TV', '日本', '2023']);
  });
}
