import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cloud_media_work_dialog.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final database = CloudMediaIndexDatabase.instance;
  late Directory temp;
  late PathProviderPlatform original;
  const filename =
      '[LoliHouse] 22／7 - 01 [BDRip 1080p HEVC-10bit FLAC AAC].mkv';
  const work = <String, Object?>{'work_key': '.', 'title': '22/7'};
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await database.close();
    temp = await Directory.systemTemp.createTemp('work_dialog_');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(temp.path);
    await database.upsertAssets([
      for (final name in [filename, '22／7 SP01.mkv', '22／7 unknown.mkv'])
        {
          'source_id': 'test',
          'relative_path': name,
          'name': name,
          'kind': 'video',
          'category': name.contains('SP') ? 'extra' : 'review',
          'work_key': '.'
        },
    ]);
  });
  tearDown(() async {
    await database.close();
    PathProviderPlatform.instance = original;
    await temp.delete(recursive: true);
  });

  test(
      'old reviews repair on read, persist, and preserve locked files and extras',
      () async {
    await database.updateAssetRelation(
        sourceId: 'test',
        relativePath: '22／7 unknown.mkv',
        workKey: '.',
        category: 'review');
    await database.upsertAssets([
      {
        'source_id': 'test',
        'relative_path': '02.mkv',
        'name': '02.mkv',
        'kind': 'video',
        'category': 'review',
        'work_key': '.'
      }
    ]);
    await database.updateAssetRelation(
        sourceId: 'test',
        relativePath: '02.mkv',
        workKey: '.',
        category: 'review');
    const hashName =
        '[AI-Raws] 29歳独身中堅冒険者の日常 #01 (BD HEVC 1920x1080 FLAC)[89A35093].mkv';
    await database.upsertAssets([
      {
        'source_id': 'test',
        'relative_path': hashName,
        'name': hashName,
        'kind': 'video',
        'category': 'review',
        'work_key': '.'
      }
    ]);
    const otherNames = [
      '[ANK-Raws] 91 Days 01 (BDrip 1920x1080 HEVC-YUV420P10 FLAC).mkv',
      'Lets.Play.S01E01.Life.is.S-Rank.1080p.CR.WEB-DL.DUAL.AAC2.0.H.264-VARYG.mkv',
    ];
    await database.upsertAssets([
      for (final name in otherNames)
        {
          'source_id': 'test',
          'relative_path': name,
          'name': name,
          'kind': 'video',
          'category': 'review',
          'work_key': '.'
        }
    ]);
    final rows = await database.getAssets(sourceId: 'test');
    for (final name in otherNames) {
      expect(rows.singleWhere((row) => row['name'] == name)['category'],
          'episode');
      expect(
          rows.singleWhere((row) => row['name'] == name)['episode_number'], 1);
    }
    expect(rows.singleWhere((row) => row['name'] == hashName)['category'],
        'episode');
    expect(rows.singleWhere((row) => row['name'] == hashName)['episode_number'],
        1);
    final repaired = rows.singleWhere((row) => row['name'] == filename);
    expect(repaired['category'], 'episode');
    expect(repaired['episode_number'], 1);
    expect(rows.singleWhere((row) => row['name'] == '02.mkv')['category'],
        'review');
    expect(
        rows.singleWhere((row) => row['name'] == '22／7 SP01.mkv')['category'],
        'extra');
    final db = await database.database;
    expect(
        (await db.query('cloud_media_asset',
                where: 'name = ?', whereArgs: [filename]))
            .single['category'],
        'episode');
  });

  for (final width in [320.0, 400.0, 840.0]) {
    testWidgets('file names and edit controls work at width $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CloudMediaWorkDialog(
                      sourceId: 'test',
                      work: work,
                      works: const [work],
                      onOpenAsset: (_, __) async {},
                    )),
            child: const Text('关联管理')),
      ))));
      await tester.tap(find.text('关联管理'));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(find.text(filename), findsOneWidget);
      expect(tester.getSize(find.text(filename)).width, greaterThan(150));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(filename));
      await tester.pumpAndSettle();
      expect(find.text('修改文件归属'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('特典').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并锁定'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      final saved =
          await tester.runAsync(() => database.getAssets(sourceId: 'test'));
      final asset = saved!.singleWhere((row) => row['name'] == filename);
      expect(asset['category'], 'extra');
      expect(asset['relation_locked'], 1);
      expect(tester.takeException(), isNull);
      await tester.tap(find.descendant(
          of: find
              .ancestor(
                  of: find.text(filename), matching: find.byType(LayoutBuilder))
              .first,
          matching: find.byTooltip('撤销上次修改')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      final undone =
          await tester.runAsync(() => database.getAssets(sourceId: 'test'));
      expect(undone!.singleWhere((row) => row['name'] == filename)['category'],
          'episode');
      expect(tester.takeException(), isNull);
    });
  }
}
