// Torrent detail page (opened by tapping a task in the BT tab), layout
// after VueTorrent's TorrentDetail view, tracker management after
// qBittorrent's tracker tab:
//   * summary header: PIECE-LEVEL progress bar (PBS style, scrub-able:
//     tap/drag reports the probed piece like VueTorrent's hover tooltip)
//     + percent + live down/up speeds + peer counts
//   * TabBar (200 ms animation): Overview | Files | Peers | Trackers
//       - Overview: grouped label/value property cards
//       - Files: per-file progress + sort menu + per-file priority actions
//       - Peers: peer rows + sort menu + copy-address action
//       - Trackers: qBittorrent-style rows (status icon, tier, fails,
//         scrape seeds/leeches, message) with copy / reannounce / remove
//   * AppBar actions: pause/resume, delete
// (VueTorrent's piece-map tab and tags/categories have no counterpart in
// this core and are deliberately omitted.)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/l10n.dart';
import '../models.dart';
import 'home.dart';

/// Short route animation for the detail page (220 ms fade + rise).
Route<void> btViewRoute(BtViewPage page) {
  return PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, a, __, child) {
      final curve = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.05),
            end: Offset.zero,
          ).animate(curve),
          child: child,
        ),
      );
    },
  );
}

enum _FileSort { name, size, progress }

enum _PeerSort { address, progress, down }

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
  late final TabController _tabs = TabController(
    length: 4,
    vsync: this,
    animationDuration: const Duration(milliseconds: 200),
  );
  TorrentInfo? _torrent;
  PieceMap? _pieces;
  List<Map<String, dynamic>> _files = [];
  List<PeerInfo> _peers = [];
  List<TrackerInfo> _trackers = [];
  _FileSort _fileSort = _FileSort.name;
  bool _fileAsc = true;
  _PeerSort _peerSort = _PeerSort.address;
  bool _peerAsc = true;
  int? _tipPiece;
  Timer? _tipTimer;
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
    _tipTimer?.cancel();
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
        _pieces = _api.btPieces(widget.infohash);
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

  void _probePiece(int? piece) {
    _tipTimer?.cancel();
    setState(() => _tipPiece = piece);
    if (piece != null) {
      _tipTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _tipPiece = null);
      });
    }
  }

  void _setFilePriority(int index, int prio) {
    final n = _files.isEmpty
        ? 0
        : (_files
                .map((f) => (f['index'] as num?)?.toInt() ?? 0)
                .reduce((a, b) => a > b ? a : b) +
            1);
    final prios = List<int>.filled(n, 4);
    for (final f in _files) {
      final i = (f['index'] as num?)?.toInt() ?? 0;
      prios[i] = (f['priority'] as num?)?.toInt() ?? 4;
    }
    if (index < 0 || index >= n) return;
    prios[index] = prio;
    try {
      _api.call('bt.file_priorities',
          {'infohash': widget.infohash, 'priorities': prios});
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  List<Map<String, dynamic>> _sortedFiles() {
    final out = List<Map<String, dynamic>>.from(_files);
    int cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
      switch (_fileSort) {
        case _FileSort.name:
          return ('${a['path']}').compareTo('${b['path']}');
        case _FileSort.size:
          return ((a['size'] as num?)?.toInt() ?? 0)
              .compareTo((b['size'] as num?)?.toInt() ?? 0);
        case _FileSort.progress:
          return ((a['progress'] as num?)?.toDouble() ?? 0)
              .compareTo((b['progress'] as num?)?.toDouble() ?? 0);
      }
    }

    out.sort((a, b) {
      final c = cmp(a, b);
      return _fileAsc ? c : -c;
    });
    return out;
  }

  List<PeerInfo> _sortedPeers() {
    final out = List<PeerInfo>.from(_peers);
    int cmp(PeerInfo a, PeerInfo b) {
      switch (_peerSort) {
        case _PeerSort.address:
          return '${a.ip}:${a.port}'.compareTo('${b.ip}:${b.port}');
        case _PeerSort.progress:
          return a.progress.compareTo(b.progress);
        case _PeerSort.down:
          return a.downSpeed.compareTo(b.downSpeed);
      }
    }

    out.sort((a, b) {
      final c = cmp(a, b);
      return _peerAsc ? c : -c;
    });
    return out;
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

  /// qBittorrent-style tracker URL edit: replace in place, tier preserved.
  Future<void> _editTrackerDialog(TrackerInfo tr) async {
    final controller = TextEditingController(text: tr.url);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.btDetailEditTracker),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: L.t.trackerUrl,
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(L.t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(L.t.save)),
        ],
      ),
    );
    if (url == null || url.isEmpty || url == tr.url) return;
    try {
      _api.btEditTracker(widget.infohash, tr.url, url);
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
          _SummaryHeader(
            torrent: t,
            pieces: _pieces,
            tipPiece: _tipPiece,
            onProbe: _probePiece,
          ),
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
                _FilesTab(
                  files: _sortedFiles(),
                  sort: _fileSort,
                  asc: _fileAsc,
                  onSort: (s) => setState(() => _fileSort = s),
                  onToggleAsc: () => setState(() => _fileAsc = !_fileAsc),
                  onPriority: _setFilePriority,
                ),
                _PeersTab(
                  peers: _sortedPeers(),
                  sort: _peerSort,
                  asc: _peerAsc,
                  onSort: (s) => setState(() => _peerSort = s),
                  onToggleAsc: () => setState(() => _peerAsc = !_peerAsc),
                  onCopyAddress: (p) =>
                      _copy('${p.ip}:${p.port}', L.t.btDetailCopyAddress),
                ),
                _TrackersTab(
                  trackers: _trackers,
                  onAdd: _addTrackerDialog,
                  onEdit: _editTrackerDialog,
                  onRemove: (tr) {
                    try {
                      _api.btRemoveTracker(widget.infohash, tr.url);
                      _load();
                    } catch (e) {
                      if (mounted) showError(context, e);
                    }
                  },
                  onReannounce: (idx) {
                    try {
                      _api.btReannounce(widget.infohash, idx);
                    } catch (e) {
                      if (mounted) showError(context, e);
                    }
                  },
                  onCopyUrl: (tr) => _copy(tr.url, L.t.btDetailCopyUrl),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Piece-level progress bar + speeds, like VueTorrent's detail header.
/// The bar is scrub-able: tap/drag probes a piece (the mobile equivalent of
/// VueTorrent's cursor-pointer hover tooltip).
class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({
    required this.torrent,
    required this.pieces,
    required this.tipPiece,
    required this.onProbe,
  });

  final TorrentInfo? torrent;
  final PieceMap? pieces;
  final int? tipPiece;
  final void Function(int? piece) onProbe;

  int? _pieceAt(double dx, double width) {
    final p = pieces;
    if (p == null || p.numPieces <= 0 || width <= 0) return null;
    final i = (dx / width * p.numPieces).floor();
    return i.clamp(0, p.numPieces - 1);
  }

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
    final p = pieces;
    final tip = tipPiece;
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
                child: LayoutBuilder(
                  builder: (ctx, cons) => GestureDetector(
                    key: const ValueKey('btdetail-pieces'),
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) =>
                        onProbe(_pieceAt(d.localPosition.dx, cons.maxWidth)),
                    onPanDown: (d) =>
                        onProbe(_pieceAt(d.localPosition.dx, cons.maxWidth)),
                    onPanUpdate: (d) =>
                        onProbe(_pieceAt(d.localPosition.dx, cons.maxWidth)),
                    onPanEnd: (_) => onProbe(null),
                    child: SizedBox(
                      height: 10,
                      child: p == null || p.numPieces <= 0
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: t?.progress ?? 0,
                                minHeight: 10,
                                color: color,
                                backgroundColor: cs.surfaceContainerHighest,
                              ),
                            )
                          : CustomPaint(
                              painter: _PiecePainter(
                                pieces: p,
                                done: color,
                                missing: cs.surfaceContainerHighest,
                              ),
                              size: const Size(double.infinity, 10),
                            ),
                    ),
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
          if (tip != null && p != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                L.t.btDetailPieceTip(
                  tip + 1,
                  p.numPieces,
                  p.has(tip) ? L.t.btDetailPieceDone : L.t.btDetailPieceMissing,
                ),
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: color),
              ),
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

class _PiecePainter extends CustomPainter {
  _PiecePainter({
    required this.pieces,
    required this.done,
    required this.missing,
  });

  final PieceMap pieces;
  final Color done;
  final Color missing;

  @override
  void paint(Canvas canvas, Size size) {
    final n = pieces.numPieces;
    if (n <= 0 || size.width <= 0) return;
    final bg = Paint()..color = missing;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(3)),
      bg,
    );
    final fg = Paint()..color = done;
    final colW = size.width / n;
    for (var i = 0; i < n; i++) {
      if (!pieces.has(i)) continue;
      final x = i * colW;
      canvas.drawRect(
        Rect.fromLTW(x, 0, colW + 0.5, size.height),
        fg,
      );
    }
  }

  @override
  bool shouldRepaint(_PiecePainter old) =>
      old.pieces != pieces || old.done != done;
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

/// Files ("Content") with sort menu and per-file priority actions.
class _FilesTab extends StatelessWidget {
  const _FilesTab({
    required this.files,
    required this.sort,
    required this.asc,
    required this.onSort,
    required this.onToggleAsc,
    required this.onPriority,
  });

  final List<Map<String, dynamic>> files;
  final _FileSort sort;
  final bool asc;
  final ValueChanged<_FileSort> onSort;
  final VoidCallback onToggleAsc;
  final void Function(int index, int prio) onPriority;

  String _sortLabel(_FileSort s) {
    switch (s) {
      case _FileSort.name:
        return L.t.btDetailSortName;
      case _FileSort.size:
        return L.t.btDetailSortSize;
      case _FileSort.progress:
        return L.t.btDetailSortProgress;
    }
  }

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
        Row(
          children: [
            Expanded(
              child: Text(L.t.filesCount(files.length),
                  style: theme.textTheme.titleSmall),
            ),
            IconButton(
              key: const ValueKey('btfiles-asc'),
              icon: Icon(asc ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 18),
              tooltip: asc ? L.t.btDetailSortAsc : L.t.btDetailSortDesc,
              onPressed: onToggleAsc,
            ),
            PopupMenuButton<_FileSort>(
              key: const ValueKey('btfiles-sort'),
              icon: const Icon(Icons.sort, size: 20),
              tooltip: L.t.btDetailSort,
              onSelected: onSort,
              itemBuilder: (ctx) => [
                for (final s in _FileSort.values)
                  PopupMenuItem(
                    value: s,
                    child: Row(
                      children: [
                        if (sort == s)
                          Icon(Icons.check,
                              size: 18, color: theme.colorScheme.primary)
                        else
                          const SizedBox(width: 18),
                        const SizedBox(width: 8),
                        Text(_sortLabel(s)),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
        ...files.map((f) {
          final prog = (f['progress'] as num?)?.toDouble() ?? 0;
          final idx = (f['index'] as num?)?.toInt() ?? 0;
          final prio = (f['priority'] as num?)?.toInt() ?? 4;
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
                    PopupMenuButton<int>(
                      key: ValueKey('btfile-prio-$idx'),
                      icon: Icon(
                        prio == 0
                            ? Icons.block
                            : prio >= 6
                                ? Icons.keyboard_double_arrow_up
                                : Icons.more_vert,
                        size: 18,
                        color: prio == 0
                            ? theme.colorScheme.outline
                            : theme.colorScheme.onSurface,
                      ),
                      tooltip: L.t.btDetailPriority,
                      onSelected: (p) => onPriority(idx, p),
                      itemBuilder: (ctx) => [
                        PopupMenuItem(
                            value: 0, child: Text(L.t.btDetailPrioSkip)),
                        PopupMenuItem(
                            value: 4, child: Text(L.t.btDetailPrioNormal)),
                        PopupMenuItem(
                            value: 6, child: Text(L.t.btDetailPrioHigh)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                      value: prog,
                      minHeight: 4,
                      color: prio == 0
                          ? theme.colorScheme.outline
                          : theme.colorScheme.primary),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

/// Peers with sort menu and copy-address action.
class _PeersTab extends StatelessWidget {
  const _PeersTab({
    required this.peers,
    required this.sort,
    required this.asc,
    required this.onSort,
    required this.onToggleAsc,
    required this.onCopyAddress,
  });

  final List<PeerInfo> peers;
  final _PeerSort sort;
  final bool asc;
  final ValueChanged<_PeerSort> onSort;
  final VoidCallback onToggleAsc;
  final ValueChanged<PeerInfo> onCopyAddress;

  String _sortLabel(_PeerSort s) {
    switch (s) {
      case _PeerSort.address:
        return L.t.btDetailSortAddress;
      case _PeerSort.progress:
        return L.t.btDetailSortProgress;
      case _PeerSort.down:
        return L.t.btDetailSortDown;
    }
  }

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
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(L.t.peersCount(peers.length),
                    style: theme.textTheme.titleSmall),
              ),
            ),
            IconButton(
              key: const ValueKey('btpeers-asc'),
              icon: Icon(asc ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 18),
              tooltip: asc ? L.t.btDetailSortAsc : L.t.btDetailSortDesc,
              onPressed: onToggleAsc,
            ),
            PopupMenuButton<_PeerSort>(
              key: const ValueKey('btpeers-sort'),
              icon: const Icon(Icons.sort, size: 20),
              tooltip: L.t.btDetailSort,
              onSelected: onSort,
              itemBuilder: (ctx) => [
                for (final s in _PeerSort.values)
                  PopupMenuItem(
                    value: s,
                    child: Row(
                      children: [
                        if (sort == s)
                          Icon(Icons.check,
                              size: 18, color: theme.colorScheme.primary)
                        else
                          const SizedBox(width: 18),
                        const SizedBox(width: 8),
                        Text(_sortLabel(s)),
                      ],
                    ),
                  ),
              ],
            ),
          ],
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
                ' · ↓${formatSpeed(p.downSpeed)} ↑${formatSpeed(p.upSpeed)}'
                '${p.chatCapable ? L.t.chatCapableMark : ''}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              trailing: PopupMenuButton<String>(
                key: ValueKey('btpeer-menu-${p.ip}:${p.port}'),
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (v) {
                  if (v == 'copy') onCopyAddress(p);
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(
                      value: 'copy', child: Text(L.t.btDetailCopyAddress)),
                ],
              ),
            )),
      ],
    );
  }
}

/// qBittorrent-style tracker rows: status, tier, fails, scrape, message,
/// with copy / force-reannounce / remove actions.
class _TrackersTab extends StatelessWidget {
  const _TrackersTab({
    required this.trackers,
    required this.onAdd,
    required this.onRemove,
    required this.onEdit,
    required this.onReannounce,
    required this.onCopyUrl,
  });

  final List<TrackerInfo> trackers;
  final VoidCallback onAdd;
  final void Function(TrackerInfo) onRemove;
  final void Function(TrackerInfo) onEdit;
  final void Function(int index) onReannounce;
  final void Function(TrackerInfo) onCopyUrl;

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
              key: const ValueKey('bttracker-add'),
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
        ...trackers.asMap().entries.map((e) {
          final i = e.key;
          final tr = e.value;
          final Icon status;
          final String statusLabel;
          // qBittorrent status enum: 1 not contacted, 2 working,
          // 3 updating, 4 not working
          switch (tr.status) {
            case 3:
              status =
                  Icon(Icons.sync, size: 18, color: theme.colorScheme.primary);
              statusLabel = L.t.btDetailTrkUpdating;
            case 4:
              status = Icon(Icons.error_outline,
                  size: 18, color: theme.colorScheme.error);
              statusLabel = L.t.btDetailTrkNotWorking;
            case 2:
              status = Icon(Icons.verified_outlined,
                  size: 18, color: theme.colorScheme.tertiary);
              statusLabel = L.t.btDetailTrkWorking;
            default:
              status = Icon(Icons.help_outline,
                  size: 18, color: theme.colorScheme.outline);
              statusLabel = L.t.btDetailTrkNotContacted;
          }
          final scrape = tr.seeds >= 0
              ? ' · S${tr.seeds}/L${tr.leeches < 0 ? 0 : tr.leeches}'
              : '';
          return ListTile(
            dense: true,
            leading: status,
            title: Text(tr.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall),
            subtitle: Text(
              '$statusLabel · tier ${tr.tier}'
              '${tr.fails > 0 ? ' · ${L.t.trackerFails(tr.fails)}' : ''}'
              '$scrape'
              '${tr.message.isNotEmpty ? ' · ${tr.message}' : ''}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            trailing: PopupMenuButton<String>(
              key: ValueKey('bttracker-menu-$i'),
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (v) {
                switch (v) {
                  case 'copy':
                    onCopyUrl(tr);
                  case 'edit':
                    onEdit(tr);
                  case 'reannounce':
                    onReannounce(i);
                  case 'remove':
                    onRemove(tr);
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(value: 'copy', child: Text(L.t.btDetailCopyUrl)),
                PopupMenuItem(
                    value: 'edit', child: Text(L.t.btDetailEditTracker)),
                PopupMenuItem(
                    value: 'reannounce', child: Text(L.t.btDetailReannounce)),
                PopupMenuItem(
                  value: 'remove',
                  child: Text(L.t.delete,
                      style: TextStyle(color: theme.colorScheme.error)),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
