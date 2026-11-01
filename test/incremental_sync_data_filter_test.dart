import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/incremental_sync_data_filter.dart';

void main() {
  test(
      'shared sync state excludes local paths, connection credentials and sync credentials',
      () {
    final sanitized = IncrementalSyncDataFilter.sanitizeBackup({
      'preferences': {
        'settings': {
          'theme': 'dark',
          'incremental_sync_webdav_password': 'sync-secret',
          'auto_sync_path': 'C:/private/sync',
        },
      },
      'mediaLibraries': {
        'localMediaLibraries': ['C:/private/anime'],
        'webdavConnections': [
          {
            'id': 'connection-id',
            'url': 'http://127.0.0.1:8080/dav',
            'username': 'private-user',
            'password': 'dav-secret',
          },
        ],
        'webdavConnection:connection-id': {
          'id': 'connection-id',
          'password': 'old-secret',
        },
        'smbConnections': [
          {'password': 'smb-secret'},
        ],
        'serverProfiles': [
          {'token': 'server-secret'},
        ],
        'cloudMediaIndex:root:logical-id': {
          'id': 'logical-id',
          'name': 'Anime',
        },
        'cloudMediaIndex:asset:sample': {
          'source_id': 'logical-id',
          'relative_path': 'Show/01.mkv',
        },
      },
    });

    final encoded = sanitized.toString();
    for (final secret in [
      'sync-secret',
      'C:/private/sync',
      'C:/private/anime',
      'private-user',
      'dav-secret',
      'old-secret',
      'smb-secret',
      'server-secret',
      'http://127.0.0.1',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
    expect(encoded, contains('cloudMediaIndex:root:logical-id'));
    expect(encoded, contains('Show/01.mkv'));
    expect(encoded, contains('dark'));
  });
}
