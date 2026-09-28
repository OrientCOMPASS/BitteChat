// BT 页：种子列表 + 添加磁力链 + 统计

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../models.dart';
import 'home.dart';
import '../core/l10n.dart';

class BtTab extends StatefulWidget {
  const BtTab({super.key});

  @override
  State<BtTab> createState() => _BtTabState();
}

class _BtTabState extends State<BtTab> {
  late final BitteApi _api = BitteApi.instance;
  List<TorrentInfo> _torrents = [];
  bool _includeChat = false;
  SessionStats _stats = SessionStats(
      dhtNodes: -1, uploadRate: 0, downloadRate: 0, numTorrents: 0);
  StreamSubscription<CoreEvent>? _sub;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _reload();
    _sub = _api.events.listen((e) {
      if (e.isBtUpdated) _reload();
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _reload());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    try {
      setState(() {
        _torrents = _api.torrents(includeChat: _includeChat);
        _stats = _api.btStats();
      });
    } catch (_) {}
  }

  Future<void> _addMagnet() async {
    final controller = TextEditingController();
    final magnet = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.addMagnet),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: L.t.magnetHint,
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: Icon(Icons.content_paste, size: 16),
            label: Text(L.t.paste),
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null) controller.text = data!.text!;
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(L.t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(L.t.add),
          ),
        ],
      ),
    );
    if (magnet == null || magnet.trim().isEmpty) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      _api.btAdd(magnet.trim());
      _reload();
      messenger.showSnackBar(SnackBar(content: Text(L.t.added)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _addTorrentFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['torrent'],
      );
      if (files.isEmpty) return;
      final file = files.single;
      final bytes = await file.xFile.readAsBytes();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        _api.btAddFile(bytes, name: file.name);
        _reload();
        messenger.showSnackBar(SnackBar(content: Text(L.t.addedTorrentFile)));
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('$e')));
      }
    } catch (e) {
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t.btTab),
        actions: [
          IconButton(
            tooltip: _includeChat ? L.t.hideChatTorrents : L.t.showChatTorrents,
            icon: Icon(_includeChat
                ? Icons.visibility
                : Icons.visibility_off_outlined),
            onPressed: () {
              setState(() => _includeChat = !_includeChat);
              _reload();
            },
          ),
          IconButton(
            tooltip: L.t.rateLimits,
            icon: Icon(Icons.speed),
            onPressed: _openLimitsSheet,
          ),
          IconButton(
            tooltip: L.t.refresh,
            icon: Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: Column(
        children: [
          GestureDetector(
            onTap: _openLimitsSheet,
            child: _StatsBar(stats: _stats),
          ),
          const Divider(height: 1),
          Expanded(
            child: _torrents.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cloud_download_outlined,
                            size: 64, color: theme.colorScheme.outlineVariant),
                        SizedBox(height: 12),
                        Text(L.t.noBtTasks,
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(color: theme.colorScheme.outline)),
                        SizedBox(height: 4),
                        Text(L.t.noBtTasksHint,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _torrents.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _TorrentTile(
                      torrent: _torrents[i],
                      onTap: () => _openDetail(_torrents[i]),
                      onControl: (op, {bool deleteFiles = false}) {
                        try {
                          _api.btControl(_torrents[i].infohash, op,
                              deleteFiles: deleteFiles);
                          _reload();
                        } catch (e) {
                          if (mounted) showError(context, e);
                        }
                      },
                      onCopyMagnet: () async {
                        await Clipboard.setData(
                            ClipboardData(text: _torrents[i].magnet));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(L.t.magnetCopied)));
                        }
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddSheet(),
        child: Icon(Icons.add),
      ),
    );
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

  Future<void> _openLimitsSheet() async {
    final limits = _api.btLimits();
    final upCtrl = TextEditingController(
        text: limits.up > 0 ? '${limits.up ~/ 1024}' : '');
    final downCtrl = TextEditingController(
        text: limits.down > 0 ? '${limits.down ~/ 1024}' : '');
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(L.t.rateLimitsHint, style: Theme.of(ctx).textTheme.titleSmall),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: upCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: L.t.upload, border: OutlineInputBorder()),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: downCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: L.t.download, border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                int parse(TextEditingController c) {
                  final v = int.tryParse(c.text.trim()) ?? 0;
                  return v <= 0 ? 0 : v * 1024;
                }

                try {
                  _api.btSetLimits(up: parse(upCtrl), down: parse(downCtrl));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(L.t.limitsApplied)));
                } catch (e) {
                  showError(context, e);
                }
              },
              child: Text(L.t.save),
            ),
          ],
        ),
      ),
    );
    upCtrl.dispose();
    downCtrl.dispose();
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.add_link),
              title: Text(L.t.addMagnet),
              onTap: () {
                Navigator.pop(ctx);
                _addMagnet();
              },
            ),
            ListTile(
              leading: Icon(Icons.upload_file),
              title: Text(L.t.importTorrent),
              onTap: () {
                Navigator.pop(ctx);
                _addTorrentFile();
              },
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _StatsBar extends StatelessWidget {
  const _StatsBar({required this.stats});
  final SessionStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          _StatChip(
            icon: Icons.arrow_downward,
            label: formatSpeed(stats.downloadRate),
            color: theme.colorScheme.primary,
          ),
          SizedBox(width: 16),
          _StatChip(
            icon: Icons.arrow_upward,
            label: formatSpeed(stats.uploadRate),
            color: theme.colorScheme.tertiary,
          ),
          const Spacer(),
          _StatChip(
            icon: Icons.public,
            label: stats.dhtNodes >= 0 ? 'DHT ${stats.dhtNodes}' : 'DHT …',
            color: theme.colorScheme.outline,
          ),
          SizedBox(width: 12),
          _StatChip(
            icon: Icons.layers,
            label: L.t.tasksCount(stats.numTorrents),
            color: theme.colorScheme.outline,
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.color,
  });
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        SizedBox(width: 3),
        Text(label,
            style:
                Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}

class _TorrentTile extends StatelessWidget {
  const _TorrentTile({
    required this.torrent,
    required this.onControl,
    required this.onCopyMagnet,
    this.onTap,
  });

  final TorrentInfo torrent;
  final VoidCallback? onTap;
  final void Function(String op, {bool deleteFiles}) onControl;
  final VoidCallback onCopyMagnet;

  IconData get _kindIcon {
    switch (torrent.kind) {
      case 1:
        return Icons.forum;
      case 2:
        return Icons.chat;
      case 3:
        return Icons.rss_feed;
      default:
        return Icons.cloud_download;
    }
  }

  String get _stateLabel {
    if (torrent.paused) return L.t.statePaused;
    switch (torrent.state) {
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
        return torrent.state;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = torrent;
    final pct = (t.progress * 100).clamp(0, 100);
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: t.isChatInternal
            ? theme.colorScheme.tertiaryContainer
            : theme.colorScheme.primaryContainer,
        child: Icon(_kindIcon,
            size: 20,
            color: t.isChatInternal
                ? theme.colorScheme.onTertiaryContainer
                : theme.colorScheme.onPrimaryContainer),
      ),
      title: Text(t.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: t.finished ? 1.0 : t.progress,
              minHeight: 4,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          SizedBox(height: 3),
          Text(
            '$_stateLabel  ${pct.toStringAsFixed(0)}%'
            '  ↑${formatSpeed(t.uploadRate)}'
            '  ↓${formatSpeed(t.downloadRate)}'
            '  ${t.numPeers} peers / ${t.numSeeds} seeds'
            '${t.error.isNotEmpty ? "  ⚠ ${t.error}" : ""}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (op) {
          if (op == 'copy') {
            onCopyMagnet();
          } else if (op == 'delete') {
            _confirmDelete(context);
          } else {
            onControl(op);
          }
        },
        itemBuilder: (ctx) => [
          if (t.paused)
            PopupMenuItem(value: 'resume', child: Text(L.t.resume))
          else
            PopupMenuItem(value: 'pause', child: Text(L.t.pause)),
          PopupMenuItem(value: 'copy', child: Text(L.t.copyMagnet)),
          PopupMenuItem(value: 'recheck', child: Text(L.t.recheck)),
          PopupMenuDivider(),
          PopupMenuItem(
            value: 'delete',
            child: Text(L.t.delete,
                style: TextStyle(color: theme.colorScheme.error)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.deleteTaskQ(torrent.name)),
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
    if (result == 'keep') onControl('remove', deleteFiles: false);
    if (result == 'delete') onControl('remove', deleteFiles: true);
  }
}

/// 任务详情：文件进度 + 连接节点 + 元信息
class TorrentDetailSheet extends StatefulWidget {
  const TorrentDetailSheet({
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
  State<TorrentDetailSheet> createState() => _TorrentDetailSheetState();
}

class _TorrentDetailSheetState extends State<TorrentDetailSheet> {
  late final BitteApi _api = BitteApi.instance;
  List<Map<String, dynamic>> _files = [];
  List<PeerInfo> _peers = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _load() {
    if (!mounted) return;
    try {
      final f = _api.call('bt.files', {'infohash': widget.infohash});
      final peers = _api.btPeers(widget.infohash);
      setState(() {
        _files = ((f['files'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _peers = peers;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          Text(widget.name, style: theme.textTheme.titleMedium),
          SizedBox(height: 4),
          Text('infohash: ${widget.infohash}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          if (widget.savePath.isNotEmpty) ...[
            SizedBox(height: 4),
            Text(L.t.savePath(widget.savePath),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
          SizedBox(height: 16),
          Text(L.t.filesCount(_files.length),
              style: theme.textTheme.titleSmall),
          if (_files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(L.t.noMetadata,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
          ..._files.map((f) {
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
                  SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: prog, minHeight: 4),
                  ),
                ],
              ),
            );
          }),
          SizedBox(height: 12),
          Text(L.t.peersCount(_peers.length),
              style: theme.textTheme.titleSmall),
          if (_peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(L.t.noPeers,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
          ..._peers.map((p) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  p.chatCapable ? Icons.chat : Icons.cloud_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                title:
                    Text('${p.ip}:${p.port}', style: theme.textTheme.bodySmall),
                subtitle: Text(
                  '${p.client} · ${(p.progress * 100).toStringAsFixed(0)}%'
                  '${p.chatCapable ? L.t.chatCapableMark : ""}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              )),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}
