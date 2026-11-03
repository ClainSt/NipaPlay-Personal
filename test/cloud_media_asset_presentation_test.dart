import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_scanner.dart';
import 'package:nipaplay/utils/cloud_media_asset_presentation.dart';

void main() {
  test(
      'continuous episodes span seasons without overriding explicit season numbers',
      () {
    final seasons = <String, dynamic>{
      'season_episode_counts': {'1': 12, '2': 12},
      '1': [
        for (var i = 1; i <= 12; i++)
          {'episode_number': i, 'name': 'S1E$i', 'still_path': '/s1e$i.jpg'}
      ],
      '2': [
        for (var i = 1; i <= 12; i++)
          {'episode_number': i, 'name': 'S2E$i', 'still_path': '/s2e$i.jpg'}
      ],
    };
    for (var i = 1; i <= 24; i++) {
      final asset = <String, Object?>{
        'category': 'episode',
        'name': i == 13
            ? '[Moozzi2] 3D Kanojo Real Girl - 13 (BD 1920x1080 x.264 Flac).mkv'
            : '3D Kanojo [$i].mkv',
        'episode_number': i
      };
      expect(CloudMediaAssetPresentation.episode(asset, seasons)?['name'],
          i <= 12 ? 'S1E$i' : 'S2E${i - 12}');
      expect(CloudMediaAssetPresentation.episode(asset, seasons)?['still_path'],
          i <= 12 ? '/s1e$i.jpg' : '/s2e${i - 12}.jpg');
    }
    expect(
        CloudMediaAssetPresentation.episode({
          'category': 'episode',
          'name': 'Show S01E13.mkv',
          'episode_number': 13
        }, seasons),
        isNull);
    expect(
        CloudMediaAssetPresentation.episode({
          'category': 'episode',
          'name': 'Show S02E01.mkv',
          'episode_number': 1
        }, seasons)?['name'],
        'S2E1');
    expect(
        CloudMediaAssetPresentation.episode(
            {'category': 'extra', 'episode_number': 13}, seasons),
        isNull);
    expect(
        CloudMediaAssetPresentation.episode(
            {'category': 'episode', 'episode_number': 25}, seasons),
        isNull);
    expect(
        CloudMediaAssetPresentation.episode(
            {'category': 'episode', 'episode_number': 13},
            {'1': seasons['1'], '2': seasons['2']}),
        isNull,
        reason: 'Do not guess season boundaries without provider counts.');
  });
  test('WEB previews retain filename labels and cannot match OVA metadata', () {
    const asset = <String, Object?>{
      'name': 'Show WEB予告#01.mkv',
      'category': 'extra'
    };
    expect(CloudMediaAssetPresentation.extraType(asset), '预告');
    expect(CloudMediaAssetPresentation.extraDisplayTitle(asset), asset['name']);
    expect(
        CloudMediaAssetPresentation.isSpecialMappingCandidate(asset), isFalse);
  });

  test('separates season folders and uses work context for relative paths', () {
    for (final label in [
      '第二季',
      '第2季',
      '第 二 期',
      'S02',
      'Season 2',
      '2nd Season'
    ]) {
      final asset = <String, Object?>{
        'name': 'Show [01][1080p].mkv',
        'relative_path': 'Show $label/Show [01].mkv',
        'category': 'episode',
        'episode_number': 1,
      };
      expect(CloudMediaAssetPresentation.seasonNumber(asset), 2, reason: label);
      expect(
          CloudMediaAssetPresentation.episode(asset, {
            '1': [
              {'episode_number': 1, 'name': 'Wrong'}
            ],
            '2': [
              {'episode_number': 1, 'name': 'Correct'}
            ],
          })?['name'],
          'Correct');
    }
    expect(
        CloudMediaAssetPresentation.seasonNumber({
          'relative_path': 'Show [01].mkv',
          'work_key': '为美好的世界献上祝福！ 第三季 (2024)',
        }),
        3);
    expect(
        CloudMediaAssetPresentation.seasonNumber({
          'relative_path': 'Show S03/Show S02E01.mkv',
          'name': 'Show S02E01.mkv',
          'work_title': 'Show 第三季',
        }),
        2);
    expect(
        CloudMediaAssetPresentation.seasonNumber({
          'season_number': 3,
          'name': 'Show S02E01.mkv',
        }),
        3);
    expect(
        CloudMediaAssetPresentation.seasonNumber({
          'name': 'Show 2 [01][1080p] (2024).mkv',
        }),
        1);
  });

  test('other extras retain identifying labels or the original filename', () {
    for (final label in ['IV01', 'IV02', 'EX03', 'EVENT01']) {
      expect(
          CloudMediaAssetPresentation.extraDisplayTitle({
            'name':
                '[SweetSub&VCB-Studio] Show [$label][1080p][HEVC10][FLAC2].mkv'
          }),
          label);
    }
    expect(
        CloudMediaAssetPresentation.extraDisplayTitle(
            {'name': 'Show IV 01.mkv'}),
        'IV01');
    const original = '[Group] Show [HEVC10][FLAC2][H264][AV1].mkv';
    expect(CloudMediaAssetPresentation.extraDisplayTitle({'name': original}),
        original);
    expect(CloudMediaAssetPresentation.extraDisplayTitle({'name': '访谈花絮.mkv'}),
        '访谈花絮.mkv');
  });
  test('extracts extra tokens without release names or encoding suffixes', () {
    for (final token in ['NCOP', 'NCED', 'SP01', 'MENU', 'NCOPED', 'CM02']) {
      final asset = {'name': '[SweetSub&VCB-Studio] Show [$token][1080p].mkv'};
      expect(CloudMediaAssetPresentation.extraTitle(asset), token);
    }
    expect(
        CloudMediaAssetPresentation.extraTitle({'name': 'Show [NCED 02].mkv'}),
        'NCED02');
    expect(CloudMediaAssetPresentation.extraTitle({'name': 'Specialist.mkv'}),
        isNull);
  });

  test('MENU names and folders are extras, including previously indexed files',
      () {
    expect(
        CloudMediaScanner.classifyAsset('Show', 'Show [MENU01].mkv', 'video'),
        'extra');
    expect(CloudMediaScanner.classifyAsset('Show/Menu', '01.mkv', 'video'),
        'extra');
    final oldAsset = {
      'name': '01.mkv',
      'relative_path': 'Show/Menu/01.mkv',
      'category': 'review'
    };
    expect(CloudMediaAssetPresentation.category(oldAsset), 'extra');
    expect(CloudMediaAssetPresentation.extraType(oldAsset), 'MENU');
  });

  test('matches the season and episode together and never matches extras', () {
    final seasons = <String, dynamic>{
      '1': [
        {'episode_number': 1, 'name': '第一季标题'}
      ],
      '2': [
        {'episode_number': 1, 'name': '第二季标题', 'still_path': '/two.jpg'}
      ],
    };
    final asset = <String, Object?>{
      'category': 'episode',
      'episode_number': 1,
      'relative_path': 'Show/Season 2/Show [01].mkv'
    };
    expect(
        CloudMediaAssetPresentation.episode(asset, seasons)?['name'], '第二季标题');
    expect(
        CloudMediaAssetPresentation.seasonNumber(
            {...asset, 'relative_path': 'Show S03E01.mkv'}),
        3);
    expect(
        CloudMediaAssetPresentation.episode(
            {...asset, 'category': 'extra'}, seasons),
        isNull);
  });

  test('maps unrenamed OVA files to TMDB specials by number and stable order',
      () {
    final assets = <Map<String, Object?>>[
      {
        'name': 'Show OVA 02.mkv',
        'relative_path': 'Show/OVA 02.mkv',
        'category': 'extra',
      },
      {
        'name': 'Show OVA 01.mkv',
        'relative_path': 'Show/OVA 01.mkv',
        'category': 'extra',
      },
    ];
    final specials = <Map<String, dynamic>>[
      {'episode_number': 2, 'name': 'OVA 2: Second', 'still_path': '/two.jpg'},
      {'episode_number': 1, 'name': 'OVA 1: First', 'still_path': '/one.jpg'},
    ];

    final mapping = CloudMediaAssetPresentation.mapSpecialEpisodes(
      assets: assets,
      specials: specials,
    );
    expect(mapping['Show/OVA 01.mkv']?['name'], 'OVA 1: First');
    expect(mapping['Show/OVA 02.mkv']?['name'], 'OVA 2: Second');

    final seasons = <String, dynamic>{
      '0': specials,
      'special_assets': mapping,
    };
    expect(
      CloudMediaAssetPresentation.specialEpisode(assets[1], seasons)?['name'],
      'OVA 1: First',
    );
    expect(
      CloudMediaAssetPresentation.specialEpisode(
        {
          'name': 'OVA.mkv',
          'relative_path': 'Show/OVA.mkv',
          'category': 'extra',
        },
        {
          '0': [
            {'episode_number': 3, 'name': 'OVA'}
          ],
        },
      ),
      isNull,
      reason:
          'A generic OVA requires the persisted mapping or explicit number.',
    );
  });

  test('uses the work year to separate shared TMDB season zero OVAs', () {
    final assets = <Map<String, Object?>>[
      {
        'name': 'Show OVA.mkv',
        'relative_path': 'Season 2/Show OVA.mkv',
        'category': 'extra',
      },
    ];
    final specials = <Map<String, dynamic>>[
      {
        'episode_number': 1,
        'name': 'OVA 1',
        'air_date': '2016-01-01',
      },
      {
        'episode_number': 2,
        'name': 'OVA 2',
        'air_date': '2017-01-01',
      },
      {
        'episode_number': 3,
        'name': 'OVA 3',
        'air_date': '2024-01-01',
      },
    ];

    final mapping = CloudMediaAssetPresentation.mapSpecialEpisodes(
      assets: assets,
      specials: specials,
      yearHint: 'Show Season 2 (2017) {tmdb-1}',
    );
    expect(mapping['Season 2/Show OVA.mkv']?['name'], 'OVA 2');
  });

  test('matches filename OVA assets to TMDB OAD entries by work year', () {
    final firstSeason = <Map<String, Object?>>[
      {
        'name':
            '[VCB-Studio] Kono Subarashii Sekai ni Shukufuku wo! [11(OVA)].mkv',
        'relative_path': 'Season 1/[11(OVA)].mkv',
        'category': 'extra',
      },
    ];
    final secondSeason = <Map<String, Object?>>[
      {
        'name':
            '[VCB-Studio] Kono Subarashii Sekai ni Shukufuku wo! 2 [11(OVA)].mkv',
        'relative_path': 'Season 2/[11(OVA)].mkv',
        'category': 'extra',
      },
    ];
    final thirdSeason = <Map<String, Object?>>[
      {
        'name': 'Show 3 [12(OVA01)].mkv',
        'relative_path': 'Season 3/[12(OVA01)].mkv',
        'category': 'extra',
      },
      {
        'name': 'Show 3 [13(OVA02)].mkv',
        'relative_path': 'Season 3/[13(OVA02)].mkv',
        'category': 'extra',
      },
    ];
    final specials = <Map<String, dynamic>>[
      {
        'episode_number': 1,
        'name': '『Show』OAD「First」',
        'air_date': '2016-06-24',
      },
      {
        'episode_number': 2,
        'name': '『Show 2』OAD「Second」',
        'air_date': '2017-07-24',
      },
      {
        'episode_number': 3,
        'name': '『Show 3』OVA1「Third」',
        'air_date': '2025-04-25',
      },
      {
        'episode_number': 4,
        'name': '『Show 3』OVA2「Fourth」',
        'air_date': '2025-04-25',
      },
    ];

    expect(
      CloudMediaAssetPresentation.mapSpecialEpisodes(
        assets: firstSeason,
        specials: specials,
        yearHint: 'Show (2016) {tmdb-1}',
      ).values.single['episode_number'],
      1,
    );
    expect(
      CloudMediaAssetPresentation.mapSpecialEpisodes(
        assets: secondSeason,
        specials: specials,
        yearHint: 'Show 2 (2017) {tmdb-1}',
      ).values.single['episode_number'],
      2,
    );
    final third = CloudMediaAssetPresentation.mapSpecialEpisodes(
      assets: thirdSeason,
      specials: specials,
      yearHint: 'Show 3 (2024) {tmdb-1}',
    );
    expect(third.values.map((entry) => entry['episode_number']), [3, 4]);
  });

  test('does not guess an unnumbered OVA without a matching year', () {
    final mapping = CloudMediaAssetPresentation.mapSpecialEpisodes(
      assets: [
        {
          'name': 'Show [OVA].mkv',
          'relative_path': 'Show/[OVA].mkv',
          'category': 'extra',
        },
      ],
      specials: [
        {
          'episode_number': 3,
          'name': 'Later OVA',
          'air_date': '2025-01-01',
        },
      ],
      yearHint: 'Show (2016) {tmdb-1}',
    );
    expect(mapping, isEmpty);
  });
}
