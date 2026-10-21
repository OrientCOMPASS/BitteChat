// VueTorrent-style torrent dashboard (see docs/PLATFORMS.md / README):
//   * session stats header with a transfer sparkline (down/up history)
//   * status filter chips (all / active / stalled / paused / finished / error)
//   * search + sort menu + table/grid view modes
//   * per-torrent property chips (size, speeds, peers/seeds, state) like
//     VueTorrent's configurable card properties
//   * long-press multi-select with a bulk action bar (pause/resume/delete)
// Tapping a torrent still opens the existing TorrentDetailSheet.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/l10n.dart';
import '../models.dart';
import 'bt_tab.dart';
import 'home.dart';

enum BtViewFilter { all, active, stalled, paused, finished, error }

enum BtViewSort { name, progress, size, down, up, peers }

enum BtViewMode { table, grid }

class BtViewPage extends StatefulWidget {
  const BtViewPage({super.key});

  @override
  State<BtViewPage> createState() => _BtViewPageState();
}

class _BtViewPageState extends State<BtViewPage> {
  late final BitteApi _api = BitteApi.instance;
  List<TorrentInfo> _all = [];
  SessionStats _stats = SessionStats(
      dhtNodes: -1, uploadRate: 0, downloadRate: 0, numTorrents: 0);
  final List<double> _dlHist = [];
  final List<double> _ulHist = [];
  static const int _histMax = 48;

  BtViewFilter _filter = BtViewFilter.all;
  BtViewSort _sort = BtViewSort.down;
  BtViewMode _mode = BtViewMode.table;
  bool _searchOpen = false;
  String _query = '';
  final Set<String> _selected = {};
  StreamSubscription<CoreEvent>? _sub;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _reload();
    _sub = _api.events.listen((e) {
      if (e.isBtUpdated) _reload();
    });
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _reload());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    try {
      setState(() {
        _all = _api.torrents(includeChat: true);
        _stats = _api.btStats();
        _dlHist.add(_stats.downloadRate.toDouble());
        _ulHist.add(_stats.uploadRate.toDouble());
        if (_dlHist.length > _histMax) _dlHist.removeAt(0);
        if (_ulHist.length > _histMax) _ulHist.removeAt(0);
        _selected.removeWhere((ih) => !_all.any((t) => t.infohash == ih));
      });
    } catch (_) {}
  }

  bool _matches(TorrentInfo t, BtViewFilter f) {
    switch (f) {
      case BtViewFilter.all:
        return true;
      case BtViewFilter.active:
        return !t.paused && (t.downloadRate > 0 || t.uploadRate > 0);
      case BtViewFilter.stalled:
        return !t.paused &&
            !t.finished &&
            t.downloadRate == 0 &&
            t.uploadRate == 0;
      case BtViewFilter.paused:
        return t.paused;
      case BtViewFilter.finished:
        return t.finished;
      case BtViewFilter.error:
        return t.error.isNotEmpty;
    }
  }

  List<TorrentInfo> _visible() {
    final q = _query.trim().toLowerCase();
    final out = _all
        .where((t) => _matches(t, _filter))
        .where((t) => q.isEmpty || t.name.toLowerCase().contains(q))
        .toList();
    int cmp(TorrentInfo a, TorrentInfo b) {
      switch (_sort) {
        case BtViewSort.name:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case BtViewSort.progress:
          return a.progress.compareTo(b.progress);
        case BtViewSort.size:
          return a.totalBytes.compareTo(b.totalBytes);
        case BtViewSort.down:
          return a.downloadRate.compareTo(b.downloadRate);
        case BtViewSort.up:
          return a.uploadRate.compareTo(b.uploadRate);
        case BtViewSort.peers:
          return (a.numPeers + a.numSeeds).compareTo(b.numPeers + b.numSeeds);
      }
    }

    out.sort((a, b) {
      final c = cmp(a, b);
      return c != 0 ? c : a.infohash.compareTo(b.infohash);
    });
    return out;
  }

  String _filterLabel(BtViewFilter f) {
    switch (f) {
      case BtViewFilter.all:
        return L.t.btViewFilterAll;
      case BtViewFilter.active:
        return L.t.btViewFilterActive;
      case BtViewFilter.stalled:
        return L.t.btViewFilterStalled;
      case BtViewFilter.paused:
        return L.t.btViewFilterPaused;
      case BtViewFilter.finished:
        return L.t.btViewFilterFinished;
      case BtViewFilter.error:
        return L.t.btViewFilterError;
    }
  }

  String _sortLabel(BtViewSort s) {
    switch (s) {
      case BtViewSort.name:
        return L.t.btViewSortName;
      case BtViewSort.progress:
        return L.t.btViewSortProgress;
      case BtViewSort.size:
        return L.t.btViewSortSize;
      case BtViewSort.down:
        return L.t.btViewSortDown;
      case BtViewSort.up:
        return L.t.btViewSortUp;
      case BtViewSort.peers:
        return L.t.btViewSortPeers;
    }
  }

  void _toggleSelect(String ih) {
    setState(() {
      if (!_selected.remove(ih)) {
        _selected.add(ih);
      }
    });
  }

  Future<void> _openDetail(TorrentInfo t) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => TorrentDetailSheet(
        infohash: t.infohash,
        name: t.name,
        savePath: t.savePath,
        magnet: t.magnet,
      ),
    );
    _reload();
  }

  Future<void> _bulk(String op) async {
    final ids = _selected.toList();
    if (op == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(L.t.delete),
          content: Text(L.t.btViewSelected(ids.length)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(L.t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(L.t.delete)),
          ],
        ),
      );
      if (ok != true) return;
    }
    for (final ih in ids) {
      try {
        if (op == 'delete') {
          _api.btControl(ih, 'remove');
        } else {
          _api.btControl(ih, op);
        }
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
    setState(() => _selected.clear());
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visible();
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t.btViewTitle),
        actions: [
          IconButton(
            key: const ValueKey('btview-search'),
            icon: Icon(_searchOpen ? Icons.close : Icons.search),
            tooltip: L.t.btViewSearch,
            onPressed: () => setState(() {
              _searchOpen = !_searchOpen;
              if (!_searchOpen) _query = '';
            }),
          ),
          PopupMenuButton<BtViewSort>(
            icon: const Icon(Icons.sort),
            tooltip: L.t.btViewSort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (ctx) => [
              for (final s in BtViewSort.values)
                PopupMenuItem(
                  value: s,
                  child: Row(
                    children: [
                      if (_sort == s)
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
          IconButton(
            key: const ValueKey('btview-mode'),
            icon: Icon(_mode == BtViewMode.table
                ? Icons.grid_view_rounded
                : Icons.table_rows),
            tooltip: _mode == BtViewMode.table
                ? L.t.btViewModeGrid
                : L.t.btViewModeTable,
            onPressed: () => setState(() => _mode =
                _mode == BtViewMode.table ? BtViewMode.grid : BtViewMode.table),
          ),
        ],
      ),
      body: Column(
        children: [
          _Header(stats: _stats, dl: _dlHist, ul: _ulHist),
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: TextField(
                key: const ValueKey('btview-search-field'),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: L.t.btViewSearch,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final f in BtViewFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(
                          '${_filterLabel(f)} (${_all.where((t) => _matches(t, f)).length})'),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(L.t.btViewEmpty,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.outline)))
                : _mode == BtViewMode.table
                    ? ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (ctx, i) => _TableRow(
                          t: visible[i],
                          selected: _selected.contains(visible[i].infohash),
                          selecting: _selected.isNotEmpty,
                          onTap: () => _selected.isNotEmpty
                              ? _toggleSelect(visible[i].infohash)
                              : _openDetail(visible[i]),
                          onLongPress: () => _toggleSelect(visible[i].infohash),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 340,
                          childAspectRatio: 1.35,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: visible.length,
                        itemBuilder: (ctx, i) => _GridCard(
                          t: visible[i],
                          selected: _selected.contains(visible[i].infohash),
                          selecting: _selected.isNotEmpty,
                          onTap: () => _selected.isNotEmpty
                              ? _toggleSelect(visible[i].infohash)
                              : _openDetail(visible[i]),
                          onLongPress: () => _toggleSelect(visible[i].infohash),
                        ),
                      ),
          ),
        ],
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : Container(
              color: theme.colorScheme.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(child: Text(L.t.btViewSelected(_selected.length))),
                    IconButton(
                      key: const ValueKey('btview-select-all'),
                      icon: const Icon(Icons.select_all),
                      tooltip: L.t.btViewSelectAll,
                      onPressed: () => setState(() {
                        _selected
                          ..clear()
                          ..addAll(visible.map((t) => t.infohash));
                      }),
                    ),
                    IconButton(
                      icon: const Icon(Icons.pause),
                      tooltip: L.t.pause,
                      onPressed: () => _bulk('pause'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      tooltip: L.t.resume,
                      onPressed: () => _bulk('resume'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: L.t.delete,
                      onPressed: () => _bulk('delete'),
                    ),
                    IconButton(
                      key: const ValueKey('btview-clear-sel'),
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _selected.clear()),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Session stats + transfer sparkline (VueTorrent's top bar / graphs).
class _Header extends StatelessWidget {
  const _Header({
    required this.stats,
    required this.dl,
    required this.ul,
  });

  final SessionStats stats;
  final List<double> dl;
  final List<double> ul;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.arrow_downward, size: 16, color: cs.primary),
              const SizedBox(width: 4),
              Text(formatSpeed(stats.downloadRate),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: cs.primary)),
              const SizedBox(width: 16),
              Icon(Icons.arrow_upward, size: 16, color: cs.tertiary),
              const SizedBox(width: 4),
              Text(formatSpeed(stats.uploadRate),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: cs.tertiary)),
              const Spacer(),
              Text(
                stats.dhtNodes >= 0 ? 'DHT ${stats.dhtNodes}' : 'DHT …',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.outline),
              ),
              const SizedBox(width: 10),
              Text(
                L.t.tasksCount(stats.numTorrents),
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.outline),
              ),
            ],
          ),
          SizedBox(
            height: 34,
            child: CustomPaint(
              painter: _SparkPainter(
                  dl: dl, ul: ul, dlColor: cs.primary, ulColor: cs.tertiary),
              size: const Size(double.infinity, 34),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.dl,
    required this.ul,
    required this.dlColor,
    required this.ulColor,
  });

  final List<double> dl;
  final List<double> ul;
  final Color dlColor;
  final Color ulColor;

  void _paintSeries(Canvas c, Size s, List<double> v, double max, Color color) {
    if (v.length < 2) return;
    final p = Path();
    for (var i = 0; i < v.length; i++) {
      final x = s.width * i / (v.length - 1);
      final y = s.height - (v[i] / max) * (s.height - 4) - 2;
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    c.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final max = [...dl, ...ul, 1.0].reduce(math.max);
    _paintSeries(canvas, size, dl, max, dlColor);
    _paintSeries(canvas, size, ul, max, ulColor);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true;
}

/// Table row: state icon | name+progress | speed column (VueTorrent table).
class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.t,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final TorrentInfo t;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _stateColorOf(t, cs);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? cs.primaryContainer.withValues(alpha: 0.35) : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            if (selecting)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: cs.primary),
              ),
            Icon(_stateIconOf(t), size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium),
                      ),
                      _KindChip(label: kindLabelOf(t)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: t.progress,
                      minHeight: 5,
                      color: color,
                      backgroundColor: cs.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${formatBytes(t.totalBytes)} · ${(t.progress * 100).toStringAsFixed(1)}% · '
                    '${t.numPeers}P/${t.numSeeds}S',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.outline),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(formatSpeed(t.downloadRate),
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: cs.primary)),
                Text(formatSpeed(t.uploadRate),
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: cs.tertiary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Card with property chips (VueTorrent's configurable card properties).
class _GridCard extends StatelessWidget {
  const _GridCard({
    required this.t,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final TorrentInfo t;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _stateColorOf(t, cs);
    return Card(
      color: selected ? cs.primaryContainer.withValues(alpha: 0.45) : null,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_stateIconOf(t), size: 16, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  if (selecting)
                    Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: cs.primary),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: t.progress,
                  minHeight: 6,
                  color: color,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 4),
              Text('${(t.progress * 100).toStringAsFixed(1)}%',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: color)),
              const Spacer(),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _PropChip(icon: Icons.save, text: formatBytes(t.totalBytes)),
                  _PropChip(
                      icon: Icons.arrow_downward,
                      text: formatSpeed(t.downloadRate)),
                  _PropChip(
                      icon: Icons.arrow_upward,
                      text: formatSpeed(t.uploadRate)),
                  _PropChip(
                      icon: Icons.people_outline,
                      text: '${t.numPeers}P/${t.numSeeds}S'),
                  _KindChip(label: kindLabelOf(t)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PropChip extends StatelessWidget {
  const _PropChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: cs.outline),
          const SizedBox(width: 3),
          Text(text,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: cs.onSecondaryContainer)),
    );
  }
}

Color _stateColorOf(TorrentInfo t, ColorScheme cs) {
  if (t.error.isNotEmpty) return cs.error;
  if (t.paused) return cs.outline;
  if (t.finished) return cs.tertiary;
  if (t.downloadRate > 0) return cs.primary;
  if (t.uploadRate > 0) return cs.tertiary;
  return cs.outline;
}

IconData _stateIconOf(TorrentInfo t) {
  if (t.error.isNotEmpty) return Icons.error_outline;
  if (t.paused) return Icons.pause_circle_outline;
  if (t.finished) return Icons.check_circle_outline;
  if (t.downloadRate > 0) return Icons.arrow_downward;
  if (t.uploadRate > 0) return Icons.arrow_upward;
  return Icons.hourglass_empty;
}

String kindLabelOf(TorrentInfo t) {
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
