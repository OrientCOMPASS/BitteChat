// RSS 订阅页：订阅源列表 → 条目列表 → 条目详情；磁力/附件一键转 BT 下载

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api.dart';
import '../models.dart';
import '../widgets/time_fmt.dart';
import 'home.dart';
import '../core/l10n.dart';

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

  static bool _initialRefreshDone = false;

  @override
  void initState() {
    super.initState();
    _reload();
    if (!_initialRefreshDone && _api.available) {
      _initialRefreshDone = true;
      try {
        _api.rssRefresh();
      } catch (_) {}
    }
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
        title: Text(L.t.addFeed),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: 'https://example.com/feed.xml',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(L.t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(L.t.add)),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    try {
      _api.rssAdd(url.trim());
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t.feedAdded)));
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
        title: Text(L.t.rssTab),
        actions: [
          IconButton(
            tooltip: L.t.refreshAll,
            icon: Icon(Icons.refresh),
            onPressed: () {
              try {
                _api.rssRefresh();
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(L.t.refreshingAll)));
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
                  SizedBox(height: 12),
                  Text(L.t.noFeeds,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(color: theme.colorScheme.outline)),
                  SizedBox(height: 4),
                  Text(L.t.noFeedsHint,
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
                            ? L.t.lastFetch(formatListTime(f.lastFetch))
                            : L.t.notFetched),
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
                        icon: Icon(Icons.delete_outline, size: 20),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(L.t.deleteFeedQ(f.displayName)),
                              content: Text(L.t.deleteFeedHint),
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
        child: Icon(Icons.add),
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
            tooltip: _unreadOnly ? L.t.showAll : L.t.unreadOnly,
            icon: Icon(_unreadOnly ? Icons.mail : Icons.mark_email_unread),
            onPressed: () {
              setState(() => _unreadOnly = !_unreadOnly);
              _reload();
            },
          ),
          IconButton(
            tooltip: L.t.markAllRead,
            icon: Icon(Icons.done_all),
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
            tooltip: L.t.refresh,
            icon: Icon(Icons.refresh),
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
                _unreadOnly ? L.t.noUnread : L.t.noItems,
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
                      it.title.isEmpty ? L.t.untitled : it.title,
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
                        SizedBox(height: 2),
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
                              SizedBox(width: 6),
                              Icon(Icons.cloud_download,
                                  size: 14, color: theme.colorScheme.tertiary),
                            ],
                          ],
                        ),
                      ],
                    ),
                    trailing: it.hasDownload
                        ? IconButton(
                            tooltip: L.t.downloadToBt,
                            icon: Icon(Icons.download,
                                color: theme.colorScheme.primary),
                            onPressed: () {
                              try {
                                final r = _api.rssDownload(it.id);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(r['started'] == true
                                          ? L.t.queuedBt
                                          : L.t.addedQueue)),
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
        title: Text(L.t.article),
        actions: [
          if (it.link.isNotEmpty)
            IconButton(
              tooltip: L.t.openBrowser,
              icon: Icon(Icons.open_in_browser),
              onPressed: () async {
                final uri = Uri.tryParse(it.link);
                if (uri != null && await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
          if (it.hasDownload)
            IconButton(
              tooltip: L.t.downloadToBt,
              icon: Icon(Icons.download),
              onPressed: () {
                try {
                  _api.rssDownload(it.id);
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(L.t.queuedBt)));
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
          Text(it.title.isEmpty ? L.t.untitled : it.title,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          SizedBox(height: 8),
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
          SizedBox(height: 16),
          if (it.magnet.isNotEmpty)
            Card(
              color: theme.colorScheme.tertiaryContainer,
              child: ListTile(
                leading: Icon(Icons.cloud_download),
                title: Text(L.t.hasBtResource),
                subtitle: Text(it.magnet,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: FilledButton(
                  onPressed: () {
                    try {
                      _api.rssDownload(it.id);
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(L.t.addedQueue)));
                    } catch (e) {
                      showError(context, e);
                    }
                  },
                  child: Text(L.t.download),
                ),
              ),
            ),
          SizedBox(height: 8),
          SelectableText(
            (it.content ?? it.snippet).isEmpty
                ? L.t.noContent
                : (it.content ?? it.snippet),
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
          ),
          SizedBox(height: 32),
        ],
      ),
    );
  }
}
