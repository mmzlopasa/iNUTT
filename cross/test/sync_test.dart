import 'package:flutter_test/flutter_test.dart';
import 'package:inutt/core/sync.dart';

void main() {
  test('GitHub repository names are read from links and owner/name', () {
    expect(SyncManager.repoName('scyde/inutt-data'), 'scyde/inutt-data');
    expect(SyncManager.repoName('https://github.com/scyde/inutt-data.git'), 'scyde/inutt-data');
    expect(SyncManager.repoName('github.com/scyde/inutt-data/tree/main'), 'scyde/inutt-data');
    expect(SyncManager.repoName('inutt-data'), isNull);
  });

  test('Vault parts sealed with the sync key open again, across 1 MB pieces', () async {
    final key = List<int>.generate(32, (i) => i);
    final plain = List<int>.generate((1 << 20) + 1234, (i) => i % 251);
    final sealed = await SyncManager.sealChunks(plain, key);
    expect(sealed.length, plain.length + 2 * (4 + 12 + 16));
    expect(await SyncManager.openChunks(sealed, key), plain);
    expect(SyncManager.openChunks(sealed, List<int>.filled(32, 7)), throwsA(anything));
  });

  test('Settings from the iPhone app are read with their names and kinds', () {
    final s = SyncManager.cleanSettings({
      'at': 1729250000000.0,
      'autoplay': false,
      'maxQuality': 1080,
      'reelsSource': 'x',
      'pin': true,
      'hideSeen': 1,
    });
    expect(s, {'at': 1729250000000, 'autoplay': false, 'maxQuality': 1080, 'reelsSource': 'x'});
  });
}
