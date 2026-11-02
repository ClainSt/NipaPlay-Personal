import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/models/playback_detail_context.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_playback_context_factory.dart';
import 'package:nipaplay/services/cue_sheet_parser.dart';
import 'package:nipaplay/utils/storage_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CD playlist preserves natural order and CUE track start positions',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final temp = await Directory.systemTemp.createTemp('cloud_cd_playlist_');
    final previousPaths = PathProviderPlatform.instance;
    final previousStorageOverride =
        StorageService.debugAppStorageDirectoryOverride;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    StorageService.debugAppStorageDirectoryOverride = temp;
    final database = CloudMediaIndexDatabase.instance;
    addTearDown(() async {
      await database.close();
      PathProviderPlatform.instance = previousPaths;
      StorageService.debugAppStorageDirectoryOverride = previousStorageOverride;
      await temp.delete(recursive: true);
    });

    final sourceId = await database.ensureLibraryRoot(
      connectionId: 'device-webdav',
      rootPath: '/Anime',
    );
    await database.upsertUnmatchedWork(
      sourceId: sourceId,
      workKey: 'Example Show',
      title: 'Example Show',
    );
    await database.upsertAssets([
      {
        'source_id': sourceId,
        'relative_path': 'Example Show/CDs/Track 10.flac',
        'name': 'Track 10.flac',
        'kind': 'audio',
        'category': 'cd',
        'work_key': 'Example Show',
      },
      {
        'source_id': sourceId,
        'relative_path': 'Example Show/CDs/Track 2.flac',
        'name': 'Track 2.flac',
        'kind': 'audio',
        'category': 'cd',
        'work_key': 'Example Show',
      },
    ]);

    final audioAssets = await database.getAssets(sourceId: sourceId);
    final audioContext = await CloudMediaPlaybackContextFactory.create(
      currentAsset: audioAssets.last,
      sourceId: sourceId,
      rootPath: '/Anime',
      normalizedRoot: '/Anime',
      isLocalSource: false,
      connectionId: 'device-webdav',
      workKey: 'Example Show',
      title: 'Example Show',
      animeId: null,
    );
    expect(audioContext, isNotNull);
    expect(audioContext!.sourceKind, PlaybackSourceKind.webDav);
    final audioPlaylist = await audioContext.episodeLoader();
    expect(audioPlaylist.map((episode) => episode.title), [
      'Track 2',
      'Track 10',
    ]);
    expect(audioPlaylist.first.videoPath,
        'webdav://device-webdav/Anime/Example Show/CDs/Track 2.flac');

    const cueText = '''
FILE "Disc.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Opening"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Ending"
    INDEX 01 03:12:37
''';
    final cueTracks = CueSheetParser.parse(
      cueText,
      cuePath: 'Example Show/CDs/album.cue',
    );
    await database.upsertAssets([
      {
        'source_id': sourceId,
        'relative_path': 'Example Show/CDs/Disc.flac',
        'name': 'Disc.flac',
        'kind': 'audio',
        'category': 'cd',
        'work_key': 'Example Show',
      },
    ]);
    final cueContext = await CloudMediaPlaybackContextFactory.create(
      currentAsset: {
        'kind': 'audio',
        'relative_path': 'Example Show/CDs/album.cue',
        'cue_tracks': cueTracks,
      },
      sourceId: sourceId,
      rootPath: '/Anime',
      normalizedRoot: '/Anime',
      isLocalSource: false,
      connectionId: 'device-webdav',
      workKey: 'Example Show',
      title: 'Example Show',
      animeId: null,
    );
    expect(cueContext, isNotNull);
    final cuePlaylist = await cueContext!.episodeLoader();
    expect(cuePlaylist.map((episode) => episode.title), ['Opening', 'Ending']);
    expect(cuePlaylist.map((episode) => episode.startPositionMs), [0, 192493]);
    expect(cuePlaylist.map((episode) => episode.videoPath).toSet(), {
      'webdav://device-webdav/Anime/Example Show/CDs/Disc.flac',
    });
    expect(cuePlaylist.first.mediaKey, isNot(cuePlaylist.last.mediaKey));
  });
}
