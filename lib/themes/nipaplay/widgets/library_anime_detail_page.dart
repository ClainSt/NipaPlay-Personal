import 'package:provider/provider.dart';
import 'package:nipaplay/providers/watch_history_provider.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/services/bangumi_api_service.dart';
import 'package:nipaplay/services/tmdb_metadata_service.dart';
import 'package:nipaplay/utils/cloud_media_asset_presentation.dart';
import 'package:nipaplay/themes/nipaplay/widgets/adaptive_media_detail_action.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cached_network_image_widget.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cloud_media_work_dialog.dart';
import 'package:nipaplay/utils/app_accent_color.dart';
import 'package:nipaplay/widgets/in_view_dialog.dart';

/// A presentation of the existing cloud catalog. Never scans or writes media relations.
class LibraryAnimeDetailPage extends StatefulWidget {
  const LibraryAnimeDetailPage({
    super.key,
    required this.sourceId,
    required this.work,
    required this.works,
    required this.pathForAsset,
    required this.onPlay,
    required this.onBack,
    this.assetsLoader,
    this.historyLoader,
    this.showAssociationManagement = true,
    this.onManage,
    this.headerActions,
    this.episodeControls,
    this.overlay,
    this.characters = const [],
    this.contentRevision,
    this.reverseEpisodes = false,
  });
  final String sourceId;
  final Map<String, Object?> work;
  final List<Map<String, Object?>> works;
  final String Function(Map<String, Object?>) pathForAsset;
  final Future<void> Function(Map<String, Object?>, bool restart) onPlay;
  final VoidCallback onBack;
  final bool showAssociationManagement;
  final VoidCallback? onManage;
  final Widget? headerActions;
  final Widget? episodeControls;
  final Widget? overlay;
  final List<Map<String, dynamic>> characters;
  final Object? contentRevision;
  final bool reverseEpisodes;
  final Future<List<Map<String, Object?>>> Function()? assetsLoader;
  final Future<List<WatchHistoryItem>> Function()? historyLoader;
  @override
  State<LibraryAnimeDetailPage> createState() => _LibraryAnimeDetailPageState();
}

class _LibraryAnimeDetailPageState extends State<LibraryAnimeDetailPage>
    with WidgetsBindingObserver {
  late Map<String, Object?> _work;
  List<Map<String, Object?>> _assets = [];
  List<Map<String, dynamic>> _characters = [];
  Map<String, WatchHistoryItem> _history = {};
  Map<String, dynamic> _episodeSeasons = {};
  bool _loading = true, _expanded = false, _summaryExpanded = false;
  String _section = 'episode', _filter = '全部';
  String? _error;
  final _rail = ScrollController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _work = widget.work;
    _characters = widget.characters;
    _load();
    _loadCharacters();
  }

  @override
  void didUpdateWidget(covariant LibraryAnimeDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _work = widget.work;
    if (oldWidget.characters != widget.characters &&
        widget.characters.isNotEmpty) {
      _characters = widget.characters;
    }
    if (oldWidget.contentRevision != widget.contentRevision ||
        oldWidget.work != widget.work ||
        oldWidget.sourceId != widget.sourceId) {
      _load();
    }
    if (oldWidget.work["bangumi_id"] != widget.work["bangumi_id"]) {
      _loadCharacters();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _historyProvider?.removeListener(_refreshHistory);
    _rail.dispose();
    super.dispose();
  }

  WatchHistoryProvider? _historyProvider;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<WatchHistoryProvider?>();
    if (provider == _historyProvider) return;
    _historyProvider?.removeListener(_refreshHistory);
    _historyProvider = provider;
    provider?.addListener(_refreshHistory);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshHistory();
  }

  Future<void> _refreshHistory() async {
    try {
      final history = await (widget.historyLoader?.call() ??
          WatchHistoryManager.getAllHistory());
      if (mounted) {
        setState(() => _history = {for (final h in history) h.filePath: h});
      }
    } catch (_) {/* Keep the last available playback state. */}
  }

  Map<String, dynamic> get _metadata {
    try {
      final value = jsonDecode(_work['metadata_json']?.toString() ?? '{}');
      return value is Map<String, dynamic> ? value : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _loadCharacters() async {
    final id = int.tryParse(_work['bangumi_id']?.toString() ?? '');
    if (id == null) return;
    try {
      final characters = await BangumiApiService.getPublicSubjectCharacters(id);
      if (mounted) setState(() => _characters = characters);
    } catch (_) {/* Optional metadata does not block the catalog. */}
  }

  int _loadGeneration = 0;
  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final assets = List<Map<String, Object?>>.of(
          await (widget.assetsLoader?.call() ??
              CloudMediaIndexDatabase.instance.getAssets(
                  sourceId: widget.sourceId,
                  workKey: _work['work_key']?.toString() ?? '.')));
      if (!mounted || generation != _loadGeneration) return;
      assets.sort((a, b) {
        final x = num.tryParse(a['episode_number']?.toString() ?? '') ?? 999999;
        final y = num.tryParse(b['episode_number']?.toString() ?? '') ?? 999999;
        final order = x.compareTo(y);
        return order != 0 ? order : '${a['name']}'.compareTo('${b['name']}');
      });
      setState(() {
        _assets = assets.where((a) => a['kind'] == 'video').toList();
        final cached = _metadata['tmdb_episode_seasons'];
        _episodeSeasons =
            cached is Map ? Map<String, dynamic>.from(cached) : {};
        _loading = false;
        _error = null;
      });
      _refreshHistory();
      _loadEpisodeMetadata(generation);
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _loading = false;
          _error = '读取媒体失败，请重试';
        });
      }
    }
  }

  Future<void> _loadEpisodeMetadata(int generation) async {
    final service = TmdbMetadataService();
    try {
      final seasons = await service.loadEpisodeSeasons(
          sourceId: widget.sourceId, work: _work, assets: _assets);
      if (mounted && generation == _loadGeneration) {
        setState(() => _episodeSeasons = seasons);
      }
    } catch (_) {/* Optional metadata must not block playback. */} finally {
      service.close();
    }
  }

  WatchHistoryItem? _watched(Map<String, Object?> a) =>
      _history[widget.pathForAsset(a)];
  List<Map<String, Object?>> get _episodes =>
      (widget.reverseEpisodes ? _assets.reversed : _assets)
          .where((a) => CloudMediaAssetPresentation.category(a) == 'episode')
          .toList();
  double _progress(Map<String, Object?> a) =>
      _watched(a)?.watchProgress ?? (a['progress'] as num?)?.toDouble() ?? 0;
  Map<String, Object?>? get _resume {
    final entries =
        _episodes.where((a) => _progress(a) > 0 && _progress(a) < .95).toList();
    entries.sort((a, b) => (_watched(b)?.lastWatchTime ?? DateTime(1970))
        .compareTo(_watched(a)?.lastWatchTime ?? DateTime(1970)));
    return entries.isNotEmpty
        ? entries.first
        : (_episodes.isEmpty ? null : _episodes.first);
  }

  static String _extraType(Map<String, Object?> a) {
    return CloudMediaAssetPresentation.extraType(a);
  }

  String _label(Map<String, Object?> a) =>
      CloudMediaAssetPresentation.category(a) == 'extra'
          ? _extraType(a)
          : a['episode_number'] == null
              ? '正片'
              : '第 ${a['episode_number']} 集';

  String _assetTitle(Map<String, Object?> asset) {
    if (CloudMediaAssetPresentation.category(asset) == 'extra') {
      return CloudMediaAssetPresentation.extraTitle(asset) ?? _extraType(asset);
    }
    final episode = CloudMediaAssetPresentation.episode(asset, _episodeSeasons);
    final title = episode?['name']?.toString().trim();
    if (title?.isNotEmpty == true) return title!;
    final matchedTitle = asset['episode_title']?.toString().trim();
    return matchedTitle?.isNotEmpty == true ? matchedTitle! : _label(asset);
  }

  String? _thumbnail(Map<String, Object?> asset) {
    final episode = CloudMediaAssetPresentation.episode(asset, _episodeSeasons);
    final still = episode?['still_path']?.toString().trim();
    if (still?.isNotEmpty == true) {
      return 'https://image.tmdb.org/t/p/w500$still';
    }
    final image = asset['still_url']?.toString().trim();
    if (image?.isNotEmpty == true) return image;
    return _watched(asset)?.thumbnailPath;
  }

  Future<void> _manage() async {
    await showInViewDialog<void>(
        context: context,
        builder: (_) => CloudMediaWorkDialog(
            sourceId: widget.sourceId,
            work: _work,
            works: widget.works,
            onOpenAsset: (_, asset) => widget.onPlay(asset, false)));
    if (!mounted) return;
    final works = await CloudMediaIndexDatabase.instance
        .getWorks(sourceId: widget.sourceId);
    if (!mounted) return;
    for (final w in works) {
      if (w['work_key'] == _work['work_key']) _work = w;
    }
    await _load();
  }

  Widget _image(String? url,
      {BoxFit fit = BoxFit.cover, Alignment alignment = Alignment.center}) {
    const placeholder = ColoredBox(
        color: Color(0xFF2B2B2B),
        child: Center(
            child:
                Icon(Icons.movie_outlined, color: Colors.white38, size: 32)));
    if (url == null || url.isEmpty) return placeholder;
    if (url.startsWith('assets/')) {
      return Image.asset(url,
          fit: fit,
          alignment: alignment,
          errorBuilder: (_, __, ___) => placeholder);
    }
    if (!url.startsWith('http')) {
      return Image.file(File(url),
          fit: fit,
          alignment: alignment,
          errorBuilder: (_, __, ___) => placeholder);
    }
    return CachedNetworkImageWidget(
        imageUrl: url,
        fit: fit,
        alignment: alignment,
        errorBuilder: (_, __) => placeholder);
  }

  String? get _fanart {
    final raw = _metadata['backdrop_path']?.toString();
    if (raw != null && raw.isNotEmpty) {
      return 'https://image.tmdb.org/t/p/original$raw';
    }
    return (_metadata['backdrop_url'] ?? _metadata['fanart'])?.toString();
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppAccentColors.current;
    final meta = _metadata;
    final date =
        (meta['first_air_date'] ?? meta['release_date'] ?? meta['date'])
                ?.toString() ??
            '';
    final genres = (meta['genres'] is List ? meta['genres'] as List : const [])
        .map((g) => g is Map ? '${g['name']}' : g.toString())
        .toList();
    final tags = (meta['tags'] is List ? meta['tags'] as List : const [])
        .whereType<Map>()
        .take(8)
        .map((g) => '${g['name']}')
        .toList();
    final title = (_work['title_cn']?.toString().isNotEmpty == true
                ? _work['title_cn']
                : _work['title'])
            ?.toString() ??
        '未命名作品';
    final visible = (widget.reverseEpisodes && _section == "episode"
            ? _assets.reversed
            : _assets)
        .where((a) =>
            CloudMediaAssetPresentation.category(a) == _section &&
            (_section != 'extra' ||
                _filter == '全部' ||
                _extraType(a) == _filter))
        .toList();
    return Material(
        color: const Color(0xFF1F1F1F),
        child: DefaultTextStyle(
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                color: Colors.white, locale: const Locale('zh', 'Hans')),
            child: LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 760;
              final contentWidth =
                  (constraints.maxWidth * .72).clamp(700.0, 1180.0);
              final posterWidth =
                  wide ? (contentWidth * .21).clamp(180.0, 246.0) : 150.0;
              final information = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: wide ? 30 : 24,
                            fontWeight: FontWeight.w700,
                            height: 1.25)),
                    const SizedBox(height: 12),
                    Wrap(spacing: 18, runSpacing: 8, children: [
                      if (_work['rating'] != null)
                        Text(
                            '★ ${num.tryParse('${_work['rating']}')?.toStringAsFixed(1) ?? _work['rating']}',
                            style: TextStyle(
                                color: accent, fontWeight: FontWeight.w600)),
                      if (date.length >= 4)
                        Text(date.substring(0, 4),
                            style: const TextStyle(color: Colors.white70)),
                      Text('${_episodes.length} 集',
                          style: const TextStyle(color: Colors.white70)),
                      ...genres.map((g) => Text(g,
                          style: const TextStyle(color: Colors.white70))),
                    ]),
                    const SizedBox(height: 20),
                    widget.headerActions ??
                        Wrap(spacing: 10, runSpacing: 10, children: [
                          AdaptiveMediaDetailActionButton(
                              icon: Icons.play_arrow_rounded,
                              label: _resume != null && _progress(_resume!) > 0
                                  ? '继续 ${_label(_resume!)}'
                                  : '开始播放',
                              emphasis: MediaDetailActionEmphasis.primary,
                              onPressed: _resume == null
                                  ? null
                                  : () => widget.onPlay(_resume!, false)),
                          AdaptiveMediaDetailActionButton(
                              icon: Icons.replay,
                              label: '从头播放',
                              onPressed: _episodes.isEmpty
                                  ? null
                                  : () => widget.onPlay(_episodes.first, true)),
                        ]),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: tags
                              .map((tag) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 9, vertical: 4),
                                  decoration: BoxDecoration(
                                      color: Colors.black26,
                                      borderRadius: BorderRadius.circular(5)),
                                  child: Text(tag,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.white70))))
                              .toList())
                    ],
                    const SizedBox(height: 16),
                    Text(
                        _work['overview']?.toString().trim().isNotEmpty == true
                            ? '${_work['overview']}'
                            : '暂无作品简介',
                        maxLines: _summaryExpanded ? null : 5,
                        overflow: _summaryExpanded
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xFFCCCCCC),
                            height: 1.8)),
                    if ((_work['overview']?.toString().length ?? 0) > 180)
                      TextButton(
                          onPressed: () => setState(
                              () => _summaryExpanded = !_summaryExpanded),
                          child: Text(_summaryExpanded ? '收起简介' : '展开简介')),
                  ]);
              return Stack(fit: StackFit.expand, children: [
                if (_fanart != null) Positioned.fill(child: _image(_fanart)),
                const Positioned.fill(
                    child: DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                      Color(0xA61F1F1F),
                      Color(0xC71F1F1F),
                      Color(0xFF1F1F1F)
                    ],
                                stops: [
                      0,
                      .6,
                      1
                    ])))),
                SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                        wide ? 28 : 16, 12, wide ? 28 : 16, 40),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            IconButton(
                                onPressed: widget.onBack,
                                tooltip: '返回媒体库',
                                icon: const Icon(Icons.arrow_back,
                                    color: Colors.white)),
                            const Spacer(),
                            if (widget.showAssociationManagement)
                              TextButton.icon(
                                  onPressed: widget.onManage ?? _manage,
                                  icon:
                                      const Icon(Icons.edit_outlined, size: 18),
                                  label: const Text('关联管理'))
                          ]),
                          Center(
                              child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                      maxWidth: wide ? contentWidth : 600),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(height: wide ? 18 : 8),
                                        if (wide)
                                          Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                SizedBox(
                                                    width: posterWidth,
                                                    height: posterWidth * 1.5,
                                                    child: ClipRRect(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(8),
                                                        child: _image(
                                                            _work['poster_url']
                                                                ?.toString()))),
                                                const SizedBox(width: 32),
                                                Expanded(child: information),
                                              ])
                                        else ...[
                                          Center(
                                              child: SizedBox(
                                                  width: posterWidth,
                                                  height: posterWidth * 1.5,
                                                  child: ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8),
                                                      child: _image(
                                                          _work['poster_url']
                                                              ?.toString())))),
                                          const SizedBox(height: 22),
                                          information,
                                        ],
                                        if (_characters.isNotEmpty) ...[
                                          const SizedBox(height: 26),
                                          const Text('角色',
                                              style: TextStyle(
                                                  color: Colors.white70)),
                                          const SizedBox(height: 12),
                                          SizedBox(
                                              height: 136,
                                              child: ScrollConfiguration(
                                                  behavior:
                                                      const _DetailScrollBehavior(),
                                                  child: ListView.separated(
                                                      scrollDirection:
                                                          Axis.horizontal,
                                                      itemCount:
                                                          _characters.length,
                                                      separatorBuilder:
                                                          (_, __) =>
                                                              const SizedBox(
                                                                  width: 16),
                                                      itemBuilder: (_, i) {
                                                        final c =
                                                            _characters[i];
                                                        final actors =
                                                            c['actors'] is List
                                                                ? c['actors']
                                                                    as List
                                                                : [];
                                                        final images =
                                                            c['images'];
                                                        return SizedBox(
                                                            width: 96,
                                                            child: Column(
                                                                children: [
                                                                  SizedBox(
                                                                      width: 80,
                                                                      height:
                                                                          80,
                                                                      child: ClipOval(
                                                                          child: _image(
                                                                              images is Map ? (images['medium'] ?? images['small'])?.toString() : null,
                                                                              alignment: Alignment.topCenter))),
                                                                  const SizedBox(
                                                                      height:
                                                                          7),
                                                                  Text(
                                                                      '${c['name'] ?? ''}',
                                                                      maxLines:
                                                                          1,
                                                                      overflow:
                                                                          TextOverflow
                                                                              .ellipsis,
                                                                      style: const TextStyle(
                                                                          fontSize:
                                                                              12)),
                                                                  const SizedBox(
                                                                      height:
                                                                          3),
                                                                  Text(
                                                                      actors
                                                                          .whereType<
                                                                              Map>()
                                                                          .map((a) => a[
                                                                              'name'])
                                                                          .join(
                                                                              ' / '),
                                                                      maxLines:
                                                                          1,
                                                                      overflow:
                                                                          TextOverflow
                                                                              .ellipsis,
                                                                      style: const TextStyle(
                                                                          fontSize:
                                                                              11,
                                                                          color:
                                                                              Colors.white54))
                                                                ]));
                                                      })))
                                        ],
                                        const SizedBox(height: 26),
                                        if (widget.episodeControls != null)
                                          widget.episodeControls!,
                                        SizedBox(
                                            width: double.infinity,
                                            child: Wrap(
                                                alignment:
                                                    WrapAlignment.spaceBetween,
                                                crossAxisAlignment:
                                                    WrapCrossAlignment.center,
                                                spacing: 24,
                                                runSpacing: 8,
                                                children: [
                                                  Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        for (final entry
                                                            in const {
                                                          'episode': '正片',
                                                          'extra': '特典'
                                                        }.entries)
                                                          Padding(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .only(
                                                                      right:
                                                                          20),
                                                              child: InkWell(
                                                                  onTap: () =>
                                                                      setState(
                                                                          () {
                                                                        _section =
                                                                            entry.key;
                                                                        _filter =
                                                                            '全部';
                                                                        _expanded =
                                                                            false;
                                                                      }),
                                                                  child: Container(
                                                                      padding: const EdgeInsets
                                                                          .symmetric(
                                                                          vertical:
                                                                              10),
                                                                      decoration:
                                                                          BoxDecoration(border: Border(bottom: BorderSide(color: _section == entry.key ? accent : Colors.transparent, width: 3))),
                                                                      child: Text('${entry.value}  ${_assets.where((a) => CloudMediaAssetPresentation.category(a) == entry.key).length}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _section == entry.key ? accent : Colors.white60)))))
                                                      ]),
                                                  TextButton.icon(
                                                      onPressed: () => setState(
                                                          () => _expanded =
                                                              !_expanded),
                                                      icon: Icon(
                                                          _expanded
                                                              ? Icons
                                                                  .view_carousel_outlined
                                                              : Icons
                                                                  .view_list_outlined,
                                                          size: 18),
                                                      label: Text(_expanded
                                                          ? '收起列表'
                                                          : '完整列表')),
                                                ])),
                                        if (_section == 'extra')
                                          Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 12),
                                              child: Wrap(
                                                  spacing: 8,
                                                  runSpacing: 8,
                                                  children: [
                                                    '全部',
                                                    ..._assets
                                                        .where((a) =>
                                                            CloudMediaAssetPresentation
                                                                .category(a) ==
                                                            'extra')
                                                        .map(_extraType)
                                                        .toSet()
                                                  ]
                                                      .map((f) => ChoiceChip(
                                                          label: Text(f),
                                                          selected:
                                                              _filter == f,
                                                          onSelected: (_) =>
                                                              setState(() =>
                                                                  _filter = f),
                                                          selectedColor:
                                                              accent.withValues(
                                                                  alpha: .25)))
                                                      .toList())),
                                        const SizedBox(height: 14),
                                        if (_loading)
                                          const Center(
                                              child:
                                                  CircularProgressIndicator())
                                        else if (_error != null)
                                          TextButton(
                                              onPressed: _load,
                                              child: Text(_error!))
                                        else if (visible.isEmpty)
                                          Padding(
                                              padding: const EdgeInsets.symmetric(
                                                  vertical: 30),
                                              child: Text(_section == 'extra' ? '暂无此分类的特典，可在关联管理中检查文件归属' : '暂无已关联正片，可在关联管理中检查文件归属',
                                                  style: const TextStyle(
                                                      color: Colors.white60)))
                                        else if (_expanded)
                                          LayoutBuilder(
                                              builder: (_, c) => Wrap(
                                                  spacing: 12,
                                                  runSpacing: 18,
                                                  children: visible
                                                      .map((a) => SizedBox(
                                                          width: (c.maxWidth - 12 * ((c.maxWidth / 210).floor().clamp(1, 6) - 1)) /
                                                              (c.maxWidth / 210)
                                                                  .floor()
                                                                  .clamp(1, 6),
                                                          child: _tile(a)))
                                                      .toList()))
                                        else
                                          SizedBox(
                                              height: 190,
                                              child: ScrollConfiguration(
                                                  behavior:
                                                      const _DetailScrollBehavior(),
                                                  child: Scrollbar(controller: _rail, thumbVisibility: true, child: ListView.separated(controller: _rail, scrollDirection: Axis.horizontal, itemCount: visible.length, separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (_, i) => SizedBox(width: wide ? (contentWidth - 48) / 5 : 220, child: _tile(visible[i])))))),
                                      ]))),
                        ])),
                if (widget.overlay != null) widget.overlay!,
              ]);
            })));
  }

  Widget _tile(Map<String, Object?> asset) {
    final progress = _progress(asset).clamp(0.0, 1.0);
    final resume = _resume != null &&
        _resume!['relative_path'] == asset['relative_path'] &&
        progress > 0;
    final status = progress >= .95
        ? '已看'
        : resume
            ? '继续播放'
            : progress > 0
                ? '观看中'
                : '未看';
    final accent = AppAccentColors.current;
    return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => widget.onPlay(asset, false),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: resume ? accent : Colors.white12,
                              width: resume ? 2 : 1)),
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: Stack(fit: StackFit.expand, children: [
                            _image(_thumbnail(asset)),
                            Positioned(
                                top: 6, left: 6, child: _badge(_label(asset))),
                            Positioned(
                                top: 6,
                                right: 6,
                                child: _badge(status,
                                    color: resume ? accent : Colors.black54)),
                            if (progress > 0)
                              Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: LinearProgressIndicator(
                                      value: progress,
                                      color: accent,
                                      backgroundColor: Colors.black38,
                                      minHeight: 3)),
                          ])))),
              const SizedBox(height: 8),
              Text(_assetTitle(asset),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, height: 1.4, color: Colors.white70)),
            ]));
  }

  Widget _badge(String text, {Color color = Colors.black54}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
      child: Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 10)));
}

class _DetailScrollBehavior extends MaterialScrollBehavior {
  const _DetailScrollBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices =>
      {...super.dragDevices, PointerDeviceKind.mouse};
}
