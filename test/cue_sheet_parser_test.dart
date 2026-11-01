import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/models/playback_detail_context.dart';
import 'package:nipaplay/services/cue_sheet_parser.dart';

void main() {
  test('parses tracks, titles, frame offsets and cue-relative audio path', () {
    const cue = '''
REM GENRE Soundtrack
TITLE "Example Album"
FILE "disc 1.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Opening"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Ending"
    INDEX 01 03:12:37
''';
    final tracks = CueSheetParser.parse(cue, cuePath: 'CDs/Album/album.cue');

    expect(tracks, hasLength(2));
    expect(tracks[0].title, 'Opening');
    expect(tracks[0].number, 1);
    expect(tracks[0].audioRelativePath, 'CDs/Album/disc 1.flac');
    expect(tracks[1].title, 'Ending');
    expect(tracks[1].startPosition.inMilliseconds, 192493);
  });

  test('ignores non-audio tracks and incomplete indexes', () {
    const cue = '''
FILE "album.wav" WAVE
TRACK 01 AUDIO
TITLE "Playable"
INDEX 01 00:00:00
TRACK 02 MODE1/2352
TITLE "Data"
INDEX 01 04:00:00
TRACK 03 AUDIO
TITLE "Missing index"
''';
    final tracks = CueSheetParser.parse(cue, cuePath: 'album.cue');

    expect(tracks.map((track) => track.title), ['Playable']);
  });

  test('playlist identities advance between cue tracks sharing one file', () {
    const episodes = [
      PlaybackDetailEpisode(
        id: 'album.flac#1',
        videoPath: 'album.flac',
        title: 'Track 1',
        mediaKey: 'cloudmedia:album#cue-track=1',
      ),
      PlaybackDetailEpisode(
        id: 'album.flac#2',
        videoPath: 'album.flac',
        title: 'Track 2',
        mediaKey: 'cloudmedia:album#cue-track=2',
      ),
    ];

    final result = PlaybackPlaylist.locate(
      episodes,
      'cloudmedia:album#cue-track=1',
      identityOf: (episode) => episode.mediaKey ?? episode.videoPath,
    );

    expect(result, isA<PlaylistHasNext>());
    expect((result as PlaylistHasNext).episode.title, 'Track 2');
    expect(episodes.first.videoPath, episodes.last.videoPath);
  });
}
