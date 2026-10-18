import 'package:flutter_test/flutter_test.dart';
import 'package:inutt/core/models.dart';
import 'package:inutt/core/stores.dart';

MediaItem _item(String title, {String? page}) =>
    MediaItem(siteId: 's', siteName: 'Site', title: title, pageUrl: Uri.parse(page ?? 'https://x.com/v/1'), kind: MediaKind.video);

void main() {
  tearDown(() => Blocklist.update(const []));

  test('blocked words hide matching titles and links, case-insensitively', () {
    Blocklist.update(['Foo', ' bar ']);
    final items = [_item('A foo clip'), _item('clean'), _item('x', page: 'https://x.com/videos/bar-baz'), _item('ok')];
    expect(Blocklist.filter(items).map((e) => e.title), ['clean', 'ok']);
  });

  test('an empty list keeps everything', () {
    final items = [_item('a'), _item('b')];
    expect(identical(Blocklist.filter(items), items), isTrue);
  });
}
