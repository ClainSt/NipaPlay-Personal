import 'dart:async';

import 'package:nipaplay/themes/nipaplay/widgets/library_anime_detail_page.dart';
import 'package:nipaplay/models/playable_item.dart';
import 'package:nipaplay/services/playback_service.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/cloud_media_scanner.dart';
import 'package:nipaplay/services/cloud_media_scan_progress.dart';
import 'package:nipaplay/services/auto_sync_service.dart';
import 'package:nipaplay/services/webdav_service.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cached_network_image_widget.dart';
import 'package:nipaplay/utils/media_source_utils.dart';
import 'package:nipaplay/utils/media_identity_resolver.dart';

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
  int _lastCompletedScanRunId = 0;

  @override
  void initState() {
    super.initState();
    _lastCompletedScanRunId = CloudMediaScanProgress.instance.runId;
    CloudMediaScanProgress.instance.addListener(_onScanProgressChanged);
    _catalogsFuture = _loadCatalogs();
  }

  @override
  void dispose() {
    CloudMediaScanProgress.instance.removeListener(_onScanProgressChanged);
    super.dispose();
  }

  void _onScanProgressChanged() {
    final progress = CloudMediaScanProgress.instance;
    if (!mounted ||
        progress.isScanning ||
        progress.phase != CloudMediaScanPhase.completed ||
        progress.runId == _lastCompletedScanRunId) {
      return;
    }
    _lastCompletedScanRunId = progress.runId;
    _refresh();
  }

  Future<List<CloudMediaCatalogEntry>> _loadCatalogs() async {
    final loader = widget.catalogLoader;
    if (loader != null) return loader();
    final database = CloudMediaIndexDatabase.instance;
    final repairedSummaries = await database.repairProviderTranslationCredits();
    if (repairedSummaries > 0) {
      unawaited(AutoSyncService.instance.scheduleSyncAfterCatalogChange());
    }
    final removedDuplicateRoots =
        await database.deduplicateEquivalentLibraryRoots();
    if (removedDuplicateRoots > 0) {
      unawaited(AutoSyncService.instance.scheduleSyncAfterCatalogChange());
    }
    final roots = (await database.getLibraryRoots())
        .where((root) =>
            !(root['connection_id']?.toString().startsWith('local:') ?? false))
        .toList();
    final catalogs = <CloudMediaCatalogEntry>[];
    for (final root in roots) {
      final id = root['id']?.toString() ?? '';
      final rootPath = root['root_path']?.toString() ?? '';
      final works = await database.getWorks(sourceId: id);
      if (CloudMediaScanner.parseTmdbId(rootPath) != null) {
        final normalizedRoot = rootPath.replaceAll('\\', '/');
        final rootWorkKey = p.posix.basename(
          normalizedRoot.replaceFirst(RegExp(r'/+$'), ''),
        );
        final tmdbId = CloudMediaScanner.parseTmdbId(rootPath);
        final matchingWork = works.where((work) {
          final workTmdbId = int.tryParse(
            (work['tmdb_tv_id'] ??
                        work['tmdb_movie_id'] ??
                        work['tmdb_unknown_id'] ??
                        work['tmdb_id'])
                    ?.toString() ??
                '',
          );
          return work['work_key'] != '.' && workTmdbId == tmdbId;
        });
        final workKey = matchingWork.isEmpty
            ? rootWorkKey
            : matchingWork.first['work_key']?.toString() ?? rootWorkKey;
        await database.assignUnassociatedVideosToWork(
          sourceId: id,
          workKey: workKey,
        );
      }
      catalogs.add(CloudMediaCatalogEntry(
        root: root,
        works: works,
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
        final cards = <_CloudWorkCard>[];
        for (final catalog in catalogs) {
          cards.addAll(_workCards(catalog));
        }
        if (cards.isEmpty) {
          return const _CatalogMessage(
            message: '当前媒体库尚无可展示的作品',
            onRefresh: null,
          );
        }
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth < 600
                  ? 3
                  : (constraints.maxWidth / 190).floor().clamp(3, 8).toInt();
              final cardWidth =
                  (constraints.maxWidth - 40 - 12 * (columns - 1)) / columns;
              final titleStyle = DefaultTextStyle.of(context)
                  .style
                  .merge(_posterTitleStyle(context));
              var titleHeight = 0.0;
              for (final card in cards) {
                final painter = TextPainter(
                  text:
                      TextSpan(text: _workTitle(card.work), style: titleStyle),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                  maxLines: 3,
                  ellipsis: '…',
                )..layout(maxWidth: cardWidth);
                if (painter.height > titleHeight) titleHeight = painter.height;
                painter.dispose();
              }
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                itemCount: cards.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  mainAxisExtent: cardWidth * 1.5 + 6 + titleHeight,
                ),
                itemBuilder: (context, index) {
                  final card = cards[index];
                  return _buildWorkCard(context, card);
                },
              );
            },
          ),
        );
      },
    );
  }

  List<_CloudWorkCard> _workCards(CloudMediaCatalogEntry catalog) {
    final videoAssets = catalog.assets
        .where((asset) => asset['kind']?.toString() == 'video')
        .toList(growable: false);
    final videoWorkKeys = videoAssets
        .map((asset) => asset['work_key']?.toString() ?? '.')
        .toSet();
    final works = <Map<String, Object?>>[
      ...catalog.works.where((work) =>
          work['work_key'] != '.' &&
          videoWorkKeys.contains(work['work_key']?.toString() ?? '.')),
      if (videoAssets.any((asset) => asset['work_key'] == '.'))
        <String, Object?>{
          'work_key': '.',
          'title': '未关联文件',
          'title_cn': '未关联文件',
        },
    ];
    return works
        .map((work) => _CloudWorkCard(
              catalog: catalog,
              work: work,
              works: works,
            ))
        .toList(growable: false);
  }

  Widget _buildWorkCard(BuildContext context, _CloudWorkCard card) {
    final work = card.work;
    final title = _workTitle(work);
    final poster = work['poster_url']?.toString();
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _openWork(
        context,
        card.catalog,
        work,
        card.works,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
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
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: _posterTitleStyle(context),
          ),
        ],
      ),
    );
  }

  TextStyle _posterTitleStyle(BuildContext context) => TextStyle(
        fontSize: MediaQuery.sizeOf(context).width < 600 ? 14 : 16,
        height: 1.2,
        fontWeight: FontWeight.w600,
      );

  Future<void> _openWork(
    BuildContext context,
    CloudMediaCatalogEntry catalog,
    Map<String, Object?> work,
    List<Map<String, Object?>> works,
  ) async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
          builder: (routeContext) => Scaffold(
                backgroundColor: const Color(0xFF1F1F1F),
                body: SafeArea(
                    child: LibraryAnimeDetailPage(
                  sourceId: catalog.root['id']?.toString() ?? '',
                  work: work,
                  works: works,
                  pathForAsset: (asset) => _assetPath(catalog, asset),
                  onBack: () => Navigator.of(routeContext).pop(),
                  onPlay: (asset, restart) => _openAsset(
                      routeContext, catalog, work, asset,
                      restart: restart),
                )),
              )),
    );
  }

  Future<void> _openAsset(
    BuildContext context,
    CloudMediaCatalogEntry catalog,
    Map<String, Object?> work,
    Map<String, Object?> asset, {
    bool restart = false,
  }) async {
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
    final title = _workTitle(work);
    final fileName = asset['name']?.toString() ?? relative;
    final filePath = MediaSourceUtils.buildWebDavPath(connection.id, fullPath);
    if (kind == 'video') {
      final previous = await WatchHistoryManager.getHistoryItem(filePath);
      final item = previous ??
          WatchHistoryItem(
            filePath: filePath,
            animeName: title,
            episodeTitle: fileName,
            animeId: int.tryParse(work['bangumi_id']?.toString() ?? ''),
            duration: 0,
            lastPosition: 0,
            watchProgress: 0,
            lastWatchTime: DateTime.now(),
            mediaKey: MediaIdentityResolver.forPath(filePath),
          );
      if (restart) {
        await PlaybackService().play(PlayableItem(
            videoPath: filePath,
            title: title,
            subtitle: item.episodeTitle,
            animeId: item.animeId,
            episodeId: item.episodeId,
            historyItem: item.copyWith(lastPosition: 0, watchProgress: 0),
            initialPositionMs: 0));
      } else {
        widget.onPlayEpisode(item);
      }
    }
  }

  String _assetPath(
      CloudMediaCatalogEntry catalog, Map<String, Object?> asset) {
    final connectionId = catalog.root['connection_id']?.toString() ?? '';
    final connection =
        WebDAVService.instance.getConnectionByIdOrName(connectionId);
    return MediaSourceUtils.buildWebDavPath(
        connection?.id ?? connectionId,
        _joinRoot(catalog.root['root_path']?.toString() ?? '/',
            asset['relative_path']?.toString() ?? ''));
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

class _CloudWorkCard {
  const _CloudWorkCard({
    required this.catalog,
    required this.work,
    required this.works,
  });

  final CloudMediaCatalogEntry catalog;
  final Map<String, Object?> work;
  final List<Map<String, Object?>> works;
}

class _CatalogMessage extends StatelessWidget {
  const _CatalogMessage({required this.message, required this.onRefresh});

  final String message;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            if (onRefresh != null)
              OutlinedButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新'),
              ),
          ],
        ),
      );
}
