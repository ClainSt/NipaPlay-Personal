import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/themes/nipaplay/widgets/library_anime_detail_page.dart';

void main() {
  const assets = <Map<String, Object?>>[
    {
      'name': 'episode-one.mkv',
      'relative_path': '01.mkv',
      'kind': 'video',
      'category': 'episode',
      'episode_number': 1
    },
    {
      'name': 'NCOP 01.mkv',
      'relative_path': 'NCOP.mkv',
      'kind': 'video',
      'category': 'extra'
    },
    {
      'name': 'PV 01.mkv',
      'relative_path': 'PV.mkv',
      'kind': 'video',
      'category': 'extra'
    },
    {
      'name': '[Group] Show [MENU01][1080p].mkv',
      'relative_path': 'MENU01.mkv',
      'kind': 'video',
      'category': 'review'
    },
  ];
  for (final width in [360.0, 840.0, 1440.0]) {
    testWidgets(
        'detail separates assets, plays without artwork, adapts at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? played;
      bool? restarted;
      await tester.pumpWidget(MaterialApp(
          home: LibraryAnimeDetailPage(
        sourceId: 'test',
        work: {
          'work_key': 'work',
          'title': '真实目录测试作品',
          'metadata_json': jsonEncode({
            'tmdb_episode_seasons': {
              '1': [
                {
                  'episode_number': 1,
                  'name': '来自 TMDB 的第一集标题',
                }
              ]
            }
          })
        },
        works: const [],
        pathForAsset: (a) => a['relative_path'] as String,
        assetsLoader: () async => assets,
        historyLoader: () async => [
          WatchHistoryItem(
              filePath: '01.mkv',
              animeName: '作品',
              watchProgress: .4,
              lastPosition: 40000,
              duration: 100000,
              lastWatchTime: DateTime(2026))
        ],
        onPlay: (a, restart) async {
          played = a['relative_path'] as String;
          restarted = restart;
        },
        onBack: () {},
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('来自 TMDB 的第一集标题'), findsOneWidget);
      expect(find.text('episode-one.mkv'), findsNothing);
      expect(find.text('NCOP01'), findsNothing);
      await tester.ensureVisible(find.text('来自 TMDB 的第一集标题'));
      await tester.tap(find.text('来自 TMDB 的第一集标题'));
      expect(played, '01.mkv');
      expect(restarted, false);
      await tester.ensureVisible(find.text('特典  3'));
      await tester.tap(find.text('特典  3'));
      await tester.pumpAndSettle();
      expect(find.text('来自 TMDB 的第一集标题'), findsNothing);
      await tester.ensureVisible(find.text('NCOP01'));
      await tester.tap(find.text('NCOP01'));
      expect(played, 'NCOP.mkv');
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'PV'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'PV'));
      await tester.pumpAndSettle();
      expect(find.text('NCOP01'), findsNothing);
      expect(find.text('PV01'), findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'MENU'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'MENU'));
      await tester.pumpAndSettle();
      expect(find.text('MENU01'), findsOneWidget);
      expect(find.text('PV01'), findsNothing);
      await tester.ensureVisible(find.text('MENU01'));
      await tester.tap(find.text('MENU01'));
      expect(played, 'MENU01.mkv');
      await tester.ensureVisible(find.text('从头播放'));
      await tester.tap(find.text('从头播放'));
      expect(played, '01.mkv');
      expect(restarted, true);
      expect(tester.takeException(), isNull);
    });
  }
}
