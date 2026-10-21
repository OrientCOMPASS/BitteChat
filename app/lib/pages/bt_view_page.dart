// Torrent detail page (opened by tapping a task in the BT tab), layout
// after VueTorrent's TorrentDetail view:
//   * summary header: state-colored overall progress + percent + speeds
//   * tab bar: Overview | Files | Peers | Trackers
//       - Overview: grouped label/value property cards (transfer, size,
//         peers, storage, about) like VueTorrent's Overview panel
//       - Files: per-file progress list (VueTorrent "Content")
//       - Peers: connected peer rows (VueTorrent "Peers")
//       - Trackers: tracker rows with add/remove (VueTorrent "Trackers")
//   * AppBar actions: pause/resume, delete
// (VueTorrent's piece map and tags/categories have no counterpart in this
// core and are deliberately omitted.)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/l10n.dart';
import '../models.dart';
import 'home.dart';

class BtViewPage extends StatefulWidget {
  const BtViewPage({
    super.key,
    required this.infohash,
    required this.name,
    this.savePath = '',
    this.magnet = '',
  });

  final String infohash;
  final String name;
  final String savePath;
  final String magnet;

  @override
  State<BtViewPage> createState() => _BtViewPageState();
}

class _BtViewPageState extends State<BtViewPage>
    with SingleTickerProviderStateMixin {
  late final BitteApi _api = BitteApi.instance;
  late final TabController _tabs = TabController(length: 4, vsync: this);
  TorrentInfo? _torrent;
  List<Map<String, dynamic>> _files = [];
  List<PeerInfo> _peers = [];
  List<TrackerInfo> _trackers = [];
  Timer? _timer;
  StreamSubscription<CoreEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = _api.events.listen((e) {
      if (e.isBtUpdated) _load();
    });
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  void _load() {
    if (!mounted) return;
    try {
      final f = _api.call('bt.files', {'infohash': widget.infohash});
      setState(() {
        final match = _api
            .torrents(includeChat: true)
            .where((t) => t.infohash == widget.infohash)
            .toList();
        _torrent = match.isEmpty ? null : match.first;
        _files = ((f['files'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _peers = _api.btPeers(widget.infohash);
        _trackers = _api.btTrackers(widget.infohash);
      });
    } catch (_) {}
  }

  Color _stateColor(TorrentInfo t, ColorScheme cs) {
    if (t.error.isNotEmpty) return cs.error;
    if (t.paused) return cs.outline;
    if (t.finished) return cs.tertiary;
    if (t.downloadRate > 0) return cs.primary;
    if (t.uploadRate > 0) return cs.tertiary;
    return cs.outline;
  }

  String _stateLabel(TorrentInfo t) {
    if (t.paused) return L.t.statePaused;
    switch (t.state) {
      case 'seeding':
        return L.t.stateSeeding;
      case 'downloading':
        return L.t.stateDownloading;
      case 'metadata':
        return L.t.stateMetadata;
      case 'checking':
        return L.t.stateChecking;
      case 'finished':
        return L.t.stateFinished;
      case 'queued':
        return L.t.stateQueued;
      default:
        return t.state;
    }
  }

  /// Short technical tags (kind taxonomy), intentionally not localized.
  String _kindLabel(TorrentInfo t) {
    switch (t.kind) {
      case 1:
        return 'DM';
      case 2:
        return 'ATT';
      case 3:
        return 'RSS';
      case 4:
        return 'SEED';
      default:
        return t.groupId.isNotEmpty ? 'ROOM' : 'BT';
    }
  }

  void _control(String op, {bool deleteFiles = false}) {
    try {
      _api.btControl(widget.infohash, op, deleteFiles: deleteFiles);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _confirmDelete() async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.deleteTaskQ(widget.name)),
        content: Text(L.t.deleteTaskHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(L.t.cancel),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: Text(L.t.deleteTaskOnly),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: Text(L.t.deleteTaskFiles),
          ),
        ],
      ),
    );
    if (result == 'keep') _control('remove');
    if (result == 'delete') _control('remove', deleteFiles: true);
    if (result != null && mounted) Navigator.of(context).pop();
  }

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _addTrackerDialog() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.addTracker),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: L.t.trackerUrl,
            hintText: 'udp://tracker.example.org:1337/announce',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(L.t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(L.t.add)),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    try {
      _api.btAddTracker(widget.infohash, url);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = _torrent;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (t != null)
            IconButton(
              key: const ValueKey('btdetail-pause-resume'),
              icon: Icon(t.paused ? Icons.play_arrow : Icons.pause),
              tooltip: t.paused ? L.t.resume : L.t.pause,
              onPressed: () => _control(t.paused ? 'resume' : 'pause'),
            ),
          IconButton(
            key: const ValueKey('btdetail-delete'),
            icon: const Icon(Icons.delete_outline),
            tooltip: L.t.delete,
            onPressed: _confirmDelete,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: L.t.btDetailOverview),
            Tab(text: L.t.btDetailFiles),
            Tab(text: L.t.btDetailPeers),
            Tab(text: L.t.btDetailTrackers),
          ],
        ),
      ),
      body: Column(
        children: [
          _SummaryHeader(torrent: t),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _OverviewTab(
                  torrent: t,
                  infohash: widget.infohash,
                  savePath: widget.savePath,
                  magnet: widget.magnet,
                  stateLabel: t == null ? '' : _stateLabel(t),
                  kindLabel: t == null ? '' : _kindLabel(t),
                  stateColor: t == null
                      ? theme.colorScheme.outline
                      : _stateColor(t, theme.colorScheme),
                  onCopy: _copy,
                ),
                _FilesTab(files: _files),
                _PeersTab(peers: _peers),
                _TrackersTab(
                  trackers: _trackers,
                  onAdd: _addTrackerDialog,
                  onRemove: (tr) {
                    try {
                      _api.btRemoveTracker(widget.infohash, tr.url);
                      _load();
                    } catch (e) {
                      if (mounted) showError(context, e);
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// State-colored overall progress + percent + live speeds, like the top of
/// VueTorrent's detail view.
class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.torrent});

  final TorrentInfo? torrent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = torrent;
    final color = t == null
        ? cs.outline
        : (t.error.isNotEmpty
            ? cs.error
            : t.paused
                ? cs.outline
                : t.finished
                    ? cs.tertiary
                    : t.downloadRate > 0
                        ? cs.primary
                        : cs.tertiary);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: t?.progress ?? 0,
                    minHeight: 8,
                    color: color,
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${((t?.progress ?? 0) * 100).toStringAsFixed(1)}%',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.arrow_downward, size: 14, color: cs.primary),
              const SizedBox(width: 3),
              Text(formatSpeed(t?.downloadRate ?? 0),
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: cs.primary)),
              const SizedBox(width: 14),
              Icon(Icons.arrow_upward, size: 14, color: cs.tertiary),
              const SizedBox(width: 3),
              Text(formatSpeed(t?.uploadRate ?? 0),
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: cs.tertiary)),
              const Spacer(),
              if (t != null)
                Text('${t.numPeers}P / ${t.numSeeds}S',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.outline)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Grouped label/value property cards (VueTorrent Overview panel).
class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.torrent,
    required this.infohash,
    required this.savePath,
    required this.magnet,
    required this.stateLabel,
    required this.kindLabel,
    required this.stateColor,
    required this.onCopy,
  });

  final TorrentInfo? torrent;
  final String infohash;
  final String savePath;
  final String magnet;
  final String stateLabel;
  final String kindLabel;
  final Color stateColor;
  final Future<void> Function(String value, String message) onCopy;

  @override
  Widget build(BuildContext context) {
    final t = torrent;
    final done = ((t?.totalBytes ?? 0) * (t?.progress ?? 0)).round();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _Group(
          title: L.t.btDetailTransfer,
          rows: [
            _Row(
                label: L.t.btDetailState,
                value: stateLabel,
                valueColor: stateColor),
            _Row(
                label: L.t.btDetailProgress,
                value: '${((t?.progress ?? 0) * 100).toStringAsFixed(1)}%'),
            _Row(
                label: L.t.btDetailDown,
                value: formatSpeed(t?.downloadRate ?? 0)),
            _Row(label: L.t.btDetailUp, value: formatSpeed(t?.uploadRate ?? 0)),
          ],
        ),
        _Group(
          title: L.t.btDetailSize,
          rows: [
            _Row(
                label: L.t.btDetailTotal,
                value: formatBytes(t?.totalBytes ?? 0)),
            _Row(label: L.t.btDetailDone, value: formatBytes(done)),
            _Row(
                label: L.t.btDetailPeers,
                value: '${t?.numPeers ?? 0} / ${t?.numSeeds ?? 0}'),
          ],
        ),
        _Group(
          title: L.t.btDetailStorage,
          rows: [
            if (savePath.isNotEmpty)
              _Row(label: L.t.btDetailSavePath, value: savePath),
            _Row(
              label: 'infohash',
              value: infohash,
              mono: true,
              onTap: () => onCopy(infohash, L.t.btDetailCopied),
            ),
            if (magnet.isNotEmpty)
              _Row(
                label: 'magnet',
                value: magnet,
                mono: true,
                onTap: () => onCopy(magnet, L.t.magnetCopied),
              ),
          ],
        ),
        _Group(
          title: L.t.btDetailAbout,
          rows: [
            _Row(label: L.t.btDetailType, value: kindLabel),
          ],
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.rows});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(height: 4),
            ...rows,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.mono = false,
    this.valueColor,
    this.onTap,
  });

  final String label;
  final String value;
  final bool mono;
  final Color? valueColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueWidget = Text(
      value,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
      style: (mono
              ? theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')
              : theme.textTheme.bodySmall)
          ?.copyWith(color: valueColor ?? theme.colorScheme.onSurface),
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
            Expanded(flex: 3, child: valueWidget),
            if (onTap != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.content_copy,
                    size: 13, color: theme.colorScheme.outline),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilesTab extends StatelessWidget {
  const _FilesTab({required this.files});

  final List<Map<String, dynamic>> files;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (files.isEmpty) {
      return Center(
        child: Text(L.t.noMetadata,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline)),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        Text(L.t.filesCount(files.length), style: theme.textTheme.titleSmall),
        ...files.map((f) {
          final prog = (f['progress'] as num?)?.toDouble() ?? 0;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(f['path'] as String? ?? '',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Text(formatBytes((f['size'] as num?)?.toInt() ?? 0),
                        style: theme.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: prog, minHeight: 4),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _PeersTab extends StatelessWidget {
  const _PeersTab({required this.peers});

  final List<PeerInfo> peers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (peers.isEmpty) {
      return Center(
        child: Text(L.t.noPeers,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline)),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(L.t.peersCount(peers.length),
              style: theme.textTheme.titleSmall),
        ),
        ...peers.map((p) => ListTile(
              dense: true,
              leading: Icon(
                p.chatCapable ? Icons.chat : Icons.cloud_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              title:
                  Text('${p.ip}:${p.port}', style: theme.textTheme.bodySmall),
              subtitle: Text(
                '${p.client} · ${(p.progress * 100).toStringAsFixed(0)}%'
                '${p.chatCapable ? L.t.chatCapableMark : ''}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            )),
      ],
    );
  }
}

class _TrackersTab extends StatelessWidget {
  const _TrackersTab({
    required this.trackers,
    required this.onAdd,
    required this.onRemove,
  });

  final List<TrackerInfo> trackers;
  final VoidCallback onAdd;
  final void Function(TrackerInfo) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(L.t.trackers(trackers.length),
                    style: theme.textTheme.titleSmall),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: Text(L.t.addTracker),
              onPressed: onAdd,
            ),
          ],
        ),
        if (trackers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(L.t.noTrackersHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
        ...trackers.map((tr) => ListTile(
              dense: true,
              leading: Icon(
                tr.verified ? Icons.verified_outlined : Icons.hub_outlined,
                size: 18,
                color: tr.message.isNotEmpty
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              title: Text(tr.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
              subtitle: Text(
                'tier ${tr.tier}'
                '${tr.fails > 0 ? ' · ${L.t.trackerFails(tr.fails)}' : ''}'
                '${tr.message.isNotEmpty ? ' · ${tr.message}' : ''}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => onRemove(tr),
              ),
            )),
      ],
    );
  }
}
