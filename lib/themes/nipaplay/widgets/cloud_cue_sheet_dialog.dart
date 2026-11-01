import 'package:flutter/material.dart';
import 'package:nipaplay/services/cue_sheet_parser.dart';
import 'package:nipaplay/widgets/in_view_dialog.dart';

class CloudCueSheetDialog {
  const CloudCueSheetDialog._();

  static Future<CueSheetTrack?> show({
    required BuildContext context,
    required String title,
    required List<CueSheetTrack> tracks,
  }) {
    return showInViewDialog<CueSheetTrack>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return ListTile(
                leading: Text(track.number.toString().padLeft(2, '0')),
                title: Text(track.title),
                subtitle: Text(
                  '${track.audioRelativePath} · ${track.startPosition.inMinutes.toString().padLeft(2, '0')}:${(track.startPosition.inSeconds % 60).toString().padLeft(2, '0')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(dialogContext, track),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}
