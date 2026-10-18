import 'package:flutter_test/flutter_test.dart';
import 'package:inutt/core/site_adapters.dart';

void main() {
  test('VSCO profile links are recognised', () {
    expect(SiteAdapters.isVsco(Uri.parse('https://vsco.co/someone/gallery')), isTrue);
    expect(SiteAdapters.vscoUser(Uri.parse('https://vsco.co/someone')), 'someone');
    expect(SiteAdapters.isVsco(Uri.parse('https://vsco.co/')), isFalse);
    expect(SiteAdapters.isVsco(Uri.parse('https://example.com/someone')), isFalse);
  });

  test('VSCO page state is read', () {
    const html = '<script>window.__PRELOADED_STATE__ = {"sites":{"siteByUsername":{"a":{"site":{"id":42,"name":"A"}}}},"x":undefined}</script>';
    final s = SiteAdapters.vscoState(html);
    expect(((s!['sites'] as Map)['siteByUsername'] as Map)['a'], isNotNull);
  });

  test('VSCO links without a scheme become https', () {
    expect(SiteAdapters.vscoAbsolute('im.vsco.co/1/a.jpg').toString(), 'https://im.vsco.co/1/a.jpg');
  });
}
