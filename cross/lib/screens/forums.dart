import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/downloads.dart';
import '../core/feed_engine.dart';
import '../core/html.dart';
import '../core/models.dart';
import '../core/net.dart';
import '../core/site_adapters.dart';
import '../core/stores.dart';
import '../ui/remote_image.dart';
import '../ui/router.dart';
import '../ui/theme.dart';

class Forum {
  final String id;
  String name;
  Uri url;

  /// Where you left off, so the forum reopens on the same thread.
  Uri? lastUrl;
  Forum({String? id, required this.name, required this.url, this.lastUrl})
    : id = id ?? hashKey('${DateTime.now().microsecondsSinceEpoch}$url');

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url.toString(), if (lastUrl != null) 'lastUrl': lastUrl.toString()};

  static Forum? fromJson(Object? j) {
    if (j is! Map) return null;
    final u = Uri.tryParse(j['url'] as String? ?? '');
    if (u == null) return null;
    return Forum(
      id: j['id'] as String?,
      name: j['name'] as String? ?? u.host,
      url: u,
      lastUrl: j['lastUrl'] == null ? null : Uri.tryParse(j['lastUrl'] as String),
    );
  }
}

class ForumStore extends ChangeNotifier {
  static final ForumStore shared = ForumStore._();
  ForumStore._() {
    final j = Disk.load('forums.json');
    if (j is List) forums = j.map(Forum.fromJson).whereType<Forum>().toList();
  }

  List<Forum> forums = [];

  bool add(String name, String link) {
    final u = SiteStore.normalize(link);
    if (u == null) return false;
    final n = name.trim();
    forums.add(Forum(name: n.isEmpty ? u.host.replaceFirst('www.', '') : n, url: u));
    _save();
    return true;
  }

  void remove(Forum f) {
    forums.removeWhere((e) => e.id == f.id);
    _save();
  }

  void remember(String id, Uri? url) {
    final i = forums.indexWhere((e) => e.id == id);
    if (i < 0 || url == null || forums[i].lastUrl == url) return;
    forums[i].lastUrl = url;
    _save();
  }

  void _save() {
    notifyListeners();
    unawaited(Disk.save('forums.json', forums.map((e) => e.toJson()).toList()));
  }
}

/// Forums you browse inside the app, signed in, with every picture and video of a thread one tap away.
class ForumsSection extends StatelessWidget {
  const ForumsSection({super.key});

  void _add(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddForumPage(), fullscreenDialog: true));

  static void open(BuildContext context, Uri url, String title, {String? forumId}) => Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => WebBrowserPage(url: url, title: title, forumId: forumId),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ForumStore.shared,
    builder: (context, _) {
      final forums = ForumStore.shared.forums;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('${forums.length} forums', style: T.mono(12)),
                const Spacer(),
                GhostButton(label: 'Add forum', onPressed: () => _add(context)),
              ],
            ),
            const SizedBox(height: 12),
            if (forums.isEmpty)
              EmptyState(
                icon: Icons.forum_rounded,
                title: 'No forums',
                message: 'Add the forums you read. They open right here, you stay signed in, and the Media button shows every picture and video of a thread in the viewer.',
                buttonTitle: 'Add forum',
                onButton: () => _add(context),
              )
            else
              for (final f in forums)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Pressable(
                    onTap: () => open(context, f.lastUrl ?? f.url, f.name, forumId: f.id),
                    onLongPress: () => _actions(context, f),
                    child: GestureDetector(onSecondaryTap: () => _actions(context, f), child: _row(f)),
                  ),
                ),
          ],
        ),
      );
    },
  );

  Widget _row(Forum f) => GlassCard(
    radius: 20,
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(width: 40, height: 40, child: RemoteImage(url: f.url.resolve('/favicon.ico'), decodeWidth: 96)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.display(16, weight: FontWeight.w600),
              ),
              const SizedBox(height: 3),
              Text(f.lastUrl != null ? 'Continue where you left off' : f.url.host, maxLines: 1, style: T.mono(11)),
            ],
          ),
        ),
        const Icon(Icons.chevron_right_rounded, color: T.muted),
      ],
    ),
  );

  void _actions(BuildContext context, Forum f) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: T.navy,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.home_rounded, color: T.gold),
              title: Text('Open start page', style: T.text(15, color: T.ink)),
              onTap: () {
                Navigator.pop(ctx);
                open(context, f.url, f.name, forumId: f.id);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_rounded, color: T.gold),
              title: Text('Remove', style: T.text(15, color: T.ink)),
              onTap: () {
                Navigator.pop(ctx);
                ForumStore.shared.remove(f);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class AddForumPage extends StatefulWidget {
  const AddForumPage({super.key});

  @override
  State<AddForumPage> createState() => _AddForumPageState();
}

class _AddForumPageState extends State<AddForumPage> {
  final _name = TextEditingController();
  final _link = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SkyScaffold(
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      title: Text('Add forum', style: T.display(17, weight: FontWeight.w600)),
      iconTheme: const IconThemeData(color: T.gold),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(hintText: 'Name (optional)'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _link,
          keyboardType: TextInputType.url,
          autocorrect: false,
          style: T.mono(14, color: T.ink),
          decoration: const InputDecoration(hintText: 'forum.example.com'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text('Sign in once inside the forum; iNUTT keeps you signed in.', style: T.text(13, color: T.muted)),
        const SizedBox(height: 20),
        GoldButton(
          label: 'Add',
          onPressed: SiteStore.normalize(_link.text) == null
              ? null
              : () {
                  if (ForumStore.shared.add(_name.text, _link.text)) Navigator.pop(context);
                },
        ),
      ],
    ),
  );
}

/// A full-screen browser for forums and for opening any item's original page.
class WebBrowserPage extends StatefulWidget {
  final Uri url;
  final String title;
  final String? forumId;
  const WebBrowserPage({super.key, required this.url, required this.title, this.forumId});

  @override
  State<WebBrowserPage> createState() => _WebBrowserPageState();
}

class _WebBrowserPageState extends State<WebBrowserPage> {
  InAppWebViewController? _web;
  String _title = '';
  Uri? _current;
  double _progress = 0;
  bool _canBack = false, _canForward = false;
  String? _note;
  Timer? _noteTimer;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  /// Age-gate cookies first, so adult forums open on their content.
  Future<void> _prepare() async {
    try {
      final jar = CookieManager.instance();
      final parts = widget.url.host.split('.');
      final domain = '.${parts.length >= 2 ? parts.sublist(parts.length - 2).join('.') : widget.url.host}';
      for (final e in SiteAdapters.ageCookies.entries) {
        await jar.setCookie(url: WebUri.uri(widget.url), name: e.key, value: e.value, domain: domain, path: '/');
      }
    } catch (_) {}
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _noteTimer?.cancel();
    final id = widget.forumId;
    if (id != null) ForumStore.shared.remember(id, _current);
    super.dispose();
  }

  Future<void> _updateNav() async {
    final c = _web;
    if (c == null) return;
    final back = await c.canGoBack();
    final fwd = await c.canGoForward();
    if (!mounted) return;
    setState(() {
      _canBack = back;
      _canForward = fwd;
    });
  }

  void _flash(String s) {
    setState(() => _note = s);
    _noteTimer?.cancel();
    _noteTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _note = null);
    });
  }

  Future<void> _showMedia() async {
    final items = await _collect();
    if (items.isEmpty) return _flash('No pictures or videos on this page');
    HapticFeedback.lightImpact();
    AppRouter.shared.open(items, 0);
  }

  /// Every picture and video on the page, downloaded one after another.
  Future<void> _downloadAll() async {
    final items = await _collect();
    if (items.isEmpty) return _flash('No pictures or videos on this page');
    DownloadManager.shared.downloadAll(items);
    _flash('Downloading ${items.length} items');
  }

  Future<List<MediaItem>> _collect() async {
    final c = _web;
    if (c == null) return const [];
    final json = await c.evaluateJavascript(source: _mediaScript);
    final base = _current ?? widget.url;
    final items = <MediaItem>[];
    final seen = <String>{};
    if (json is String) {
      final list = jsonDecode(json);
      if (list is List) {
        for (final d in list.whereType<Map>()) {
          final media = Html.resolve(d['m'] as String?, base);
          final page = Html.resolve(d['p'] as String?, base);
          final thumb = Html.resolve(d['t'] as String?, base) ?? media;
          final key = (media ?? page)?.toString();
          if (key == null || !seen.add(key)) continue;
          final kind = d['k'] == 'v' ? MediaKind.video : (MediaKind.guess(media) ?? MediaKind.guess(thumb) ?? MediaKind.image);
          items.add(
            MediaItem(
              // The forum page is sent as referer, so image hosts that block hot-linking still answer.
              id: hashKey(key),
              siteId: 'forum',
              siteName: widget.title,
              title: d['n'] as String? ?? '',
              thumbnailUrl: thumb,
              mediaUrl: media,
              pageUrl: media == null ? page : base,
              kind: kind,
            ),
          );
        }
      }
    }
    return items;
  }

  /// The page you are on becomes a site, so its media shows up on Home and in Sites.
  void _addAsSite() {
    final u = _current;
    if (u == null) return;
    final name = _title.isEmpty ? u.host : (_title.length > 40 ? _title.substring(0, 40) : _title);
    final site = Site(name: name, url: u);
    if (SiteStore.shared.add(site)) {
      unawaited(FeedEngine.shared.refreshForHome(site));
      _flash('Added to Sites');
    } else {
      _flash("Couldn't add this page");
    }
  }

  Widget _icon(IconData i, VoidCallback? onTap) => Opacity(
    opacity: onTap == null ? 0.4 : 1,
    child: Pressable(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.07)),
        child: Icon(i, size: 20, color: T.ink),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: Column(
        children: [
          Container(
            color: T.navy,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _icon(Icons.close_rounded, () => Navigator.pop(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title.isEmpty ? widget.title : _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.display(14, weight: FontWeight.w600),
                      ),
                      Text((_current ?? widget.url).host, maxLines: 1, style: T.mono(10)),
                    ],
                  ),
                ),
                _icon(Icons.refresh_rounded, () => _web?.reload()),
              ],
            ),
          ),
          if (_progress > 0 && _progress < 1)
            LinearProgressIndicator(value: _progress, minHeight: 2, color: T.gold, backgroundColor: Colors.transparent),
          Expanded(
            child: Stack(
              children: [
                if (_ready)
                  InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri.uri(widget.url)),
                    initialSettings: InAppWebViewSettings(
                      userAgent: Net.userAgent,
                      javaScriptEnabled: true,
                      allowsInlineMediaPlayback: true,
                      mediaPlaybackRequiresUserGesture: false,
                      supportMultipleWindows: false,
                      transparentBackground: true,
                    ),
                    onWebViewCreated: (c) => _web = c,
                    onTitleChanged: (c, t) => setState(() => _title = t ?? ''),
                    onProgressChanged: (c, p) => setState(() => _progress = p / 100),
                    onUpdateVisitedHistory: (c, url, _) {
                      _current = url;
                      _updateNav();
                    },
                  ),
                if (_note != null)
                  Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      margin: const EdgeInsets.only(top: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(color: T.navy.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(18)),
                      child: Text(
                        _note!,
                        style: T.text(13, weight: FontWeight.w500, color: T.ink),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            color: T.navy,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                _icon(Icons.chevron_left_rounded, _canBack ? () => _web?.goBack() : null),
                const SizedBox(width: 12),
                _icon(Icons.chevron_right_rounded, _canForward ? () => _web?.goForward() : null),
                const Spacer(),
                _icon(Icons.library_add_rounded, _addAsSite),
                const SizedBox(width: 8),
                _icon(Icons.download_rounded, _downloadAll),
                const SizedBox(width: 12),
                GoldButton(label: 'Media', icon: Icons.photo_library_rounded, onPressed: _showMedia),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  static const _mediaScript = r"""
(function(){
  var out=[], seen={};
  var file=/\.(jpe?g|png|webp|gif|mp4|webm|m3u8|mov)(\?|#|$)/i;
  function add(o){ var k=o.m||o.p; if(!k||seen[k])return; seen[k]=1; out.push(o); }
  function big(i){ var w=i.naturalWidth||i.width, h=i.naturalHeight||i.height; return w>=120&&h>=90; }
  function src(i){ return i.currentSrc||i.src||i.getAttribute('data-src')||i.getAttribute('data-url')||''; }
  var junk=/avatar|smilie|smiley|emoji|icon|logo|rank|badge|banner|signature/i;
  document.querySelectorAll('a[href] img').forEach(function(i){
    var a=i.closest('a'); var h=a.href||''; if(!big(i)&&!(i.getAttribute('data-src'))) return;
    if(junk.test(src(i)+' '+i.className)) return;
    if(file.test(h)) add({m:h,t:src(i),k:/\.(mp4|webm|m3u8|mov)/i.test(h)?'v':'i',n:i.alt||''});
    else if(/^https?:/i.test(h)) add({p:h,t:src(i),k:'i',n:i.alt||''});
  });
  document.querySelectorAll('img').forEach(function(i){
    if(i.closest('a[href]')) return; var s=src(i); if(!s||!big(i)) return;
    if((i.naturalWidth||i.width)<300) return;
    if(junk.test(s+' '+i.className)) return;
    add({m:s,t:s,k:'i',n:i.alt||''});
  });
  document.querySelectorAll('a[href]').forEach(function(a){ if(/\.(mp4|webm|m3u8|mov)(\?|#|$)/i.test(a.href)) add({m:a.href,k:'v',n:(a.innerText||'').trim().slice(0,80)}); });
  document.querySelectorAll('video').forEach(function(v){
    var s=v.currentSrc||v.src; if(!s||s.indexOf('blob:')===0){ var so=v.querySelector('source'); s=so?so.src:''; }
    if(s&&s.indexOf('blob:')!==0) add({m:s,t:v.poster||'',k:'v'});
  });
  document.querySelectorAll('iframe[src]').forEach(function(f){ if(/embed|player|video/i.test(f.src)) add({p:f.src,k:'v'}); });
  return JSON.stringify(out.slice(0,500));
})()
""";
}
