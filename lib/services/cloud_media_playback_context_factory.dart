import 'package:path/path.dart' as p;
import 'package:nipaplay/models/media_identity.dart';
import 'package:nipaplay/models/playback_detail_context.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cue_sheet_parser.dart';
import 'package:nipaplay/utils/media_source_utils.dart';
import 'package:nipaplay/utils/webdav_file_sorter.dart';

/// Builds the existing player playlist context for an indexed CD work.
class CloudMediaPlaybackContextFactory {
  const CloudMediaPlaybackContextFactory._();

  static Future<PlaybackDetailContext?> create({
    required Map<String, Object?> currentAsset,
    required String sourceId,
    required String rootPath,
    required String normalizedRoot,
    required bool isLocalSource,
    required String? connectionId,
    required String workKey,
    required String title,
    required int? animeId,
  }) async {
    if (currentAsset['kind'] != 'audio') return null;
    final sourceAssets = (await CloudMediaIndexDatabase.instance
            .getAssets(sourceId: sourceId))
        .where((entry) =>
            entry['work_key'] == workKey &&
            entry['category'] == 'cd' &&
            entry['kind'] == 'audio')
        .toList()
      ..sort((a, b) => WebDAVFileSorter.naturalCompare(
            a['relative_path']?.toString() ?? '',
            b['relative_path']?.toString() ?? '',
          ));

    String filePathFor(String relative) {
      final normalized = relative.replaceAll('\\', '/').replaceFirst(
            RegExp(r'^/+'),
            '',
          );
      if (isLocalSource) return p.join(rootPath, relative);
      final remotePath = normalizedRoot.isEmpty
          ? '/$normalized'
          : '$normalizedRoot/$normalized';
      if (connectionId == null || connectionId.isEmpty) {
        throw StateError('未配置云媒体来源连接');
      }
      return MediaSourceUtils.buildWebDavPath(connectionId, remotePath);
    }

    final playlist = <PlaybackDetailEpisode>[];
    final cueTracks = currentAsset['cue_tracks'];
    if (cueTracks is List<CueSheetTrack>) {
      for (final track in cueTracks) {
        if (!sourceAssets.any(
            (entry) => entry['relative_path'] == track.audioRelativePath)) {
          continue;
        }
        final trackPath = filePathFor(track.audioRelativePath);
        final trackKey = MediaIdentity.remotePathKey(
          source: 'cloudmedia',
          connectionId: sourceId,
          rawPath: '${track.audioRelativePath}#cue-track=${track.number}',
        );
        final trackHistory =
            await WatchHistoryManager.getHistoryByMediaKey(trackKey);
        playlist.add(PlaybackDetailEpisode(
          id: '${track.audioRelativePath}#${track.number}',
          videoPath: trackPath,
          title: track.title,
          subtitle: title,
          animeId: animeId,
          historyItem: WatchHistoryItem(
            filePath: trackPath,
            animeName: title,
            episodeTitle: track.title,
            animeId: animeId,
            duration: trackHistory?.duration ?? 0,
            lastPosition: trackHistory?.lastPosition ??
                track.startPosition.inMilliseconds,
            watchProgress: trackHistory?.watchProgress ?? 0,
            lastWatchTime: trackHistory?.lastWatchTime ?? DateTime.now(),
            mediaKey: trackKey,
          ),
          mediaKey: trackKey,
          startPositionMs: track.startPosition.inMilliseconds,
        ));
      }
    } else {
      for (final audioAsset in sourceAssets) {
        final audioRelative = audioAsset['relative_path']?.toString() ?? '';
        final audioPath = filePathFor(audioRelative);
        final audioKey = MediaIdentity.remotePathKey(
          source: 'cloudmedia',
          connectionId: sourceId,
          rawPath: audioRelative,
        );
        final audioHistory =
            await WatchHistoryManager.getHistoryByMediaKey(audioKey);
        final audioName = audioAsset['name']?.toString() ?? audioRelative;
        playlist.add(PlaybackDetailEpisode(
          id: audioRelative,
          videoPath: audioPath,
          title: p.basenameWithoutExtension(audioName),
          subtitle: title,
          animeId: animeId,
          historyItem: WatchHistoryItem(
            filePath: audioPath,
            animeName: title,
            episodeTitle: audioName,
            animeId: animeId,
            duration: audioHistory?.duration ?? 0,
            lastPosition: audioHistory?.lastPosition ?? 0,
            watchProgress: audioHistory?.watchProgress ?? 0,
            lastWatchTime: audioHistory?.lastWatchTime ?? DateTime.now(),
            mediaKey: audioKey,
          ),
          mediaKey: audioKey,
        ));
      }
    }

    final cdPlaylist = List<PlaybackDetailEpisode>.unmodifiable(playlist);
    return PlaybackDetailContext(
      sourceKind: isLocalSource
          ? PlaybackSourceKind.localFile
          : PlaybackSourceKind.webDav,
      sourceLabel: isLocalSource ? '本地 CDs' : 'WebDAV CDs',
      sourceKey: 'cloudmedia-cd:$sourceId:$workKey',
      title: title,
      isIdentified: true,
      animeId: animeId,
      episodeLoader: () async => cdPlaylist,
    );
  }
}
