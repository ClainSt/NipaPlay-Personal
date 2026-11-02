import 'package:flutter/foundation.dart';

enum CloudMediaScanPhase {
  idle,
  listing,
  indexing,
  matching,
  completed,
  failed
}

/// Process-wide status for a cloud media scan. Keeping this outside the
/// management page lets the catalog show progress even after navigation.
class CloudMediaScanProgress extends ChangeNotifier {
  CloudMediaScanProgress._();

  static final CloudMediaScanProgress instance = CloudMediaScanProgress._();

  bool isScanning = false;
  bool hasActivity = false;
  String source = 'WebDAV';
  String rootPath = '';
  String message = '';
  CloudMediaScanPhase phase = CloudMediaScanPhase.idle;
  int directoriesVisited = 0;
  int videosFound = 0;
  int filesIndexed = 0;
  int totalFiles = 0;
  int processedWorks = 0;
  int totalWorks = 0;
  int matchedWorks = 0;
  int failedWorks = 0;
  int runId = 0;

  double? get fraction {
    if (phase == CloudMediaScanPhase.indexing) return 0.62;
    if (phase == CloudMediaScanPhase.matching && totalWorks > 0) {
      return 0.68 + 0.32 * (processedWorks / totalWorks);
    }
    if (phase == CloudMediaScanPhase.completed) return 1;
    return null;
  }

  void start({required String source, required String rootPath}) {
    runId++;
    isScanning = true;
    hasActivity = true;
    this.source = source;
    this.rootPath = rootPath;
    message = '正在连接并读取目录';
    phase = CloudMediaScanPhase.listing;
    directoriesVisited = 0;
    videosFound = 0;
    filesIndexed = 0;
    totalFiles = 0;
    processedWorks = 0;
    totalWorks = 0;
    matchedWorks = 0;
    failedWorks = 0;
    notifyListeners();
  }

  void updateListing(
      {required int directoriesVisited, required int videosFound}) {
    if (!isScanning) return;
    phase = CloudMediaScanPhase.listing;
    this.directoriesVisited = directoriesVisited;
    this.videosFound = videosFound;
    message = '正在读取目录：已检查 $directoriesVisited 个目录，发现 $videosFound 个视频';
    notifyListeners();
  }

  void updateIndexing({required int filesIndexed, required int totalFiles}) {
    if (!isScanning) return;
    phase = CloudMediaScanPhase.indexing;
    this.filesIndexed = filesIndexed;
    this.totalFiles = totalFiles;
    message = '正在更新媒体库索引（$filesIndexed/$totalFiles）';
    notifyListeners();
  }

  void updateMatching({
    required int processed,
    required int total,
    required int matched,
    required int failed,
    String? currentWork,
  }) {
    if (!isScanning) return;
    phase = CloudMediaScanPhase.matching;
    processedWorks = processed;
    totalWorks = total;
    matchedWorks = matched;
    failedWorks = failed;
    message = currentWork == null || currentWork.isEmpty
        ? '正在匹配作品（$processed/$total）'
        : '正在匹配作品（$processed/$total）：$currentWork';
    notifyListeners();
  }

  void updateMessage(String value) {
    if (!isScanning) return;
    message = value;
    notifyListeners();
  }

  void complete({
    required String message,
    required int directoriesVisited,
    required int videosFound,
    required int matchedWorks,
    required int failedWorks,
    int? totalFiles,
  }) {
    isScanning = false;
    hasActivity = true;
    phase = CloudMediaScanPhase.completed;
    this.message = message;
    this.directoriesVisited = directoriesVisited;
    this.videosFound = videosFound;
    this.totalFiles = totalFiles ?? videosFound;
    filesIndexed = this.totalFiles;
    this.matchedWorks = matchedWorks;
    this.failedWorks = failedWorks;
    processedWorks = totalWorks;
    notifyListeners();
  }

  void fail(Object error) {
    isScanning = false;
    hasActivity = true;
    phase = CloudMediaScanPhase.failed;
    message = '扫描失败：$error';
    notifyListeners();
  }

  void dismiss() {
    if (isScanning) return;
    hasActivity = false;
    phase = CloudMediaScanPhase.idle;
    message = '';
    notifyListeners();
  }
}
