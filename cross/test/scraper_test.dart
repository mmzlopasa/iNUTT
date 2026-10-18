import 'package:flutter_test/flutter_test.dart';
import 'package:inutt/core/models.dart';
import 'package:inutt/core/scraper.dart';
import 'package:inutt/core/site_adapters.dart';

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

  test('player JSON with escaped links picks the best quality', () {
    const html = '<script>var flashvars_1 = {"mediaDefinitions":[{"format":"hls","videoUrl":"https:\\/\\/cdn.example.com\\/v\\/240P_400K_1.mp4\\/master.m3u8?a=1\\u0026b=2","quality":"240"},'
        '{"format":"hls","videoUrl":"https:\\/\\/cdn.example.com\\/v\\/1080P_4000K_1.mp4\\/master.m3u8?a=1\\u0026b=2","quality":"1080"},'
        '{"format":"mp4","videoUrl":"https:\\/\\/www.example.com\\/video\\/get_media?s=x","quality":[]}]};</script>';
    final r = Scraper.resolveDetail(html, Uri.parse('https://www.example.com/view_video.php?viewkey=1'), 2160);
    expect(r?.kind, MediaKind.video);
    expect(r?.url.toString(), 'https://cdn.example.com/v/1080P_4000K_1.mp4/master.m3u8?a=1&b=2');
  });

  test('aggregator cards that link out are kept', () {
    final cards = List.generate(
        6,
        (i) => '<a href="https://othertube$i.com/videos/clip-$i/" title="Clip $i"><img data-src="https://img.example.com/t$i.jpg"><span>12:0$i</span></a>')
        .join();
    final site = Site(name: 'Agg', url: Uri.parse('https://agg.example.com/'));
    final r = Scraper.parseListing('<html><body>$cards</body></html>', site.url, site, null);
    expect(r.items.length, 6);
    expect(r.items.first.kind, MediaKind.video);
  });

  test('JSON feeds become items', () {
    final site = Site(name: 'Api', url: Uri.parse('https://api.example.com/'));
    final r = SiteAdapters.parseJsonListing(
        '[{"postId":1,"label":"One","videoStreamUrl":"https://cdn.example.com/1/playlist.m3u8","thumbnailStreamUrl":"https://cdn.example.com/1/thumb.jpg"},'
        '{"postId":2,"label":"Two","videoStreamUrl":"https://cdn.example.com/2/playlist.m3u8"}]',
        site.url,
        site,
        null);
    expect(r.items.length, 2);
    expect(r.items.first.title, 'One');
    expect(r.items.first.thumbnailUrl.toString(), 'https://cdn.example.com/1/thumb.jpg');
    expect(r.items.every((e) => e.kind == MediaKind.video), isTrue);
  });

  test('plain KVS links pass through', () {
    final v = SiteAdapters.kvsVideos("var flashvars = { video_url: 'https://kvs.example.com/get_file/1/abc/1000/1001/1001.mp4/', video_url_text: '720p' };");
    expect(v.single.$1, 'https://kvs.example.com/get_file/1/abc/1000/1001/1001.mp4/');
    expect(v.single.$2, '720p');
  });
}
