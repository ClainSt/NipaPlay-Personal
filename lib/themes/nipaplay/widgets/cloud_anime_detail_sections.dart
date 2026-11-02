import 'package:flutter/material.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/widgets/in_view_dialog.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cloud_media_work_dialog.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cached_network_image_widget.dart';

typedef CloudAnimeAssetOpenCallback = Future<void> Function(
  BuildContext context,
  Map<String, Object?> asset,
);

class CloudAnimeDetailSections extends StatelessWidget {
  const CloudAnimeDetailSections({
    super.key,
    required this.animeId,
    required this.onOpenAsset,
  });

  final int animeId;
  final CloudAnimeAssetOpenCallback onOpenAsset;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: CloudMediaIndexDatabase.instance.getWorks(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const SizedBox.shrink();
        final allWorks = snapshot.data;
        if (allWorks == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final matches = allWorks
            .where((work) =>
                work['bangumi_id']?.toString() == animeId.toString() ||
                work['dandanplay_anime_id']?.toString() == animeId.toString())
            .toList();
        if (matches.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('云媒体文件', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final work in matches)
                _CloudAnimeWorkCard(
                  work: work,
                  allWorks: allWorks
                      .where((item) => item['source_id'] == work['source_id'])
                      .toList(),
                  onOpenAsset: onOpenAsset,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CloudAnimeWorkCard extends StatelessWidget {
  const _CloudAnimeWorkCard({
    required this.work,
    required this.allWorks,
    required this.onOpenAsset,
  });

  final Map<String, Object?> work;
  final List<Map<String, Object?>> allWorks;
  final CloudAnimeAssetOpenCallback onOpenAsset;

  static const _labels = <String, String>{
    'episode': '正片',
    'extra': '特典',
  };

  @override
  Widget build(BuildContext context) {
    final sourceId = work['source_id']?.toString() ?? '';
    final workKey = work['work_key']?.toString() ?? '.';
    return FutureBuilder<List<Map<String, Object?>>>(
      future: CloudMediaIndexDatabase.instance.getAssets(
        sourceId: sourceId,
        workKey: workKey,
      ),
      builder: (context, snapshot) {
        final assets = snapshot.data ?? const <Map<String, Object?>>[];
        if (snapshot.hasError) {
          return const ListTile(title: Text('读取媒体分类失败'));
        }
        final counts = <String, int>{
          for (final category in _labels.keys)
            category:
                assets.where((asset) => asset['category'] == category).length,
        };
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (work['poster_url']?.toString().isNotEmpty == true) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CachedNetworkImageWidget(
                      imageUrl: work['poster_url'].toString(),
                      width: 72,
                      height: 104,
                      fit: BoxFit.cover,
                      memCacheWidth: 216,
                      memCacheHeight: 312,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        work['title_cn']?.toString().isNotEmpty == true
                            ? work['title_cn'].toString()
                            : work['title']?.toString() ?? '云媒体库作品',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final entry in _labels.entries)
                            Chip(
                              label:
                                  Text('${entry.value} ${counts[entry.key]}'),
                            ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed:
                              snapshot.connectionState != ConnectionState.done
                                  ? null
                                  : () => showInViewDialog<void>(
                                        context: context,
                                        builder: (_) => CloudMediaWorkDialog(
                                          sourceId: sourceId,
                                          work: work,
                                          works: allWorks,
                                          onOpenAsset: onOpenAsset,
                                        ),
                                      ),
                          icon: const Icon(Icons.view_list_outlined),
                          label: const Text('查看正片与特典'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
