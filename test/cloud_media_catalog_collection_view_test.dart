import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/media_library/cloud_media_catalog_collection_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cloud catalog collection renders scanned WebDAV works',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CloudMediaCatalogCollectionView(
          onPlayEpisode: (_) {},
          catalogLoader: () async => [
            const CloudMediaCatalogEntry(
              root: {
                'id': 'library-id',
                'name': 'Anime',
                'root_path': '/Anime',
                'connection_id': 'webdav-id',
              },
              works: [
                {
                  'work_key': 'Anime',
                  'title': 'Indexed Anime',
                  'title_cn': 'Indexed Anime',
                },
              ],
              assets: [
                {
                  'work_key': 'Anime',
                  'relative_path': '[01].mkv',
                  'name': '[01].mkv',
                  'kind': 'video',
                  'category': 'episode',
                },
                {
                  'work_key': '.',
                  'relative_path': 'metadata.nfo',
                  'name': 'metadata.nfo',
                  'kind': 'nfo',
                  'category': 'metadata',
                },
              ],
            ),
          ],
        ),
      ),
    ));

    for (var attempt = 0;
        attempt < 20 && find.text('Indexed Anime').evaluate().isEmpty;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Indexed Anime'), findsOneWidget);
    expect(find.byType(InkWell), findsWidgets);
    expect(find.text('未关联文件'), findsNothing);
    expect(find.text('/Anime'), findsNothing);
    final grid = tester.widget<GridView>(find.byType(GridView));
    final layout =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(layout.mainAxisExtent, isNotNull);
    final title = tester.getRect(find.text('Indexed Anime'));
    final card = tester.getRect(find
        .ancestor(
            of: find.text('Indexed Anime'), matching: find.byType(InkWell))
        .first);
    expect(card.bottom - title.bottom, lessThan(1));
  });
}
