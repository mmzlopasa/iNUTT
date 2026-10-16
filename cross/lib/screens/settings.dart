import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/downloads.dart';
import '../core/feed_engine.dart';
import '../core/image_cache.dart';
import '../core/models.dart';
import '../core/security.dart';
import '../core/stores.dart';
import '../ui/theme.dart';
import 'library.dart';
import 'lock.dart';
import 'onboarding.dart';

const appVersion = '1.0.0';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  int _cache = 0;

  @override
  void initState() {
    super.initState();
    ImagePipeline.shared.diskUsage().then((v) {
      if (mounted) setState(() => _cache = v);
    });
  }

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([AppSettings.shared, SiteStore.shared, Library.shared, LockManager.shared]),
        builder: (context, _) {
          final s = AppSettings.shared;
          final lock = LockManager.shared;
          return SkyScaffold(
            body: ListView(padding: EdgeInsets.zero, children: [
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Row(children: [
                    if (Navigator.of(context).canPop()) ...[
                      Pressable(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.06), border: Border.all(color: T.line2)),
                          child: const Icon(Icons.chevron_left_rounded, color: T.ink),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('SETTINGS', style: T.mono(11, spacing: 1.2)),
                      const Wordmark(size: 30),
                    ]),
                  ]),
                ),
              ),
              Section(title: 'Sites', children: [
                Row2(
                    icon: Icons.public_rounded,
                    title: 'Manage sites',
                    value: '${SiteStore.shared.sites.length}/${Limits.maxSites}',
                    onTap: () => _push(const ManageSitesView())),
                Row2(
                  icon: Icons.add_circle_rounded,
                  title: 'Add links',
                  onTap: SiteStore.shared.canAdd
                      ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddSiteView(), fullscreenDialog: true))
                      : null,
                ),
              ]),
              Section(
                title: 'Security',
                footer: 'When enabled, iNUTT asks for ${lock.biometryName} or your PIN every time it opens.',
                children: [
                  SwitchRow(
                    icon: Icons.fingerprint_rounded,
                    title: lock.biometryName,
                    value: s.biometricEnabled,
                    onChanged: lock.biometricAvailable || s.biometricEnabled ? (v) => s.biometricEnabled = v : null,
                  ),
                  if (s.pinEnabled) ...[
                    Row2(icon: Icons.lock_reset_rounded, title: 'Change PIN', onTap: () => _push(const PinSetupView())),
                    Row2(icon: Icons.lock_open_rounded, title: 'Turn off PIN', tint: T.err, onTap: lock.removePin),
                  ] else
                    Row2(icon: Icons.lock_rounded, title: 'Set up PIN lock', onTap: () => _push(const PinSetupView())),
                  SwitchRow(icon: Icons.bedtime_rounded, title: 'Lock when leaving', value: s.lockOnBackground, onChanged: (v) => s.lockOnBackground = v),
                  SwitchRow(
                      icon: Icons.visibility_off_rounded,
                      title: 'Hide content in app switcher',
                      value: s.hideInSwitcher,
                      onChanged: (v) => s.hideInSwitcher = v),
                ],
              ),
              Section(title: 'History', children: [
                Row2(
                    icon: Icons.history_rounded,
                    title: 'View and search history',
                    value: '${Library.shared.history.length}',
                    onTap: () => _push(const HistoryView())),
                SwitchRow(icon: Icons.radio_button_checked_rounded, title: 'Save history', value: s.historyEnabled, onChanged: (v) => s.historyEnabled = v),
                Row2(
                  icon: Icons.delete_rounded,
                  title: 'Clear history',
                  tint: T.err,
                  onTap: Library.shared.history.isEmpty ? null : Library.shared.clearHistory,
                ),
              ]),
              Section(title: 'Playback', children: [
                Row2(
                  icon: Icons.four_k_rounded,
                  title: 'Maximum resolution',
                  value: s.maxQuality == 2160 ? '4K (2160p)' : '${s.maxQuality}p',
                  onTap: () => _pickQuality(context),
                ),
                SwitchRow(icon: Icons.play_circle_rounded, title: 'Autoplay', value: s.autoplay, onChanged: (v) => s.autoplay = v),
                SwitchRow(icon: Icons.repeat_rounded, title: 'Loop videos', value: s.loopVideos, onChanged: (v) => s.loopVideos = v),
                SwitchRow(icon: Icons.volume_off_rounded, title: 'Start muted', value: s.startMuted, onChanged: (v) => s.startMuted = v),
              ]),
              Section(
                title: 'Downloads & storage',
                footer: Platform.isWindows
                    ? 'Downloads are saved in Downloads › iNUTT Downloads.'
                    : 'Downloads are saved to your gallery in the iNUTT album.',
                children: [
                  Row2(
                    icon: Icons.storage_rounded,
                    title: 'Clear cache',
                    value: '${(_cache / 1024 / 1024).toStringAsFixed(1)} MB',
                    onTap: () async {
                      await ImagePipeline.shared.clear();
                      FeedEngine.shared.clearCache();
                      if (mounted) setState(() => _cache = 0);
                    },
                  ),
                ],
              ),
              Section(
                title: 'Backup',
                footer: 'Copies your site links as text. To restore them, paste the list into Add links › Multiple links.',
                children: [
                  Row2(
                    icon: Icons.ios_share_rounded,
                    title: 'Export sites',
                    value: '${SiteStore.shared.sites.length}',
                    onTap: SiteStore.shared.sites.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(ClipboardData(text: SiteStore.shared.sites.map((e) => e.url.toString()).join('\n')));
                            DownloadManager.shared.show('Site links copied');
                          },
                  ),
                ],
              ),
              Section(
                title: 'About',
                footer: 'iNUTT · made by SCYDE · scyde.dev',
                children: [
                  const Row2(icon: Icons.info_rounded, title: 'Version', value: appVersion),
                  Row2(icon: Icons.privacy_tip_rounded, title: 'Privacy', onTap: () => _push(const LegalView(title: 'Privacy', text: LegalText.privacy))),
                  Row2(icon: Icons.description_rounded, title: 'Terms of use', onTap: () => _push(const LegalView(title: 'Terms of use', text: LegalText.terms))),
                  Row2(
                    icon: Icons.handyman_rounded,
                    title: 'Developer',
                    value: 'SCYDE',
                    onTap: () => launchUrl(Uri.parse('https://scyde.dev'), mode: LaunchMode.externalApplication),
                  ),
                ],
              ),
              const SizedBox(height: 120),
            ]),
          );
        },
      );

  void _pickQuality(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        backgroundColor: T.navy,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (q, label) in const [(2160, '4K (2160p)'), (1440, '1440p'), (1080, '1080p'), (720, '720p')])
              ListTile(
                title: Text(label, style: T.text(15, color: T.ink)),
                trailing: AppSettings.shared.maxQuality == q ? const Icon(Icons.check_rounded, color: T.gold) : null,
                onTap: () {
                  AppSettings.shared.maxQuality = q;
                  Navigator.pop(ctx);
                },
              ),
          ]),
        ),
      );
}

class Section extends StatelessWidget {
  final String title;
  final String? footer;
  final List<Widget> children;
  const Section({super.key, required this.title, this.footer, required this.children});

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(title.toUpperCase(), style: T.mono(11, color: T.gold, spacing: 1)),
              ),
              GlassCard(
                radius: 18,
                child: Column(children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 52, color: T.line),
                    children[i],
                  ],
                ]),
              ),
              if (footer != null)
                Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 0), child: Text(footer!, style: T.text(12, color: T.muted))),
            ]),
          ),
        ),
      );
}

class Row2 extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? value;
  final Color tint;
  final VoidCallback? onTap;
  final Widget? trailing;
  const Row2({super.key, required this.icon, required this.title, this.value, this.tint = T.ink, this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Opacity(
          opacity: onTap == null && trailing == null && value == null ? 0.5 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(color: T.gold.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, size: 16, color: T.gold),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: T.text(15, weight: FontWeight.w500, color: tint), maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (value != null) Text(value!, style: T.mono(12)),
              if (trailing != null) trailing!,
              if (onTap != null && trailing == null) const Icon(Icons.chevron_right_rounded, color: T.muted, size: 20),
            ]),
          ),
        ),
      );
}

class SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  const SwitchRow({super.key, required this.icon, required this.title, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) => Row2(
        icon: icon,
        title: title,
        trailing: SizedBox(height: 28, child: FittedBox(child: Switch(value: value, onChanged: onChanged))),
      );
}

class ManageSitesView extends StatelessWidget {
  const ManageSitesView({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: SiteStore.shared,
        builder: (context, _) {
          final sites = SiteStore.shared.sites;
          return SkyScaffold(
            appBar: AppBar(title: const Text('Sites'), actions: [
              IconButton(
                icon: const Icon(Icons.add_rounded),
                onPressed: SiteStore.shared.canAdd
                    ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddSiteView(), fullscreenDialog: true))
                    : null,
              ),
            ]),
            body: sites.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: EmptyState(icon: Icons.public_rounded, title: 'No sites', message: 'Add links to start.'),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(0, 4, 0, 120),
                    itemCount: sites.length,
                    onReorder: SiteStore.shared.move,
                    itemBuilder: (context, i) {
                      final s = sites[i];
                      return ListTile(
                        key: ValueKey(s.id),
                        leading: SiteIcon(site: s, size: 36),
                        title: Text(s.name, style: T.text(15, weight: FontWeight.w500, color: T.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(s.host, style: T.mono(11), maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Switch(
                            value: s.enabled,
                            onChanged: (v) {
                              final c = s.copy()..enabled = v;
                              SiteStore.shared.update(c);
                            },
                          ),
                          const SizedBox(width: 24),
                        ]),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditSiteView(site: s))),
                      );
                    },
                  ),
          );
        },
      );
}

class AddSiteView extends StatefulWidget {
  const AddSiteView({super.key});

  @override
  State<AddSiteView> createState() => _AddSiteViewState();
}

class _AddSiteViewState extends State<AddSiteView> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _search = TextEditingController();
  RenderMode _mode = RenderMode.auto;
  bool _bulk = false;
  bool _checking = false;
  String? _error;
  ScrapeResult? _preview;
  Uri? _previewUrl;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    final store = SiteStore.shared;
    if (_bulk) {
      var added = 0;
      for (final line in _url.text.split('\n')) {
        final u = SiteStore.normalize(line);
        if (u == null || !store.canAdd) continue;
        final s = Site(name: u.host.replaceFirst('www.', ''), url: u);
        if (store.add(s)) {
          added++;
          FeedEngine.shared.refresh(s, null);
        }
      }
      if (added == 0) return setState(() => _error = 'No new valid links.');
      if (mounted) Navigator.pop(context);
      return;
    }
    final url = SiteStore.normalize(_url.text);
    if (url == null) return setState(() => _error = 'Invalid link.');
    if (!store.canAdd) return setState(() => _error = 'You have reached the maximum of ${Limits.maxSites} sites.');
    final site = Site(
      name: _name.text.trim().isEmpty ? url.host.replaceFirst('www.', '') : _name.text.trim(),
      url: url,
      renderMode: _mode,
      searchTemplate: _search.text.trim().isEmpty ? null : _search.text.trim(),
    );
    if (_preview != null && _previewUrl == url) return _save(site, _preview!);
    setState(() => _checking = true);
    try {
      final r = await FeedEngine.fetchListing(url, url, site, null);
      _preview = r;
      _previewUrl = url;
      if (r.items.isEmpty && r.categories.isEmpty) {
        _error = 'No content found on this page. Try the "Full (JavaScript)" mode or another link.';
      } else if (_name.text.trim().isEmpty && (r.title?.trim().isNotEmpty ?? false) && r.title!.trim().length < 40) {
        _name.text = r.title!.trim();
      }
    } catch (e) {
      _error = 'Couldn\'t load the site: $e';
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _save(Site s, ScrapeResult p) {
    if (_name.text.trim().isNotEmpty) s.name = _name.text.trim();
    s.categories = p.categories;
    s.iconUrl = p.iconUrl;
    if (!SiteStore.shared.add(s)) return setState(() => _error = 'This site is already added.');
    FeedEngine.shared.refresh(s, null);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    return SkyScaffold(
      appBar: AppBar(
        title: const Text('Add site'),
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('One site')), ButtonSegment(value: true, label: Text('Multiple links'))],
          selected: {_bulk},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _bulk = s.first),
        ),
        const SizedBox(height: 16),
        if (_bulk) ...[
          TextField(
            controller: _url,
            minLines: 6,
            maxLines: 14,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
            style: T.mono(13, color: T.ink),
            decoration: const InputDecoration(hintText: 'One link per line'),
          ),
          const SizedBox(height: 8),
          Text('${Limits.maxSites - SiteStore.shared.sites.length} sites left.', style: T.text(12, color: T.muted)),
        ] else ...[
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: T.mono(14, color: T.ink),
            onChanged: (_) => _preview = null,
            decoration: const InputDecoration(hintText: 'https://example.com/gallery'),
          ),
          const SizedBox(height: 6),
          Text('A category page, RSS feed or subreddit (r/name) works too.', style: T.text(12, color: T.muted)),
          const SizedBox(height: 12),
          TextField(controller: _name, style: T.text(15, color: T.ink), decoration: const InputDecoration(hintText: 'Name (optional)')),
          const SizedBox(height: 18),
          Text('LOADING', style: T.mono(11, color: T.gold, spacing: 1)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final m in RenderMode.values) Chip2(title: m.label, selected: _mode == m, onTap: () => setState(() => _mode = m)),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            autocorrect: false,
            style: T.mono(13, color: T.ink),
            decoration: const InputDecoration(hintText: 'Search template, e.g. https://site.com/search?q={q}'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(_error!, style: T.text(13, color: T.err)),
        ],
        if (p != null && (p.items.isNotEmpty || p.categories.isNotEmpty)) ...[
          const SizedBox(height: 16),
          GlassCard(
            radius: 18,
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const Icon(Icons.check_circle_rounded, color: T.gold),
              const SizedBox(width: 10),
              Expanded(child: Text('Found ${p.items.length} items and ${p.categories.length} categories.', style: T.text(14, color: T.ink))),
            ]),
          ),
        ],
        const SizedBox(height: 22),
        Center(
          child: _checking
              ? const CircularProgressIndicator()
              : GoldButton(
                  label: _bulk ? 'Add all' : (p != null && (p.items.isNotEmpty || p.categories.isNotEmpty) ? 'Add site' : 'Check and add'),
                  icon: Icons.add_rounded,
                  onPressed: _submit,
                ),
        ),
      ]),
    );
  }
}

class EditSiteView extends StatefulWidget {
  final Site site;
  const EditSiteView({super.key, required this.site});

  @override
  State<EditSiteView> createState() => _EditSiteViewState();
}

class _EditSiteViewState extends State<EditSiteView> {
  late final Site _draft = widget.site.copy();
  late final _name = TextEditingController(text: _draft.name);
  late final _url = TextEditingController(text: _draft.url.toString());
  late final _search = TextEditingController(text: _draft.searchTemplate ?? '');

  void _save() {
    _draft.name = _name.text.trim().isEmpty ? _draft.name : _name.text.trim();
    final u = SiteStore.normalize(_url.text);
    final urlChanged = u != null && u != _draft.url;
    if (u != null) _draft.url = u;
    _draft.searchTemplate = _search.text.trim().isEmpty ? null : _search.text.trim();
    if (urlChanged) {
      _draft.categories = [];
      FeedEngine.shared.forget(_draft.id);
    }
    SiteStore.shared.update(_draft);
    FeedEngine.shared.refresh(_draft, null);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => SkyScaffold(
        appBar: AppBar(title: const Text('Edit site'), actions: [TextButton(onPressed: _save, child: Text('Save', style: T.text(15, weight: FontWeight.w600, color: T.gold)))]),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
          TextField(controller: _name, style: T.text(15, color: T.ink), decoration: const InputDecoration(hintText: 'Name')),
          const SizedBox(height: 12),
          TextField(controller: _url, autocorrect: false, style: T.mono(13, color: T.ink), decoration: const InputDecoration(hintText: 'Link')),
          const SizedBox(height: 12),
          TextField(
              controller: _search, autocorrect: false, style: T.mono(13, color: T.ink), decoration: const InputDecoration(hintText: 'Search template ({q})')),
          const SizedBox(height: 18),
          Text('LOADING', style: T.mono(11, color: T.gold, spacing: 1)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final m in RenderMode.values) Chip2(title: m.label, selected: _draft.renderMode == m, onTap: () => setState(() => _draft.renderMode = m)),
          ]),
          const SizedBox(height: 18),
          Section(title: 'Site', children: [
            SwitchRow(icon: Icons.power_settings_new_rounded, title: 'Enabled', value: _draft.enabled, onChanged: (v) => setState(() => _draft.enabled = v)),
            Row2(
              icon: Icons.delete_rounded,
              title: 'Remove site',
              tint: T.err,
              onTap: () {
                SiteStore.shared.remove(_draft.id);
                FeedEngine.shared.forget(_draft.id);
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ]),
        ]),
      );
}
