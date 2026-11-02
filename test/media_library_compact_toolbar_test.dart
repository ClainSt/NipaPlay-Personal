import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/app/unified_media_library_sections.dart';
import 'package:nipaplay/media_library/adaptive_media_library_controls.dart';

void main() {
  const section = UnifiedMediaLibrarySection(
      id: 'webdav',
      label: 'WebDAV媒体库',
      phoneSymbol: 'cloud',
      contentType: UnifiedMediaLibraryContentType.mediaCollection,
      source: UnifiedMediaLibrarySource.webdav);
  for (final width in [600.0, 1600.0]) {
    testWidgets('library toolbar stays in one compact row at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AdaptiveMediaLibraryScaffold(
        sections: const [section],
        selectedSection: section,
        onSectionSelected: (_) {},
        onSectionOrderChanged: (_) {},
        onRemoteAccess: () {},
        onAddMedia: () {},
        child: const SizedBox(key: ValueKey('content')),
      ))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(find.byKey(const ValueKey('content'))).dy, 48);
      if (width > 1150) {
        final y = tester.getCenter(find.text('WebDAV媒体库')).dy;
        for (final label in ['排序', '远程访问', '添加媒体', '刮削进度']) {
          expect(tester.getCenter(find.text(label)).dy, closeTo(y, 1));
        }
      } else {
        expect(find.byTooltip('刮削进度'), findsOneWidget);
        expect(find.text('刮削进度'), findsNothing);
      }
    });
  }
}
