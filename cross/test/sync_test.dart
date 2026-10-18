import 'package:flutter_test/flutter_test.dart';
import 'package:inutt/core/sync.dart';

void main() {
  test('GitHub repository names are read from links and owner/name', () {
    expect(SyncManager.repoName('scyde/inutt-data'), 'scyde/inutt-data');
    expect(SyncManager.repoName('https://github.com/scyde/inutt-data.git'), 'scyde/inutt-data');
    expect(SyncManager.repoName('github.com/scyde/inutt-data/tree/main'), 'scyde/inutt-data');
    expect(SyncManager.repoName('inutt-data'), isNull);
  });
}
