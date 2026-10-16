import 'package:flutter_test/flutter_test.dart';
import 'package:inutt/core/models.dart';
import 'package:inutt/core/scraper.dart';

void main() {
  final site = Site(name: 'Demo', url: Uri.parse('https://demo.com/'));

  test('video cards become video items', () {
    const html = '''
      <a href="/video/123/nice-clip"><img src="/t/1.jpg" alt="Nice clip"><span>12:34</span></a>
      <a href="/video/124/other"><img src="/t/2.jpg" alt="Other"><span>3:05</span></a>''';
    final r = Scraper.parseListing(html, site.url, site, null);
    expect(r.items.length, 2);
    expect(r.items.first.kind, MediaKind.video);
    expect(r.items.first.duration, '12:34');
    expect(r.items.first.title, 'Nice clip');
  });

  test('tiles with item counts become categories', () {
    const html = '''
      <a href="/amateur"><img src="/c/a.jpg"><span>Amateur</span><span>1,234 videos</span></a>
      <a href="/outdoor"><img src="/c/b.jpg"><span>Outdoor</span><span>56 videos</span></a>''';
    final r = Scraper.parseListing(html, site.url, site, null);
    expect(r.items, isEmpty);
    expect(r.categories.map((c) => c.name), ['Amateur', 'Outdoor']);
    expect(r.categories.first.thumbnailUrl.toString(), 'https://demo.com/c/a.jpg');
  });

  test('category URLs are recognised', () {
    expect(Scraper.isCategoryUrl(Uri.parse('https://demo.com/categories/cats/')), isTrue);
    expect(Scraper.isCategoryUrl(Uri.parse('https://demo.com/video/123')), isFalse);
  });

  test('reddit json urls keep sort options', () {
    final u = Scraper.redditJsonUrl(Uri.parse('https://www.reddit.com/r/pics/top/?t=week'), after: 'abc');
    expect(u.path, '/r/pics/top.json');
    expect(u.queryParameters['t'], 'week');
    expect(u.queryParameters['after'], 'abc');
    expect(Scraper.redditJsonUrl(Uri.parse('https://reddit.com')).path, '/.json');
  });

  test('reddit galleries keep every image', () {
    const json = '''{"data":{"after":null,"children":[{"kind":"t3","data":{
      "title":"Two pics","permalink":"/r/pics/comments/x/two/","is_gallery":true,
      "gallery_data":{"items":[{"media_id":"a"},{"media_id":"b"}]},
      "media_metadata":{"a":{"s":{"u":"https://i.redd.it/a.jpg"}},"b":{"s":{"u":"https://i.redd.it/b.jpg"}}}}}]}}''';
    final r = Scraper.parseReddit(json.codeUnits, Uri.parse('https://www.reddit.com/r/pics'), site, null);
    expect(r.items.single.gallery?.length, 2);
    expect(r.categories.first.name, 'Hot');
    expect(r.title, 'r/pics');
  });

  test('detail pages pick the best video', () {
    const html = '''<video><source src="/v/480.mp4" size="480"><source src="/v/1080.mp4" size="1080"><source src="/v/2160.mp4" size="2160"></video>''';
    final r = Scraper.resolveDetail(html, Uri.parse('https://demo.com/video/1'), 1080);
    expect(r?.url.toString(), 'https://demo.com/v/1080.mp4');
    expect(r?.kind, MediaKind.video);
  });
}
