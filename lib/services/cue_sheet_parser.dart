import 'package:path/path.dart' as p;

/// A playable audio track described by a CUE sheet.
class CueSheetTrack {
  const CueSheetTrack({
    required this.number,
    required this.title,
    required this.audioRelativePath,
    required this.startPosition,
  });

  final int number;
  final String title;
  final String audioRelativePath;
  final Duration startPosition;
}

/// Parses the common FILE / TRACK / TITLE / INDEX 01 subset used by albums.
class CueSheetParser {
  const CueSheetParser._();

  static List<CueSheetTrack> parse(String text, {required String cuePath}) {
    text = text.replaceFirst('\uFEFF', '');
    final cueDirectory = p.posix.dirname(cuePath.replaceAll('\\', '/'));
    final tracks = <CueSheetTrack>[];
    String? currentFile;
    _CueTrackBuilder? currentTrack;

    void finishTrack() {
      final track = currentTrack;
      if (track == null || track.file == null || track.indexFrame == null) {
        return;
      }
      final relativePath = p.posix.normalize(
        p.posix.join(cueDirectory, track.file!),
      );
      final frame = track.indexFrame!;
      final seconds = frame ~/ (75 * 60);
      final remainder = frame % (75 * 60);
      final duration = Duration(
        minutes: seconds,
        seconds: remainder ~/ 75,
        milliseconds: ((remainder % 75) * 1000 / 75).round(),
      );
      tracks.add(CueSheetTrack(
        number: track.number,
        title: track.title?.trim().isNotEmpty == true
            ? track.title!.trim()
            : 'Track ${track.number.toString().padLeft(2, '0')}',
        audioRelativePath: relativePath,
        startPosition: duration,
      ));
    }

    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      final fileMatch = RegExp(
        r'^FILE\s+(?:"([^"]+)"|(\S+))',
        caseSensitive: false,
      ).firstMatch(line);
      if (fileMatch != null) {
        currentFile = fileMatch.group(1) ?? fileMatch.group(2);
        continue;
      }
      final trackMatch = RegExp(
        r'^TRACK\s+(\d+)\s+(\w+)',
        caseSensitive: false,
      ).firstMatch(line);
      if (trackMatch != null) {
        finishTrack();
        currentTrack = trackMatch.group(2)!.toUpperCase() == 'AUDIO'
            ? _CueTrackBuilder(
                number: int.tryParse(trackMatch.group(1)!) ?? tracks.length + 1,
                file: currentFile,
              )
            : null;
        continue;
      }
      final track = currentTrack;
      if (track == null) continue;
      final titleMatch = RegExp(
        r'^TITLE\s+(?:"(.*)"|(.*))$',
        caseSensitive: false,
      ).firstMatch(line);
      if (titleMatch != null) {
        track.title = titleMatch.group(1) ?? titleMatch.group(2);
        continue;
      }
      final indexMatch = RegExp(
        r'^INDEX\s+01\s+(\d{1,3}):(\d{2}):(\d{2})',
        caseSensitive: false,
      ).firstMatch(line);
      if (indexMatch != null) {
        final minutes = int.parse(indexMatch.group(1)!);
        final seconds = int.parse(indexMatch.group(2)!);
        final frames = int.parse(indexMatch.group(3)!);
        if (seconds < 60 && frames < 75) {
          track.indexFrame = (minutes * 60 + seconds) * 75 + frames;
        }
      }
    }
    finishTrack();
    return List.unmodifiable(tracks);
  }
}

class _CueTrackBuilder {
  _CueTrackBuilder({required this.number, required this.file});

  final int number;
  final String? file;
  String? title;
  int? indexFrame;
}
