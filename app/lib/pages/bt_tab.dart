// BT 页：种子列表 + 添加磁力链 + 统计

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../models.dart';
import 'home.dart';

class BtTab extends StatefulWidget {
  const BtTab({super.key});

  @override
  State<BtTab> createState() => _BtTabState();
}

class _BtTabState extends State<BtTab> {
  late final BitteApi _api = BitteApi.instance;
  List<TorrentInfo> _torrents = [];
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
        _torrents = _api.torrents();
        _stats = _api.btStats();
      });
    } catch (_) {}
  }

  Future<void> _addMagnet() async {
    final controller = TextEditingController();
    final magnet = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加磁力链接'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'magnet:?xt=urn:btih:...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.content_paste, size: 16),
            label: const Text('粘贴'),
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null) controller.text = data!.text!;
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('添加'),
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
      messenger.showSnackBar(const SnackBar(content: Text('已添加')));
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
        messenger.showSnackBar(const SnackBar(content: Text('已添加种子文件')));
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
        title: const Text('种子'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: Column(
        children: [
          _StatsBar(stats: _stats),
          const Divider(height: 1),
          Expanded(
            child: _torrents.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cloud_download_outlined,
                            size: 64, color: theme.colorScheme.outlineVariant),
                        const SizedBox(height: 12),
                        Text('暂无任务',
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(color: theme.colorScheme.outline)),
                        const SizedBox(height: 4),
                        Text('点击右下角按钮添加磁力链接或种子文件',
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
                              const SnackBar(content: Text('磁力链接已复制')));
                        }
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddSheet(),
        child: const Icon(Icons.add),
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

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_link),
              title: const Text('添加磁力链接'),
              onTap: () {
                Navigator.pop(ctx);
                _addMagnet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('导入种子文件 (.torrent)'),
              onTap: () {
                Navigator.pop(ctx);
                _addTorrentFile();
              },
            ),
            const SizedBox(height: 8),
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
          const SizedBox(width: 16),
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
          const SizedBox(width: 12),
          _StatChip(
            icon: Icons.layers,
            label: '${stats.numTorrents} 任务',
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
        const SizedBox(width: 3),
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
    if (torrent.paused) return '已暂停';
    switch (torrent.state) {
      case 'seeding':
        return '做种中';
      case 'downloading':
        return '下载中';
      case 'metadata':
        return '获取元数据…';
      case 'checking':
        return '校验中';
      case 'finished':
        return '已完成';
      case 'queued':
        return '排队中';
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
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: t.finished ? 1.0 : t.progress,
              minHeight: 4,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 3),
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
            const PopupMenuItem(value: 'resume', child: Text('继续'))
          else
            const PopupMenuItem(value: 'pause', child: Text('暂停')),
          const PopupMenuItem(value: 'copy', child: Text('复制磁力链接')),
          const PopupMenuItem(value: 'recheck', child: Text('重新校验')),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: theme.colorScheme.error)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${torrent.name}」？'),
        content: const Text('选择是否同时删除已下载的文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('仅删除任务'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('删除任务+文件'),
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
          const SizedBox(height: 4),
          Text('infohash: ${widget.infohash}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          if (widget.savePath.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('保存目录: ${widget.savePath}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
          const SizedBox(height: 16),
          Text('文件（${_files.length}）', style: theme.textTheme.titleSmall),
          if (_files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('元数据尚未获取',
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
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: prog, minHeight: 4),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 12),
          Text('连接节点（${_peers.length}）', style: theme.textTheme.titleSmall),
          if (_peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('暂无连接',
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
                  '${p.chatCapable ? " · 支持聊天" : ""}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              )),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
