// Typed application-level wrapper around the FFI bridge, plus a broadcast
// stream of core events for the UI. When the native core is unavailable
// (host tests, desktop), everything degrades to empty demo data.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'bridge.dart';
import 'models.dart';

class CoreEvent {
  CoreEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;

  bool get isChatMessage => type == 'chat.message_new';
  bool get isChatGroupUpdated =>
      type == 'chat.group_updated' ||
      type == 'chat.group_joined' ||
      type == 'chat.group_restored';
  bool get isBtUpdated => type == 'bt.updated' || type == 'bt.added' || type == 'bt.removed';
  bool get isRssUpdated => type == 'rss.updated' || type == 'rss.error';
}

class BitteApi extends ChangeNotifier {
  BitteApi._(this.bridge, this.dataDir);

  final BitteBridge? bridge;
  final String dataDir;
  bool get available => bridge != null;

  StreamSubscription<String>? _sub;
  final _events = StreamController<CoreEvent>.broadcast();
  Stream<CoreEvent> get events => _events.stream;

  static BitteApi? _instance;
  static BitteApi get instance {
    final i = _instance;
    if (i == null) throw StateError('BitteApi not initialized');
    return i;
  }

  static bool get hasInstance => _instance != null;

  static Future<BitteApi> init({int listenPort = 17531}) async {
    if (_instance != null) return _instance!;
    String dir = './bitte-data';
    try {
      final d = await getExternalStorageDirectory() ??
          await getApplicationSupportDirectory();
      dir = d.path;
    } catch (_) {}
    final bridge = BitteBridge.tryOpen(dataDir: dir, listenPort: listenPort);
    final api = BitteApi._(bridge, dir);
    if (bridge != null) {
      api._sub = bridge.events.listen(api._onRawEvent);
    }
    _instance = api;
    return api;
  }

  void _onRawEvent(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is Map<String, dynamic>) {
        final type = j['type'];
        final data = j['data'];
        if (type is String) {
          _events.add(CoreEvent(type, data is Map<String, dynamic> ? data : {}));
        }
      }
    } catch (_) {}
  }

  Map<String, dynamic> call(String method, [Map<String, dynamic> params = const {}]) {
    final b = bridge;
    if (b == null) throw BridgeException('原生核心不可用（当前为演示模式）');
    return b.call(method, params);
  }

  // ---- sys -----------------------------------------------------------

  Identity? identity() {
    if (!available) return null;
    try {
      return Identity.fromJson(call('sys.identity.get'));
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> sysInfo() {
    try {
      return call('sys.info');
    } catch (_) {
      return {'version': '?', 'engine': 'none'};
    }
  }

  void setIdentity({String? name, String? avatarB64}) {
    call('sys.identity.set', {
      if (name != null) 'name': name,
      if (avatarB64 != null) 'avatar_b64': avatarB64,
    });
    notifyListeners();
  }

  void setActiveGroup(String? groupId) {
    if (!available) return;
    try {
      call('sys.set_active_group', {'group_id': groupId ?? ''});
    } catch (_) {}
  }

  // ---- chat ------------------------------------------------------------

  List<GroupSummary> chatGroups() {
    if (!available) return [];
    final r = call('chat.groups');
    return ((r['groups'] as List?) ?? [])
        .map((e) => GroupSummary.fromJson(_asMapSafe(e)))
        .toList();
  }

  List<ChatMessage> chatMessages(String groupId, {int limit = 300}) {
    if (!available) return [];
    final r = call('chat.messages', {'group_id': groupId, 'limit': limit});
    return ((r['messages'] as List?) ?? [])
        .map((e) => ChatMessage.fromJson(_asMapSafe(e)))
        .toList();
  }

  Map<String, dynamic> createGroup(String name) =>
      call('chat.create_group', {'name': name});

  Map<String, dynamic> joinGroup(String magnet) =>
      call('chat.join_group', {'magnet': magnet.trim()});

  void leaveGroup(String groupId, {bool deleteHistory = false}) =>
      call('chat.leave_group',
          {'group_id': groupId, 'delete_history': deleteHistory});

  List<String> sendText(String groupId, String text) {
    final r = call('chat.send', {'group_id': groupId, 'text': text});
    return ((r['ids'] as List?) ?? []).map((e) => '$e').toList();
  }

  Map<String, dynamic> sendFile(String groupId, String path, {String? name}) =>
      call('chat.send_file',
          {'group_id': groupId, 'path': path, if (name != null) 'name': name});

  void markRead(String groupId) =>
      call('chat.mark_read', {'group_id': groupId});

  void syncGroup(String groupId) {
    try {
      call('chat.sync', {'group_id': groupId});
    } catch (_) {}
  }

  Map<String, dynamic> groupDetail(String groupId) =>
      call('chat.group_detail', {'group_id': groupId});

  // ---- bt --------------------------------------------------------------

  List<TorrentInfo> torrents() {
    if (!available) return [];
    final r = call('bt.list');
    return ((r['torrents'] as List?) ?? [])
        .map((e) => TorrentInfo.fromJson(_asMapSafe(e)))
        .toList();
  }

  SessionStats btStats() {
    if (!available) {
      return SessionStats(
          dhtNodes: -1, uploadRate: 0, downloadRate: 0, numTorrents: 0);
    }
    try {
      return SessionStats.fromJson(call('bt.stats'));
    } catch (_) {
      return SessionStats(
          dhtNodes: -1, uploadRate: 0, downloadRate: 0, numTorrents: 0);
    }
  }

  Map<String, dynamic> btAdd(String magnet) =>
      call('bt.add', {'magnet': magnet.trim()});

  Map<String, dynamic> btAddFile(List<int> torrentBytes, {String name = ''}) =>
      call('bt.add_file', {
        'torrent_b64': base64Encode(torrentBytes),
        if (name.isNotEmpty) 'name': name,
      });

  void btControl(String infohash, String op,
          {bool deleteFiles = false, bool force = false}) =>
      call('bt.control', {
        'infohash': infohash,
        'op': op,
        'delete_files': deleteFiles,
        'force': force,
      });

  List<PeerInfo> btPeers(String infohash) {
    if (!available) return [];
    try {
      final r = call('bt.peers', {'infohash': infohash});
      return ((r['peers'] as List?) ?? [])
          .map((e) => PeerInfo.fromJson(_asMapSafe(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ---- rss -------------------------------------------------------------

  List<FeedInfo> feeds() {
    if (!available) return [];
    final r = call('rss.feeds');
    return ((r['feeds'] as List?) ?? [])
        .map((e) => FeedInfo.fromJson(_asMapSafe(e)))
        .toList();
  }

  Map<String, dynamic> rssAdd(String url) => call('rss.add', {'url': url.trim()});

  void rssRemove(int id) => call('rss.remove', {'id': id});

  void rssRefresh({int? id}) =>
      call('rss.refresh', {if (id != null) 'id': id});

  ({List<RssItem> items, int unread}) rssItems(int feedId,
      {int limit = 50, int offset = 0, bool unreadOnly = false}) {
    if (!available) return (items: [], unread: 0);
    final r = call('rss.items', {
      'feed_id': feedId,
      'limit': limit,
      'offset': offset,
      'unread_only': unreadOnly,
    });
    return (
      items: ((r['items'] as List?) ?? [])
          .map((e) => RssItem.fromJson(_asMapSafe(e)))
          .toList(),
      unread: (r['unread'] as int?) ?? 0,
    );
  }

  RssItem? rssItemDetail(int id) {
    if (!available) return null;
    final r = call('rss.item_detail', {'id': id});
    return RssItem.fromJson(r);
  }

  void rssMarkFeedRead(int feedId) =>
      call('rss.mark_feed_read', {'feed_id': feedId});

  Map<String, dynamic> rssDownload(int itemId) =>
      call('rss.download', {'id': itemId});

  @override
  void dispose() {
    _sub?.cancel();
    _events.close();
    super.dispose();
  }
}

Map<String, dynamic> _asMapSafe(dynamic e) =>
    e is Map<String, dynamic> ? e : <String, dynamic>{};
