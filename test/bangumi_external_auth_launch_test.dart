import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Bangumi auth launches directly and only reports real success', () {
    final source = File(
      'lib/themes/nipaplay/pages/account/material_account_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(source, isNot(contains('canLaunchUrl(uri)')));
    expect(
      source,
      contains(
        'final opened = await _openExternalUrl(\n'
        '      BangumiAccountViewModel.bangumiAccessTokenUrl,',
      ),
    );
    expect(source, contains('if (!mounted) return;'));
    expect(source, contains('if (!opened) {'));
    final helper =
        source.substring(source.indexOf('Future<bool> _openExternalUrl'));
    expect(helper, contains('final opened = await launchUrl('));
    expect(helper, contains('mode: LaunchMode.externalApplication'));
    expect(source, contains('return opened;'));
  });
}
