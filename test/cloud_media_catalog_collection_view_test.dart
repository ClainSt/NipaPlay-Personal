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
    expect(find.text('1 部作品 · 1 个文件'), findsOneWidget);
    expect(find.text('/Anime'), findsOneWidget);
  });
}
