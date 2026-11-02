import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_scanner.dart';
import 'package:nipaplay/utils/cloud_media_asset_presentation.dart';

void main() {
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
}
