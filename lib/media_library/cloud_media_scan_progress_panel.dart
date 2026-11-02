import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:nipaplay/services/cloud_media_scan_progress.dart';
import 'package:nipaplay/widgets/in_view_dialog.dart';

Future<void> showCloudMediaScanProgressDialog(BuildContext context) async {
  await showInViewDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: const _CloudMediaScanProgressDetails(),
      ),
    ),
  );
}

class _CloudMediaScanProgressDetails extends StatelessWidget {
  const _CloudMediaScanProgressDetails();

  @override
  Widget build(BuildContext context) {
    final progress = CloudMediaScanProgress.instance;
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final isFailed = progress.phase == CloudMediaScanPhase.failed;
        final isEmpty = !progress.hasActivity;
        return Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '刮削进度',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: Text('暂无扫描任务。选择 WebDAV 文件夹并开始刮削后，进度会显示在这里。'),
                  ),
                )
              else ...[
                Text(
                  progress.source,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  progress.rootPath,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  progress.message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isFailed ? theme.colorScheme.error : null,
                  ),
                ),
                if (progress.isScanning) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress.fraction),
                ],
                const SizedBox(height: 18),
                _ProgressDetailRow(
                  label: '已检查目录',
                  value: '${progress.directoriesVisited}',
                ),
                _ProgressDetailRow(
                  label: '发现视频',
                  value: '${progress.videosFound}',
                ),
                if (progress.phase == CloudMediaScanPhase.indexing)
                  _ProgressDetailRow(
                    label: '索引文件',
                    value: '${progress.filesIndexed}/${progress.totalFiles}',
                  ),
                if (progress.totalWorks > 0)
                  _ProgressDetailRow(
                    label: '匹配作品',
                    value: '${progress.processedWorks}/${progress.totalWorks}',
                  ),
                if (!progress.isScanning && !isFailed)
                  _ProgressDetailRow(
                    label: '匹配结果',
                    value:
                        '${progress.matchedWorks} 部成功 · ${progress.failedWorks} 部待确认',
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    children: [
                      if (!progress.isScanning && !isEmpty)
                        TextButton(
                          onPressed: progress.dismiss,
                          child: const Text('清除记录'),
                        ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ProgressDetailRow extends StatelessWidget {
  const _ProgressDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, textAlign: TextAlign.end),
        ],
      ),
    );
  }
}

class CloudMediaScanProgressPanel extends StatelessWidget {
  const CloudMediaScanProgressPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final progress = CloudMediaScanProgress.instance;
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        if (!progress.hasActivity) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final isFailed = progress.phase == CloudMediaScanPhase.failed;
        final title = progress.isScanning
            ? '${progress.source} 扫描进行中'
            : isFailed
                ? '${progress.source} 扫描失败'
                : '${progress.source} 扫描结果';
        final rootName = p.posix.basename(
          progress.rootPath.replaceAll('\\', '/').replaceFirst(
                RegExp(r'/+$'),
                '',
              ),
        );
        final summary = switch (progress.phase) {
          CloudMediaScanPhase.listing =>
            '已检查 ${progress.directoriesVisited} 个目录 · 发现 ${progress.videosFound} 个视频',
          CloudMediaScanPhase.indexing =>
            '已处理 ${progress.filesIndexed}/${progress.totalFiles} 个媒体文件',
          CloudMediaScanPhase.matching =>
            '已匹配 ${progress.matchedWorks} 部 · 待确认 ${progress.failedWorks} 部',
          CloudMediaScanPhase.completed =>
            '检查 ${progress.directoriesVisited} 个目录 · ${progress.videosFound} 个视频 · 匹配 ${progress.matchedWorks} 部',
          _ => '',
        };
        return Card(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      isFailed
                          ? Icons.error_outline
                          : Icons.cloud_sync_outlined,
                      size: 19,
                      color: isFailed
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        rootName.isEmpty ? title : '$title · $rootName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    if (!progress.isScanning)
                      IconButton(
                        tooltip: '关闭扫描状态',
                        visualDensity: VisualDensity.compact,
                        onPressed: progress.dismiss,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  progress.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isFailed
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    summary,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (progress.isScanning) ...[
                  const SizedBox(height: 9),
                  LinearProgressIndicator(value: progress.fraction),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
