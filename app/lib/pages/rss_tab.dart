// RSS 订阅页：订阅源列表 → 条目列表 → 条目详情；磁力/附件一键转 BT 下载

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api.dart';
import '../models.dart';
import '../widgets/time_fmt.dart';
import 'home.dart';

class RssTab extends StatefulWidget {
  const RssTab({super.key});

  @override
  State<RssTab> createState() => _RssTabState();
}

class _RssTabState extends State<RssTab> {
  late final BitteApi _api = BitteApi.instance;
  List<FeedInfo> _feeds = [];
  StreamSubscription<CoreEvent>? _sub;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _reload();
    _sub = _api.events.listen((e) {
      if (e.isRssUpdated) _reload();
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _reload());
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
      setState(() => _feeds = _api.feeds());
    } catch (_) {}
  }

  Future<void> _addFeed() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加订阅'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/feed.xml',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('添加')),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    try {
      _api.rssAdd(url.trim());
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已添加，正在后台抓取……')));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _openFeed(FeedInfo feed) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => FeedItemsPage(feed: feed)));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅'),
        actions: [
          IconButton(
            tooltip: '全部刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              try {
                _api.rssRefresh();
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('正在刷新全部订阅')));
              } catch (e) {
                showError(context, e);
              }
            },
          ),
        ],
      ),
      body: _feeds.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.rss_feed_outlined,
                      size: 64, color: theme.colorScheme.outlineVariant),
                  const SizedBox(height: 12),
                  Text('还没有订阅',
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(color: theme.colorScheme.outline)),
                  const SizedBox(height: 4),
                  Text('支持 RSS 2.0 与 Atom；含磁力/种子的条目可一键转 BT 下载',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ],
              ),
            )
          : ListView.separated(
              itemCount: _feeds.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final f = _feeds[i];
                return ListTile(
                  onTap: () => _openFeed(f),
                  leading: CircleAvatar(
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    child: Icon(
                      f.error.isNotEmpty ? Icons.error_outline : Icons.rss_feed,
                      color: f.error.isNotEmpty
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSecondaryContainer,
                      size: 20,
                    ),
                  ),
                  title: Text(f.displayName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    f.error.isNotEmpty
                        ? '⚠ ${f.error}'
                        : (f.lastFetch > 0
                            ? '上次更新 ${formatListTime(f.lastFetch)}'
                            : '尚未抓取'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: f.error.isNotEmpty
                            ? theme.colorScheme.error
                            : theme.colorScheme.outline),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (f.unread > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            f.unread > 99 ? '99+' : '${f.unread}',
                            style: TextStyle(
                                color: theme.colorScheme.onPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text('删除「${f.displayName}」？'),
                              content: const Text('将同时删除该源的全部已缓存条目。'),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('取消')),
                                FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('删除')),
                              ],
                            ),
                          );
                          if (ok == true) {
                            try {
                              _api.rssRemove(f.id);
                              _reload();
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          }
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'rss-add',
        onPressed: _addFeed,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class FeedItemsPage extends StatefulWidget {
  const FeedItemsPage({super.key, required this.feed});
  final FeedInfo feed;

  @override
  State<FeedItemsPage> createState() => _FeedItemsPageState();
}

class _FeedItemsPageState extends State<FeedItemsPage> {
  late final BitteApi _api = BitteApi.instance;
  List<RssItem> _items = [];
  bool _unreadOnly = false;

  @override
  void initState() {
    super.initState();
    _reload();
    try {
      _api.rssRefresh(id: widget.feed.id);
    } catch (_) {}
  }

  void _reload() {
    if (!mounted) return;
    try {
      final r =
          _api.rssItems(widget.feed.id, limit: 200, unreadOnly: _unreadOnly);
      setState(() {
        _items = r.items;
      });
    } catch (_) {}
  }

  Future<void> _openItem(RssItem item) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ItemDetailPage(item: item)));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.feed.displayName),
        actions: [
          IconButton(
            tooltip: _unreadOnly ? '显示全部' : '只看未读',
            icon: Icon(_unreadOnly ? Icons.mail : Icons.mark_email_unread),
            onPressed: () {
              setState(() => _unreadOnly = !_unreadOnly);
              _reload();
            },
          ),
          IconButton(
            tooltip: '全部标记已读',
            icon: const Icon(Icons.done_all),
            onPressed: () {
              try {
                _api.rssMarkFeedRead(widget.feed.id);
                _reload();
              } catch (e) {
                showError(context, e);
              }
            },
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              try {
                _api.rssRefresh(id: widget.feed.id);
              } catch (e) {
                showError(context, e);
              }
              Future.delayed(const Duration(seconds: 2), _reload);
            },
          ),
        ],
      ),
      body: _items.isEmpty
          ? Center(
              child: Text(
                _unreadOnly ? '没有未读条目' : '暂无条目（可能仍在抓取）',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                try {
                  _api.rssRefresh(id: widget.feed.id);
                } catch (_) {}
                await Future.delayed(const Duration(seconds: 2));
                _reload();
              },
              child: ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final it = _items[i];
                  return ListTile(
                    onTap: () => _openItem(it),
                    leading: it.read
                        ? null
                        : Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(top: 8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                    title: Text(
                      it.title.isEmpty ? '(无标题)' : it.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight:
                            it.read ? FontWeight.normal : FontWeight.w600,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (it.snippet.isNotEmpty)
                          Text(it.snippet,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(formatListTime(it.ts),
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.outline)),
                            if (it.author.isNotEmpty) ...[
                              Text(' · ${it.author}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.outline)),
                            ],
                            if (it.hasTorrent) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.cloud_download,
                                  size: 14, color: theme.colorScheme.tertiary),
                            ],
                          ],
                        ),
                      ],
                    ),
                    trailing: it.hasDownload
                        ? IconButton(
                            tooltip: '转 BT 下载',
                            icon: Icon(Icons.download,
                                color: theme.colorScheme.primary),
                            onPressed: () {
                              try {
                                final r = _api.rssDownload(it.id);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(r['started'] == true
                                          ? '已开始后台处理，稍后见种子页'
                                          : '已加入下载队列')),
                                );
                              } catch (e) {
                                showError(context, e);
                              }
                            },
                          )
                        : null,
                  );
                },
              ),
            ),
    );
  }
}

class ItemDetailPage extends StatefulWidget {
  const ItemDetailPage({super.key, required this.item});
  final RssItem item;

  @override
  State<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  late final BitteApi _api = BitteApi.instance;
  late RssItem _item = widget.item;

  @override
  void initState() {
    super.initState();
    // marks read on the core side and returns full content
    try {
      final full = _api.rssItemDetail(widget.item.id);
      if (full != null) _item = full;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final it = _item;
    return Scaffold(
      appBar: AppBar(
        title: const Text('正文'),
        actions: [
          if (it.link.isNotEmpty)
            IconButton(
              tooltip: '浏览器打开',
              icon: const Icon(Icons.open_in_browser),
              onPressed: () async {
                final uri = Uri.tryParse(it.link);
                if (uri != null && await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
          if (it.hasDownload)
            IconButton(
              tooltip: '转 BT 下载',
              icon: const Icon(Icons.download),
              onPressed: () {
                try {
                  _api.rssDownload(it.id);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已开始后台处理，稍后见种子页')));
                } catch (e) {
                  showError(context, e);
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(it.title.isEmpty ? '(无标题)' : it.title,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(
            children: [
              if (it.author.isNotEmpty)
                Text(it.author,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              if (it.author.isNotEmpty && it.ts > 0)
                Text(' · ',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              if (it.ts > 0)
                Text(formatFull(it.ts),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
          const SizedBox(height: 16),
          if (it.magnet.isNotEmpty)
            Card(
              color: theme.colorScheme.tertiaryContainer,
              child: ListTile(
                leading: const Icon(Icons.cloud_download),
                title: const Text('此条目附带 BT 资源'),
                subtitle: Text(it.magnet,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: FilledButton(
                  onPressed: () {
                    try {
                      _api.rssDownload(it.id);
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已加入下载队列')));
                    } catch (e) {
                      showError(context, e);
                    }
                  },
                  child: const Text('下载'),
                ),
              ),
            ),
          const SizedBox(height: 8),
          SelectableText(
            (it.content ?? it.snippet).isEmpty
                ? '（无正文）'
                : (it.content ?? it.snippet),
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
