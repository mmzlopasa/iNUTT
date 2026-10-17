import 'package:flutter_test/flutter_test.dart';
import 'package:inutt/core/models.dart';

MediaItem item(String site, {String title = '', String? media, String? thumb, String? duration}) => MediaItem(
  siteId: site,
  siteName: site,
  title: title,
  mediaUrl: media == null ? null : Uri.parse(media),
  thumbnailUrl: thumb == null ? null : Uri.parse(thumb),
  pageUrl: Uri.parse('https://$site.example/${title.hashCode}${media.hashCode}'),
  kind: MediaKind.video,
  duration: duration,
);

void main() {
  test('the same file on two sites shares a key', () {
    final a = item('a', media: 'https://cdn1.example/v/8f3a9c21b7e4d0_720p.mp4');
    final b = item('b', media: 'https://cdn2.example/x/8f3a9c21b7e4d0_1080p.mp4');
    expect(a.duplicateKeys.toSet().intersection(b.duplicateKeys.toSet()), isNotEmpty);
  });

  test('a long title with the same length matches, a short one does not', () {
    final a = item('a', title: 'Sunset beach walk with friends', duration: '12:04');
    final b = item('b', title: 'Sunset Beach Walk with Friends!', duration: '12:04');
    expect(a.duplicateKeys, equals(b.duplicateKeys));
    expect(item('c', title: 'Hot one').duplicateKeys, isEmpty);
  });

  test('generic file names never count', () {
    expect(item('a', thumb: 'https://x.example/123/thumb.jpg').duplicateKeys, isEmpty);
  });

  test('hashtags come from the site and from the title', () {
    final i = MediaItem(siteId: 's', siteName: 's', title: 'So good #summer #Beach', kind: MediaKind.video, tags: ['beach', 'sun']);
    expect(i.hashtags, ['beach', 'sun', 'summer']);
    expect(i.titleWithoutTags, 'So good');
  });
}
