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
  for (final width in [360.0, 600.0, 840.0, 1024.0, 1440.0, 1672.0]) {
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
          'overview': '真实作品简介。\n\n(由 弹弹play AI 辅助翻译)',
          'metadata_json': jsonEncode({
            'bangumi': {
              'typeDescription': 'TV动画',
              'air_date': '2024-07-05',
              'tags': [
                {'name': '恋爱'},
                {'name': '2024年7月'},
                {'name': '校园'},
                {'name': '漫画改'},
                {'name': 'cosplay'},
                {'name': 'TV'},
                {'name': '后宫'},
                {'name': '日常'},
              ],
            },
            'tmdb_episode_seasons': {
              '1': [
                {
                  'episode_number': 1,
                  'name': '来自 TMDB 的第一集测试用超长标题，用来确认滚动条不会挡住文字',
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
      expect(find.text('2024'), findsOneWidget);
      final contentSize = tester.getSize(
        find.byKey(const ValueKey('library-anime-detail-content')),
      );
      final posterSize = tester.getSize(
        find.byKey(const ValueKey('library-anime-detail-poster')),
      );
      expect(posterSize.width / posterSize.height, closeTo(2 / 3, .001));
      if (width < 1500) {
        expect(contentSize.width, greaterThanOrEqualTo(width - 100));
      }
      if (width >= 1440) {
        expect(contentSize.width, greaterThan(1200));
        expect(contentSize.width, lessThanOrEqualTo(1500));
      }
      expect(find.text('2024年7月'), findsNothing);
      expect(find.text('恋爱'), findsOneWidget);
      expect(find.textContaining('辅助翻译'), findsNothing);
      expect(find.text('来自 TMDB 的第一集测试用超长标题，用来确认滚动条不会挡住文字'), findsOneWidget);
      expect(find.text('episode-one.mkv'), findsNothing);
      expect(find.text('NCOP01'), findsNothing);
      final tmdbTitle = find.text('来自 TMDB 的第一集测试用超长标题，用来确认滚动条不会挡住文字');
      await tester.ensureVisible(tmdbTitle);
      final titleRect = tester.getRect(tmdbTitle);
      final railRect = tester.getRect(
        find.byKey(const ValueKey('library-anime-detail-episode-rail')),
      );
      expect(titleRect.bottom, lessThanOrEqualTo(railRect.bottom - 8));
      await tester.tap(tmdbTitle);
      expect(played, '01.mkv');
      expect(restarted, false);
      await tester.ensureVisible(find.text('特典  3'));
      await tester.tap(find.text('特典  3'));
      await tester.pumpAndSettle();
      expect(find.text('来自 TMDB 的第一集测试用超长标题，用来确认滚动条不会挡住文字'), findsNothing);
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

  testWidgets('single movie video falls back to the work title',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: LibraryAnimeDetailPage(
        sourceId: 'movie-test',
        work: const {
          'work_key': 'Movie',
          'title': 'Movie',
          'title_cn': '电影测试作品',
          'poster_url': 'assets/backempty.png',
          'tmdb_movie_id': 42,
          'metadata_json': '{}',
        },
        works: const [],
        pathForAsset: (asset) => asset['relative_path'] as String,
        assetsLoader: () async => [
          {
            'name': 'Movie.mkv',
            'relative_path': 'Movie.mkv',
            'kind': 'video',
            'category': 'episode',
          },
        ],
        historyLoader: () async => const [],
        workArtworkLoader: () async => 'assets/girl.png',
        onPlay: (_, __) async {},
        onBack: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('电影测试作品'), findsAtLeastNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey('library-anime-detail-tile:Movie.mkv'),
        ),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName == 'assets/girl.png',
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('movie extras do not reuse the movie poster as thumbnails',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: LibraryAnimeDetailPage(
        sourceId: 'movie-extra-test',
        work: const {
          'work_key': 'Movie',
          'title': 'Movie',
          'title_cn': '电影测试作品',
          'poster_url': 'assets/backempty.png',
          'tmdb_movie_id': 42,
          'metadata_json': '{}',
        },
        works: const [],
        pathForAsset: (asset) => asset['relative_path'] as String,
        assetsLoader: () async => [
          {
            'name': 'Movie.mkv',
            'relative_path': 'Movie.mkv',
            'kind': 'video',
            'category': 'episode',
          },
          {
            'name': 'Movie [CM01].mkv',
            'relative_path': 'SPs/CM01.mkv',
            'kind': 'video',
            'category': 'extra',
          },
        ],
        historyLoader: () async => const [],
        workArtworkLoader: () async => 'assets/girl.png',
        onPlay: (_, __) async {},
        onBack: () {},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('特典  1'));
    await tester.tap(find.text('特典  1'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey('library-anime-detail-tile:SPs/CM01.mkv'),
        ),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName == 'assets/girl.png',
        ),
      ),
      findsNothing,
    );
    expect(find.text('CM01'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail surface follows the active light and dark theme',
      (tester) async {
    Future<void> pumpTheme(Brightness brightness) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: LibraryAnimeDetailPage(
          sourceId: 'theme-test',
          work: const {
            'work_key': 'Theme',
            'title': '主题测试作品',
            'metadata_json': '{}',
          },
          works: const [],
          pathForAsset: (asset) => asset['relative_path'] as String,
          assetsLoader: () async => const [],
          historyLoader: () async => const [],
          onPlay: (_, __) async {},
          onBack: () {},
        ),
      ));
      await tester.pumpAndSettle();
    }

    await pumpTheme(Brightness.light);
    final lightSurface = tester.widget<Material>(
      find.byKey(const ValueKey('library-anime-detail-surface')),
    );
    expect(lightSurface.color!.computeLuminance(), greaterThan(.8));

    await pumpTheme(Brightness.dark);
    final darkSurface = tester.widget<Material>(
      find.byKey(const ValueKey('library-anime-detail-surface')),
    );
    expect(darkSurface.color!.computeLuminance(), lessThan(.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV detail displays fetched landscape artwork', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: LibraryAnimeDetailPage(
        sourceId: 'tv-artwork-test',
        work: const {
          'work_key': 'TV',
          'title': 'TV 测试作品',
          'poster_url': 'assets/backempty.png',
          'tmdb_tv_id': 42,
          'metadata_json': '{}',
        },
        works: const [],
        pathForAsset: (asset) => asset['relative_path'] as String,
        assetsLoader: () async => const [],
        historyLoader: () async => const [],
        workArtworkLoader: () async => 'assets/girl.png',
        onPlay: (_, __) async {},
        onBack: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName == 'assets/girl.png',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
