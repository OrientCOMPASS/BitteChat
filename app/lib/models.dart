// Data models mirroring the Rust core's JSON schemas. Parsing is defensive:
// unknown/missing fields fall back to safe defaults so a core upgrade never
// hard-crashes the UI.

Map<String, dynamic> _asMap(dynamic v) =>
    v is Map<String, dynamic> ? v : <String, dynamic>{};

String _s(Map<String, dynamic> m, String k, [String d = '']) {
  final v = m[k];
  return v is String ? v : d;
}

int _i(Map<String, dynamic> m, String k, [int d = 0]) {
  final v = m[k];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return d;
}

double _d(Map<String, dynamic> m, String k, [double d = 0]) {
  final v = m[k];
  if (v is num) return v.toDouble();
  return d;
}

bool _b(Map<String, dynamic> m, String k, [bool d = false]) {
  final v = m[k];
  return v is bool ? v : d;
}

enum MsgPayloadKind { text, attachment, system, chunk, unknown }

class Attachment {
  Attachment({
    required this.infohash,
    required this.name,
    required this.size,
    this.mime = '',
  });

  final String infohash;
  final String name;
  final int size;
  final String mime;

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        infohash: _s(j, 'infohash'),
        name: _s(j, 'name'),
        size: _i(j, 'size'),
        mime: _s(j, 'mime'),
      );
}

class DownloadState {
  DownloadState({
    required this.progress,
    required this.finished,
    required this.paused,
    required this.rate,
    required this.peers,
    this.state = '',
  });

  final double progress;
  final bool finished;
  final bool paused;
  final int rate;
  final int peers;
  final String state;

  factory DownloadState.fromJson(Map<String, dynamic> j) => DownloadState(
        progress: _d(j, 'progress'),
        finished: _b(j, 'finished'),
        paused: _b(j, 'paused'),
        rate: _i(j, 'rate'),
        peers: _i(j, 'peers'),
        state: _s(j, 'state'),
      );
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.group,
    required this.authorPk,
    required this.authorName,
    required this.ts,
    required this.kind,
    required this.own,
    required this.state,
    this.text = '',
    this.attachment,
    this.systemCode = '',
    this.systemDetail = '',
    this.localPath,
    this.haveFile = false,
    this.dl,
  });

  final String id;
  final String group;
  final String authorPk;
  final String authorName;
  final int ts; // unix millis
  final int kind; // 1 text, 2 attachment, 3 system, 5 chunk
  final bool own;
  final int state; // 0 pending, 1 confirmed
  final String text;
  final Attachment? attachment;
  final String systemCode;
  final String systemDetail;
  final String? localPath;
  final bool haveFile;
  final DownloadState? dl;

  MsgPayloadKind get payloadKind {
    switch (kind) {
      case 1:
        return MsgPayloadKind.text;
      case 2:
        return MsgPayloadKind.attachment;
      case 3:
        return MsgPayloadKind.system;
      case 5:
        return MsgPayloadKind.chunk;
      default:
        return MsgPayloadKind.unknown;
    }
  }

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final payload = _asMap(j['payload']);
    // serde serializes the Rust Payload enum as a single-key map:
    //   {"Text": {"text": "..."}} or {"Attachment": {...}} etc.
    String text = '';
    Attachment? att;
    String sysCode = '';
    String sysDetail = '';
    if (payload.containsKey('Text')) {
      text = _s(_asMap(payload['Text']), 'text');
    } else if (payload.containsKey('Attachment')) {
      att = Attachment.fromJson(_asMap(payload['Attachment']));
    } else if (payload.containsKey('System')) {
      final s = _asMap(payload['System']);
      sysCode = _s(s, 'code');
      sysDetail = _s(s, 'detail');
    }
    return ChatMessage(
      id: _s(j, 'id'),
      group: _s(j, 'group'),
      authorPk: _s(j, 'author_pk'),
      authorName: _s(j, 'author_name'),
      ts: _i(j, 'ts'),
      kind: _i(j, 'kind'),
      own: _b(j, 'own'),
      state: _i(j, 'state'),
      text: text,
      attachment: att,
      systemCode: sysCode,
      systemDetail: sysDetail,
      localPath: j['local_path'] is String ? j['local_path'] as String : null,
      haveFile: _b(j, 'have_file'),
      dl: j['dl'] is Map<String, dynamic>
          ? DownloadState.fromJson(j['dl'] as Map<String, dynamic>)
          : null,
    );
  }
}

class GroupSummary {
  GroupSummary({
    required this.id,
    required this.name,
    required this.avatarB64,
    required this.inviteMagnet,
    required this.unread,
    required this.lastTs,
    required this.online,
    required this.syncing,
    required this.messages,
    required this.missing,
    this.dm = false,
    this.previewAuthor = '',
    this.previewText = '',
    this.previewTs = 0,
    this.previewOwn = false,
    this.previewKind = 0,
  });

  final String id;
  final String name;
  final String avatarB64;
  final String inviteMagnet;
  final int unread;
  final int lastTs;
  final int online;
  final bool syncing;
  final int messages;
  final int missing;
  final bool dm;
  final String previewAuthor;
  final String previewText;
  final int previewTs;
  final bool previewOwn;
  final int previewKind;

  factory GroupSummary.fromJson(Map<String, dynamic> j) {
    final pv = _asMap(j['preview']);
    return GroupSummary(
      id: _s(j, 'group_id'),
      name: _s(j, 'name'),
      avatarB64: _s(j, 'avatar_b64'),
      inviteMagnet: _s(j, 'invite_magnet'),
      unread: _i(j, 'unread'),
      lastTs: _i(j, 'last_ts'),
      online: _i(j, 'online'),
      syncing: _b(j, 'syncing'),
      messages: _i(j, 'messages'),
      missing: _i(j, 'missing'),
      previewAuthor: _s(pv, 'author_name'),
      previewText: _s(pv, 'text', ''),
      previewTs: _i(pv, 'ts'),
      previewOwn: _b(pv, 'own'),
      previewKind: _i(pv, 'kind'),
    );
  }
}

class TorrentInfo {
  TorrentInfo({
    required this.infohash,
    required this.name,
    required this.kind,
    required this.progress,
    required this.totalBytes,
    required this.downloadRate,
    required this.uploadRate,
    required this.numPeers,
    required this.numSeeds,
    required this.paused,
    required this.finished,
    required this.state,
    required this.error,
    required this.magnet,
    required this.savePath,
    this.groupName = '',
  });

  final String infohash;
  final String name;
  final int kind; // 0 normal, 1 group manifest, 2 chat attachment, 3 rss
  final double progress;
  final int totalBytes;
  final int downloadRate;
  final int uploadRate;
  final int numPeers;
  final int numSeeds;
  final bool paused;
  final bool finished;
  final String state;
  final String error;
  final String magnet;
  final String savePath;
  final String groupName;

  bool get isChatInternal => kind == 1;

  factory TorrentInfo.fromJson(Map<String, dynamic> j) => TorrentInfo(
        infohash: _s(j, 'infohash'),
        name: _s(j, 'name'),
        kind: _i(j, 'kind'),
        progress: _d(j, 'progress'),
        totalBytes: _i(j, 'total_bytes'),
        downloadRate: _i(j, 'download_rate'),
        uploadRate: _i(j, 'upload_rate'),
        numPeers: _i(j, 'num_peers'),
        numSeeds: _i(j, 'num_seeds'),
        paused: _b(j, 'paused'),
        finished: _b(j, 'finished'),
        state: _s(j, 'state'),
        error: _s(j, 'error'),
        magnet: _s(j, 'magnet'),
        savePath: _s(j, 'save_path'),
        groupName: _s(j, 'group_name'),
      );
}

class PeerInfo {
  PeerInfo({
    required this.ip,
    required this.port,
    required this.client,
    required this.progress,
    required this.chatCapable,
  });

  final String ip;
  final int port;
  final String client;
  final double progress;
  final bool chatCapable;

  factory PeerInfo.fromJson(Map<String, dynamic> j) => PeerInfo(
        ip: _s(j, 'ip'),
        port: _i(j, 'port'),
        client: _s(j, 'client'),
        progress: _d(j, 'progress'),
        chatCapable: _b(j, 'chat_capable'),
      );
}

class FeedInfo {
  FeedInfo({
    required this.id,
    required this.url,
    required this.title,
    required this.lastFetch,
    required this.error,
    required this.unread,
  });

  final int id;
  final String url;
  final String title;
  final int lastFetch;
  final String error;
  final int unread;

  String get displayName => title.isNotEmpty ? title : url;

  factory FeedInfo.fromJson(Map<String, dynamic> j) => FeedInfo(
        id: _i(j, 'id'),
        url: _s(j, 'url'),
        title: _s(j, 'title'),
        lastFetch: _i(j, 'last_fetch'),
        error: _s(j, 'error'),
        unread: _i(j, 'unread'),
      );
}

class RssItem {
  RssItem({
    required this.id,
    required this.feedId,
    required this.title,
    required this.link,
    required this.author,
    required this.ts,
    required this.read,
    required this.hasTorrent,
    required this.hasDownload,
    this.snippet = '',
    this.content,
    this.magnet = '',
    this.enclosureUrl = '',
    this.enclosureType = '',
  });

  final int id;
  final int feedId;
  final String title;
  final String link;
  final String author;
  final int ts;
  final bool read;
  final bool hasTorrent;
  final bool hasDownload;
  final String snippet;
  final String? content;
  final String magnet;
  final String enclosureUrl;
  final String enclosureType;

  factory RssItem.fromJson(Map<String, dynamic> j) => RssItem(
        id: _i(j, 'id'),
        feedId: _i(j, 'feed_id'),
        title: _s(j, 'title'),
        link: _s(j, 'link'),
        author: _s(j, 'author'),
        ts: _i(j, 'ts'),
        read: _b(j, 'read'),
        hasTorrent: _b(j, 'has_torrent'),
        hasDownload: _b(j, 'has_download'),
        snippet: _s(j, 'snippet'),
        content: j['content'] is String ? j['content'] as String : null,
        magnet: _s(j, 'magnet'),
        enclosureUrl: _s(j, 'enclosure_url'),
        enclosureType: _s(j, 'enclosure_type'),
      );
}

class SessionStats {
  SessionStats({
    required this.dhtNodes,
    required this.uploadRate,
    required this.downloadRate,
    required this.numTorrents,
  });

  final int dhtNodes;
  final int uploadRate;
  final int downloadRate;
  final int numTorrents;

  factory SessionStats.fromJson(Map<String, dynamic> j) => SessionStats(
        dhtNodes: _i(j, 'dht_nodes', -1),
        uploadRate: _i(j, 'upload_rate'),
        downloadRate: _i(j, 'download_rate'),
        numTorrents: _i(j, 'num_torrents'),
      );
}

class Identity {
  Identity({required this.name, required this.pk, this.avatarB64 = ''});

  final String name;
  final String pk;
  final String avatarB64;

  factory Identity.fromJson(Map<String, dynamic> j) => Identity(
        name: _s(j, 'name'),
        pk: _s(j, 'pk'),
        avatarB64: _s(j, 'avatar_b64'),
      );
}

/// Deterministic avatar color from a hex key (stable per author/group).
int colorFromKey(String key) {
  var h = 0;
  for (final c in key.codeUnits.take(16)) {
    h = (h * 31 + c) & 0x7FFFFFFF;
  }
  return h % 360; // hue
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}

String formatSpeed(int bytesPerSec) {
  if (bytesPerSec <= 0) return '0 B/s';
  return '${formatBytes(bytesPerSec)}/s';
}
