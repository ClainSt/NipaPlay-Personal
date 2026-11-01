import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nipaplay/services/cloud_media_index_database.dart';
import 'package:nipaplay/widgets/in_view_dialog.dart';
import 'package:nipaplay/services/auto_sync_service.dart';
import 'package:nipaplay/services/cloud_media_scraper.dart';

typedef CloudAssetOpenCallback = Future<void> Function(
  BuildContext context,
  Map<String, Object?> asset,
);

/// Detail view for one indexed work, with local classification and relation controls.
class CloudMediaWorkDialog extends StatefulWidget {
  const CloudMediaWorkDialog({
    super.key,
    required this.sourceId,
    required this.work,
    required this.works,
    required this.onOpenAsset,
  });

  final String sourceId;
  final Map<String, Object?> work;
  final List<Map<String, Object?>> works;
  final CloudAssetOpenCallback onOpenAsset;

  @override
  State<CloudMediaWorkDialog> createState() => _CloudMediaWorkDialogState();
}

class _CloudMediaWorkDialogState extends State<CloudMediaWorkDialog> {
  static const _categories = <String, String>{
    'episode': '正片',
    'extra': '特典',
    'cd': 'CDs',
    'scan': 'Scans',
    'review': '待确认',
    'metadata': '其他',
  };

  late Future<List<Map<String, Object?>>> _assetsFuture;
  late List<Map<String, Object?>> _works;
  late Map<String, Object?> _work;
  String _filter = 'all';
  bool _isRescrapingMetadata = false;

  @override
  void initState() {
    super.initState();
    _works = List<Map<String, Object?>>.of(widget.works);
    _work = Map<String, Object?>.of(widget.work);
    _assetsFuture =
        CloudMediaIndexDatabase.instance.getAssets(sourceId: widget.sourceId);
  }

  void _reload() {
    setState(() {
      _assetsFuture =
          CloudMediaIndexDatabase.instance.getAssets(sourceId: widget.sourceId);
    });
  }

  bool get _canRescrapeMetadata {
    final id = _work['tmdb_tv_id'] ??
        _work['tmdb_movie_id'] ??
        _work['tmdb_unknown_id'] ??
        _work['tmdb_id'];
    return int.tryParse(id?.toString() ?? '') != null &&
        _work['relation_locked'] != 1;
  }

  Future<void> _rescrapeMetadata() async {
    final workKey = _work['work_key']?.toString() ?? '.';
    setState(() => _isRescrapingMetadata = true);
    var succeeded = false;
    try {
      succeeded = await CloudMediaScraper().rescrapeWork(
        sourceId: widget.sourceId,
        workKey: workKey,
      );
      if (succeeded) {
        final works = await CloudMediaIndexDatabase.instance
            .getWorks(sourceId: widget.sourceId);
        if (!mounted) return;
        final refreshed = works.where((entry) => entry['work_key'] == workKey);
        if (refreshed.isNotEmpty) {
          setState(() {
            _works = works;
            _work = Map<String, Object?>.of(refreshed.first);
          });
        }
        unawaited(AutoSyncService.instance.scheduleSyncAfterCatalogChange());
      }
    } catch (_) {
      succeeded = false;
    } finally {
      if (mounted) setState(() => _isRescrapingMetadata = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            succeeded ? '作品元数据已更新并加入同步队列' : '未能获取元数据，请检查 TMDB 令牌、网络和作品 ID'),
      ),
    );
  }

  Future<void> _editAsset(Map<String, Object?> asset) async {
    var selectedWorkKey = asset['work_key']?.toString() ?? '.';
    var selectedCategory = asset['category']?.toString() ?? 'review';
    final changed = await showInViewDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('修改文件归属'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(asset['name']?.toString() ?? ''),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _categories.containsKey(selectedCategory)
                      ? selectedCategory
                      : 'review',
                  decoration: const InputDecoration(labelText: '内容分类'),
                  items: [
                    for (final entry in _categories.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedCategory = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _works.any(
                    (work) => work['work_key'] == selectedWorkKey,
                  )
                      ? selectedWorkKey
                      : '.',
                  decoration: const InputDecoration(labelText: '所属作品'),
                  items: [
                    const DropdownMenuItem(value: '.', child: Text('未关联')),
                    for (final work in _works)
                      DropdownMenuItem(
                        value: work['work_key']?.toString() ?? '.',
                        child: Text(_workTitle(work),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedWorkKey = value);
                    }
                  },
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _createWork(
                      setDialogState: setDialogState,
                      setSelectedWorkKey: (value) => selectedWorkKey = value,
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('新建作品后关联'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存并锁定'),
            ),
          ],
        ),
      ),
    );
    if (changed != true || !mounted) return;
    await CloudMediaIndexDatabase.instance.updateAssetRelation(
      sourceId: widget.sourceId,
      relativePath: asset['relative_path']?.toString() ?? '',
      workKey: selectedWorkKey,
      category: selectedCategory,
    );
    unawaited(AutoSyncService.instance.scheduleSyncAfterCatalogChange());
    _reload();
  }

  Future<void> _undoAsset(Map<String, Object?> asset) async {
    final undone =
        await CloudMediaIndexDatabase.instance.undoLastAssetRelationChange(
      sourceId: widget.sourceId,
      relativePath: asset['relative_path']?.toString() ?? '',
    );
    unawaited(AutoSyncService.instance.scheduleSyncAfterCatalogChange());
    if (!mounted) return;
    if (undone) _reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(undone ? '已撤销上次修改' : '没有可撤销的修改')),
    );
  }

  Future<void> _createWork({
    required StateSetter setDialogState,
    required ValueChanged<String> setSelectedWorkKey,
  }) async {
    final controller = TextEditingController();
    final title = await showInViewDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建作品'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '作品名称'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.trim().isEmpty || !mounted) return;
    final workKey = await CloudMediaIndexDatabase.instance.createManualWork(
      sourceId: widget.sourceId,
      title: title,
    );
    unawaited(AutoSyncService.instance.scheduleSyncAfterCatalogChange());
    if (!mounted) return;
    setState(() => _works.add({
          'work_key': workKey,
          'title': title,
          'title_cn': title,
        }));
    setDialogState(() => setSelectedWorkKey(workKey));
  }

  @override
  Widget build(BuildContext context) {
    final workKey = _work['work_key']?.toString() ?? '.';
    final title = _workTitle(_work);
    return AlertDialog(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 760,
        height: 560,
        child: FutureBuilder<List<Map<String, Object?>>>(
          future: _assetsFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('读取作品文件失败：${snapshot.error}'));
            }
            final all = snapshot.data;
            if (all == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final related =
                all.where((asset) => asset['work_key'] == workKey).toList();
            final tabs = <(String, String)>[
              ('all', '全部'),
              for (final entry in _categories.entries) (entry.key, entry.value),
            ];
            final shown = _filter == 'all'
                ? related
                : related
                    .where((asset) => asset['category'] == _filter)
                    .toList();
            return Column(
              children: [
                if (_work['overview']?.toString().isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _work['overview'].toString(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (key, label) in tabs)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                                '$label (${key == 'all' ? related.length : related.where((asset) => asset['category'] == key).length})'),
                            selected: _filter == key,
                            onSelected: (_) => setState(() => _filter = key),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: shown.isEmpty
                      ? const Center(child: Text('此分类暂无文件'))
                      : ListView.separated(
                          itemCount: shown.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final asset = shown[index];
                            final category =
                                asset['category']?.toString() ?? '';
                            final openable = const {
                                  'episode',
                                  'extra',
                                  'cd',
                                  'scan'
                                }.contains(category) ||
                                asset['kind'] == 'cue';
                            return ListTile(
                              leading: Icon(_iconFor(asset)),
                              title: Text(asset['name']?.toString() ?? '',
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${_categories[category] ?? category} · ${asset['relative_path'] ?? ''}'
                                '${asset['relation_locked'] == 1 ? ' · 已锁定' : ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Wrap(
                                spacing: 0,
                                children: [
                                  if (openable)
                                    IconButton(
                                      tooltip: '打开',
                                      onPressed: () =>
                                          widget.onOpenAsset(context, asset),
                                      icon: const Icon(Icons.open_in_new),
                                    ),
                                  IconButton(
                                    tooltip: '修改归属或分类',
                                    onPressed: () => _editAsset(asset),
                                    icon: const Icon(Icons.tune),
                                  ),
                                  IconButton(
                                    tooltip: '撤销上次修改',
                                    onPressed: () => _undoAsset(asset),
                                    icon: const Icon(Icons.undo),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _isRescrapingMetadata || !_canRescrapeMetadata
              ? null
              : _rescrapeMetadata,
          icon: _isRescrapingMetadata
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          label: const Text('重新刮削元数据'),
        ),
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }

  static String _workTitle(Map<String, Object?> work) {
    final cn = work['title_cn']?.toString() ?? '';
    final title = work['title']?.toString() ?? '';
    return cn.isNotEmpty ? cn : title;
  }

  static IconData _iconFor(Map<String, Object?> asset) {
    if (asset['kind'] == 'cue') return Icons.queue_music;
    switch (asset['category']) {
      case 'episode':
      case 'extra':
        return Icons.movie_outlined;
      case 'cd':
        return Icons.album_outlined;
      case 'scan':
        return Icons.menu_book_outlined;
      default:
        return Icons.help_outline;
    }
  }
}
