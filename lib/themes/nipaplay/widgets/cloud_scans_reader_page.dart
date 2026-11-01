import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nipaplay/services/webdav_service.dart';

/// Reads one scan image at a time from its configured WebDAV source.
class CloudScansReaderPage extends StatefulWidget {
  const CloudScansReaderPage({
    super.key,
    required this.connection,
    required this.rootPath,
    required this.images,
    this.initialIndex = 0,
  });

  final WebDAVConnection connection;
  final String rootPath;
  final List<Map<String, Object?>> images;
  final int initialIndex;

  @override
  State<CloudScansReaderPage> createState() => _CloudScansReaderPageState();
}

class _CloudScansReaderPageState extends State<CloudScansReaderPage> {
  late PageController _pageController;
  final Map<int, Future<Uint8List>> _imageBytes = {};
  bool _doublePage = false;
  late int _pageIndex;

  int get _pageCount =>
      _doublePage ? (widget.images.length + 1) ~/ 2 : widget.images.length;
  int get _currentImageIndex => _doublePage ? _pageIndex * 2 : _pageIndex;

  @override
  void initState() {
    super.initState();
    final initial = widget.images.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.images.length - 1).toInt();
    _pageIndex = _doublePage ? initial ~/ 2 : initial;
    _pageController = PageController(initialPage: _pageIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<Uint8List> _bytesFor(int index) {
    return _imageBytes.putIfAbsent(index, () async {
      final row = widget.images[index];
      final relativePath = row['relative_path']?.toString() ?? '';
      final root = widget.rootPath
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'/+$'), '');
      final relative = relativePath.replaceAll('\\', '/').replaceFirst(
            RegExp(r'^/+'),
            '',
          );
      final path = root.isEmpty ? '/$relative' : '$root/$relative';
      return WebDAVService.instance.readFileBytes(widget.connection, path);
    });
  }

  void _movePage(int delta) {
    final target = (_pageIndex + delta).clamp(0, _pageCount - 1).toInt();
    if (target == _pageIndex) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _toggleDoublePage() {
    final currentImageIndex = _currentImageIndex;
    final showDouble = !_doublePage;
    final nextPage = showDouble ? currentImageIndex ~/ 2 : currentImageIndex;
    final oldController = _pageController;
    setState(() {
      _doublePage = showDouble;
      _pageIndex = nextPage;
      _pageController = PageController(initialPage: nextPage);
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => oldController.dispose());
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      return const Scaffold(body: Center(child: Text('没有可阅读的图片')));
    }
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final firstName =
        widget.images[_currentImageIndex]['name']?.toString() ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${_currentImageIndex + 1} / ${widget.images.length}  $firstName',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '上一页',
            onPressed: _pageIndex == 0 ? null : () => _movePage(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: '下一页',
            onPressed: _pageIndex >= _pageCount - 1 ? null : () => _movePage(1),
            icon: const Icon(Icons.chevron_right),
          ),
          IconButton(
            tooltip: _doublePage ? '切换为单页' : '切换为双页',
            onPressed: _toggleDoublePage,
            icon: Icon(_doublePage
                ? Icons.looks_one_outlined
                : Icons.menu_book_outlined),
          ),
          if (wide)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: Text(_doublePage ? '双页' : '单页')),
            ),
        ],
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _movePage(1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _movePage(-1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: PageView.builder(
          key: ValueKey(_doublePage),
          controller: _pageController,
          itemCount: _pageCount,
          onPageChanged: (index) => setState(() => _pageIndex = index),
          itemBuilder: (context, page) {
            final first = _doublePage ? page * 2 : page;
            if (!_doublePage || first + 1 >= widget.images.length) {
              return _buildImage(first);
            }
            return Row(
              children: [
                Expanded(child: _buildImage(first)),
                const VerticalDivider(width: 1),
                Expanded(child: _buildImage(first + 1)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildImage(int index) {
    return FutureBuilder<Uint8List>(
      future: _bytesFor(index),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('图片读取失败：${snapshot.error}'),
            ),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 6,
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        );
      },
    );
  }
}
