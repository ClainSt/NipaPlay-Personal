import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:nipaplay/models/playable_item.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cue_sheet_parser.dart';
import 'package:nipaplay/services/playback_service.dart';
import 'package:nipaplay/services/webdav_service.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cached_network_image_widget.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cloud_cue_sheet_dialog.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cloud_media_work_dialog.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cloud_scans_reader_page.dart';
import 'package:nipaplay/utils/media_source_utils.dart';
import 'package:nipaplay/widgets/in_view_dialog.dart';

class CloudMediaCatalogCollectionView extends StatefulWidget {
  const CloudMediaCatalogCollectionView({
    super.key,
    required this.onPlayEpisode,
    this.catalogLoader,
  });

  final ValueChanged<WatchHistoryItem> onPlayEpisode;
  final Future<List<CloudMediaCatalogEntry>> Function()? catalogLoader;

  @override
  State<CloudMediaCatalogCollectionView> createState() =>
      _CloudMediaCatalogCollectionViewState();
}

class _CloudMediaCatalogCollectionViewState
    extends State<CloudMediaCatalogCollectionView> {
  late Future<List<CloudMediaCatalogEntry>> _catalogsFuture;

  @override
  void initState() {
    super.initState();
    _catalogsFuture = _loadCatalogs();
  }

  Future<List<CloudMediaCatalogEntry>> _loadCatalogs() async {
    final loader = widget.catalogLoader;
    if (loader != null) return loader();
    final database = CloudMediaIndexDatabase.instance;
    final roots = (await database.getLibraryRoots())
        .where((root) =>
            !(root['connection_id']?.toString().startsWith('local:') ?? false))
        .toList();
    final catalogs = <CloudMediaCatalogEntry>[];
    for (final root in roots) {
      final id = root['id']?.toString() ?? '';
      catalogs.add(CloudMediaCatalogEntry(
        root: root,
        works: await database.getWorks(sourceId: id),
        assets: await database.getAssets(sourceId: id),
      ));
    }
    return catalogs;
  }

  void _refresh() {
    setState(() => _catalogsFuture = _loadCatalogs());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<CloudMediaCatalogEntry>>(
      future: _catalogsFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _CatalogMessage(
            message: '读取 WebDAV 媒体库失败：${snapshot.error}',
            onRefresh: _refresh,
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final catalogs = snapshot.data!;
        if (catalogs.isEmpty) {
          return _CatalogMessage(
            message: '还没有扫描过 WebDAV 媒体库。请在“WebDAV库管理”中选择目录并扫描。',
            onRefresh: _refresh,
          );
        }
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            itemCount: catalogs.length,
            itemBuilder: (context, index) =>
                _buildCatalog(context, catalogs[index]),
          ),
        );
      },
    );
  }

  Widget _buildCatalog(BuildContext context, CloudMediaCatalogEntry catalog) {
    final root = catalog.root;
    final rootPath = root['root_path']?.toString() ?? '';
    final works = <Map<String, Object?>>[
      ...catalog.works,
      if (catalog.assets.any((asset) => asset['work_key'] == '.'))
        <String, Object?>{
          'work_key': '.',
          'title': '未关联文件',
          'title_cn': '未关联文件',
        },
    ];
    final workCounts = <String, int>{};
    for (final asset in catalog.assets) {
      final key = asset['work_key']?.toString() ?? '.';
      workCounts[key] = (workCounts[key] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  root['name']?.toString() ?? rootPath,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                '${catalog.works.length} 部作品 · ${catalog.assets.length} 个文件',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (rootPath.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3, bottom: 10),
              child: Text(
                rootPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (works.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('此目录尚无可展示的媒体文件')),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    (constraints.maxWidth / 160).floor().clamp(2, 8).toInt();
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: works.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.68,
                  ),
                  itemBuilder: (context, index) {
                    final work = works[index];
                    final title = _workTitle(work);
                    final poster = work['poster_url']?.toString();
                    final workKey = work['work_key']?.toString() ?? '.';
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _openWork(context, catalog, work, works),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: poster?.startsWith('http') == true
                                  ? CachedNetworkImageWidget(
                                      imageUrl: poster!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __) => const Center(
                                        child: Icon(Icons.movie_outlined),
                                      ),
                                    )
                                  : const ColoredBox(
                                      color: Color(0x18000000),
                                      child: Center(
                                        child: Icon(Icons.movie_outlined),
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${workCounts[workKey] ?? 0} 个文件',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }

  Future<void> _openWork(
    BuildContext context,
    CloudMediaCatalogEntry catalog,
    Map<String, Object?> work,
    List<Map<String, Object?>> works,
  ) async {
    final sourceId = catalog.root['id']?.toString() ?? '';
    await showInViewDialog<void>(
      context: context,
      builder: (_) => CloudMediaWorkDialog(
        sourceId: sourceId,
        work: work,
        works: works,
        onOpenAsset: (assetContext, asset) =>
            _openAsset(assetContext, catalog, work, asset),
      ),
    );
    if (mounted) _refresh();
  }

  Future<void> _openAsset(
    BuildContext context,
    CloudMediaCatalogEntry catalog,
    Map<String, Object?> work,
    Map<String, Object?> asset,
  ) async {
    final root = catalog.root;
    final connectionId = root['connection_id']?.toString() ?? '';
    final connection =
        WebDAVService.instance.getConnectionByIdOrName(connectionId);
    if (connection == null) {
      _showMessage(context, '当前设备尚未映射此 WebDAV 媒体来源');
      return;
    }
    final rootPath = root['root_path']?.toString() ?? '/';
    final relative = asset['relative_path']?.toString() ?? '';
    final fullPath = _joinRoot(rootPath, relative);
    final kind = asset['kind']?.toString() ?? '';
    final category = asset['category']?.toString() ?? '';
    final title = _workTitle(work);
    final fileName = asset['name']?.toString() ?? relative;

    if (category == 'scan' && kind == 'image') {
      final images = catalog.assets
          .where((row) =>
              row['work_key'] == asset['work_key'] &&
              row['category'] == 'scan' &&
              row['kind'] == 'image')
          .toList()
        ..sort((a, b) => _naturalCompare(
              a['relative_path']?.toString() ?? '',
              b['relative_path']?.toString() ?? '',
            ));
      final selected = images.indexWhere(
        (row) => row['relative_path'] == asset['relative_path'],
      );
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CloudScansReaderPage(
            connection: connection,
            rootPath: rootPath,
            images: images,
            initialIndex: selected < 0 ? 0 : selected,
          ),
        ),
      );
      return;
    }

    if (kind == 'cue') {
      try {
        final text = utf8.decode(
          await WebDAVService.instance.readFileBytes(connection, fullPath),
        );
        final tracks = CueSheetParser.parse(text, cuePath: relative);
        if (!context.mounted) return;
        if (tracks.isEmpty) {
          _showMessage(context, 'CUE 文件中没有可播放的曲目');
          return;
        }
        final track = await CloudCueSheetDialog.show(
          context: context,
          title: fileName,
          tracks: tracks,
        );
        if (track == null || !context.mounted) return;
        final audio = catalog.assets.where((row) =>
            row['relative_path'] == track.audioRelativePath &&
            row['kind'] == 'audio' &&
            row['work_key'] == asset['work_key']);
        if (audio.isEmpty) {
          _showMessage(context, '索引中找不到 CUE 引用的音频文件');
          return;
        }
        await _playAudio(
          connection,
          rootPath,
          audio.first,
          title,
          track.title,
          startPosition: track.startPosition,
        );
      } catch (error) {
        if (context.mounted) _showMessage(context, '读取 CUE 文件失败：$error');
      }
      return;
    }

    final filePath = MediaSourceUtils.buildWebDavPath(connection.id, fullPath);
    if (kind == 'audio' && category == 'cd') {
      await _playAudio(connection, rootPath, asset, title, fileName);
      return;
    }
    if (kind == 'video') {
      widget.onPlayEpisode(WatchHistoryItem(
        filePath: filePath,
        animeName: title,
        episodeTitle: fileName,
        animeId: int.tryParse(work['bangumi_id']?.toString() ?? ''),
        duration: 0,
        lastPosition: 0,
        watchProgress: 0,
        lastWatchTime: DateTime.now(),
      ));
    }
  }

  Future<void> _playAudio(
    WebDAVConnection connection,
    String rootPath,
    Map<String, Object?> asset,
    String title,
    String subtitle, {
    Duration? startPosition,
  }) async {
    final relative = asset['relative_path']?.toString() ?? '';
    final fullPath = _joinRoot(rootPath, relative);
    final filePath = MediaSourceUtils.buildWebDavPath(connection.id, fullPath);
    final history = WatchHistoryItem(
      filePath: filePath,
      animeName: title,
      episodeTitle: subtitle,
      duration: 0,
      lastPosition: startPosition?.inMilliseconds ?? 0,
      watchProgress: 0,
      lastWatchTime: DateTime.now(),
    );
    await PlaybackService().play(PlayableItem(
      videoPath: filePath,
      title: title,
      subtitle: subtitle,
      historyItem: history,
      initialPositionMs: startPosition?.inMilliseconds,
    ));
  }

  void _showMessage(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _workTitle(Map<String, Object?> work) {
    final chinese = work['title_cn']?.toString().trim() ?? '';
    final original = work['title']?.toString().trim() ?? '';
    return chinese.isNotEmpty
        ? chinese
        : (original.isNotEmpty ? original : '未命名作品');
  }

  String _joinRoot(String root, String relative) {
    final normalizedRoot = root.replaceAll('\\', '/');
    final normalizedRelative =
        relative.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
    return p.posix.join(normalizedRoot, normalizedRelative);
  }

  int _naturalCompare(String left, String right) {
    final leftParts = RegExp(r'(\d+|\D+)').allMatches(left.toLowerCase());
    final rightParts = RegExp(r'(\d+|\D+)').allMatches(right.toLowerCase());
    final a = leftParts.map((match) => match.group(0)!).toList();
    final b = rightParts.map((match) => match.group(0)!).toList();
    for (var i = 0; i < a.length && i < b.length; i++) {
      final leftNumber = int.tryParse(a[i]);
      final rightNumber = int.tryParse(b[i]);
      final comparison = leftNumber != null && rightNumber != null
          ? leftNumber.compareTo(rightNumber)
          : a[i].compareTo(b[i]);
      if (comparison != 0) return comparison;
    }
    return a.length.compareTo(b.length);
  }
}

class CloudMediaCatalogEntry {
  const CloudMediaCatalogEntry({
    required this.root,
    required this.works,
    required this.assets,
  });

  final Map<String, Object?> root;
  final List<Map<String, Object?>> works;
  final List<Map<String, Object?>> assets;
}

class _CatalogMessage extends StatelessWidget {
  const _CatalogMessage({required this.message, required this.onRefresh});

  final String message;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新'),
            ),
          ],
        ),
      );
}
