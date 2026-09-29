// 群聊视图：消息流（哈希链 DAG 的线性化展示）+ 输入框 + 群详情/邀请

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/api.dart';
import '../core/prefs.dart';
import '../core/files.dart';
import '../models.dart';
import '../widgets/audio_row.dart';
import '../widgets/photo_view.dart';
import 'media_pages.dart';
import '../widgets/avatar.dart';
import '../widgets/time_fmt.dart';
import 'home.dart';
import '../core/l10n.dart';

class ChatViewPage extends StatefulWidget {
  const ChatViewPage({super.key, required this.group, this.prefs});

  final GroupSummary group;
  final UiPrefs? prefs;

  @override
  State<ChatViewPage> createState() => _ChatViewPageState();
}

class _ChatViewPageState extends State<ChatViewPage> {
  late final BitteApi _api = BitteApi.instance;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = [];
  List<_ChatEntry> _entries = [];
  final Set<String> _expandedGaps = {};
  bool _sending = false;
  String? _attJob;
  String _attPhase = '';
  StreamSubscription<CoreEvent>? _sub;
  Map<String, dynamic> _detail = {};
  Timer? _detailTimer;
  bool _showJump = false;

  String get _gid => widget.group.id;
  bool get _isDm => widget.group.dm;
  bool get _dmOnline => (_detail['dm_online'] as bool?) ?? false;

  @override
  void initState() {
    super.initState();
    _api.setActiveGroup(_gid);
    _reload(markRead: true);
    _api.syncGroup(_gid);
    _sub = _api.events.listen((e) {
      if (e.isChatMessage && e.data['group'] == _gid) {
        _reload();
      } else if (e.isChatGroupUpdated) {
        _reload();
      } else if (e.type == 'chat.sync' && e.data['group'] == _gid) {
        if (mounted) setState(() {});
      } else if (e.type == 'chat.message_state' && e.data['group'] == _gid) {
        _reload();
      } else if (e.type == 'chat.attachment_progress' &&
          e.data['job_id'] == _attJob) {
        _onAttProgress('${e.data['phase'] ?? ''}', '${e.data['error'] ?? ''}');
      }
    });
    _detailTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _loadDetail(silent: true);
      if (_hasActiveDownload) _reload();
    });
    _loadDetail(silent: true);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _api.setActiveGroup(null);
    _sub?.cancel();
    _detailTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reload({bool markRead = false}) {
    if (!mounted) return;
    try {
      final msgs = _api.chatMessages(_gid, limit: 500);
      final stick = markRead || _nearBottom();
      setState(() {
        _messages = msgs;
        _entries = _buildEntries(msgs);
      });
      if (markRead) _api.markRead(_gid);
      if (stick) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (_) {}
  }

  void _loadDetail({bool silent = false}) {
    try {
      _detail = _api.groupDetail(_gid);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _onAttProgress(String phase, String error) {
    if (!mounted) return;
    if (phase == 'sent') {
      setState(() {
        _attJob = null;
        _attPhase = '';
      });
      _reload();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L.t.sentSeeding(''))));
    } else if (phase == 'error') {
      setState(() {
        _attJob = null;
        _attPhase = '';
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${L.t.attachFailed}: $error')));
    } else {
      setState(() => _attPhase = phase);
    }
  }

  void _onScroll() {
    final show =
        _scroll.position.maxScrollExtent - _scroll.position.pixels > 240;
    if (show != _showJump && mounted) setState(() => _showJump = show);
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  bool _nearBottom() =>
      !_scroll.hasClients ||
      _scroll.position.maxScrollExtent - _scroll.position.pixels < 160;

  /// Open a DM with the author of [m] (used by the message action popup).
  Future<void> _startDmFromMessage(ChatMessage m) async {
    try {
      final r = _api.startDm(m.authorPk);
      final dgid = r['group_id'] as String;
      if (!mounted) return;
      final groups = _api.chatGroups();
      final summary = groups.firstWhere(
        (g) => g.id == dgid,
        orElse: () => GroupSummary(
          id: dgid,
          name: m.authorName,
          avatarB64: '',
          inviteMagnet: '',
          unread: 0,
          lastTs: 0,
          online: 0,
          syncing: false,
          messages: 0,
          missing: 0,
          dm: true,
        ),
      );
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatViewPage(group: summary, prefs: widget.prefs)));
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// QQ-style floating action popup anchored at the selection, shown by the
  /// message [SelectionArea] on long-press alongside the selection handles
  /// (replaces the old pull-up bottom sheet).
  Widget _messageContextMenu(
      BuildContext ctx, SelectableRegionState state, ChatMessage m) {
    final theme = Theme.of(ctx);
    final anchor = state.contextMenuAnchors.primaryAnchor;
    final screen = MediaQuery.sizeOf(ctx);
    const menuW = 300.0;
    final maxLeft = (screen.width - menuW - 8).clamp(8.0, screen.width);
    final left = (anchor.dx - menuW / 2).clamp(8.0, maxLeft);
    final top = (anchor.dy + 8).clamp(8.0, screen.height - 140);
    void run(VoidCallback fn) {
      state.hideToolbar();
      fn();
    }

    Widget act(IconData icon, String label, VoidCallback fn) {
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => run(fn),
        child: SizedBox(
          width: 68,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.onSurface),
              const SizedBox(height: 4),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: SizedBox(
                width: menuW,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  runSpacing: 8,
                  children: [
                    if (m.payloadKind == MsgPayloadKind.text)
                      act(Icons.copy, L.t.copyMessage, () {
                        Clipboard.setData(ClipboardData(text: m.text));
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(L.t.copied)));
                      }),
                    act(Icons.fingerprint, L.t.copyMessageId, () {
                      Clipboard.setData(ClipboardData(text: m.id));
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(L.t.copiedId)));
                    }),
                    if (!m.own && !_isDm)
                      act(Icons.lock_person_outlined, L.t.startDm,
                          () => _startDmFromMessage(m)),
                    if (!m.own)
                      act(Icons.block, L.t.blockAuthor, () {
                        try {
                          _api.blockAuthor(m.authorPk);
                          _reload();
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(L.t.blockedAuthor(m.authorName))));
                        } catch (e) {
                          showError(context, e);
                        }
                      }),
                    act(Icons.verified_user, L.t.signatureInfo, () {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(L.t.sigDetail(
                              shortHash(m.authorPk, 16),
                              m.state == 1
                                  ? L.t.sigConfirmed
                                  : L.t.sigPending))));
                    }),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      _api.sendText(_gid, text);
      _input.clear();
      _reload();
    } catch (e) {
      showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSendFile() async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: L.t.pickFileToSend,
        type: FileType.any,
      );
      if (files.isEmpty) return;
      final path = files.single.path;
      final name = files.single.name;
      if (path == null) return;
      if (!mounted) return;
      // v0.5.2: the core hashes+copies on a worker thread (big videos must
      // not block the UI); we track the job via attachment_progress events
      final r = _api.sendFile(_gid, path, name: name);
      final job = '${r['job_id'] ?? ''}';
      if (job.isNotEmpty) {
        setState(() {
          _attJob = job;
          _attPhase = 'hash';
        });
      } else {
        _reload();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _downloadAttachment(ChatMessage m) async {
    final att = m.attachment;
    if (att == null) return;
    try {
      _api.downloadAttachment(_gid, m.id);
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L.t.downloadStarted(att.name))),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  List<_ChatEntry> _buildEntries(List<ChatMessage> msgs) {
    final out = <_ChatEntry>[];
    for (final m in msgs) {
      if (m.blocked) {
        if (out.isNotEmpty && out.last.isGap) {
          out.last.blocked.add(m);
        } else {
          out.add(_ChatEntry.gap([m]));
        }
      } else {
        out.add(_ChatEntry.msg(m));
      }
    }
    return out;
  }

  bool get _hasActiveDownload => _messages.any((m) =>
      m.payloadKind == MsgPayloadKind.attachment &&
      m.dl != null &&
      !m.dl!.finished &&
      !m.haveFile);

  Future<void> _openGroupSheet() async {
    _loadDetail();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => GroupDetailSheet(
        groupId: _gid,
        detail: _detail,
        onChanged: () => setState(() {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = (_detail['missing'] as int?) ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isDm) ...[
                  Icon(Icons.lock, size: 16, color: theme.colorScheme.primary),
                  SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(widget.group.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            if (missing > 0)
              Text(
                L.t.syncingMissing(missing),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              )
            else if (_isDm)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle,
                      size: 8,
                      color: _dmOnline
                          ? Colors.green
                          : theme.colorScheme.outlineVariant),
                  const SizedBox(width: 5),
                  Text(
                    _dmOnline ? L.t.dmOnline : L.t.dmOffline,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ],
              )
            else
              Text(
                L.t.historySynced(_detail['peers'] is List
                    ? (_detail['peers'] as List).length
                    : 0),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: L.t.resync,
            icon: Icon(Icons.sync),
            onPressed: () {
              _api.syncGroup(_gid);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(L.t.resyncStarted)),
              );
            },
          ),
          IconButton(
            tooltip: L.t.groupDetail,
            icon: Icon(Icons.info_outline),
            onPressed: _openGroupSheet,
          ),
        ],
      ),
      body: Stack(
        children: [
          // the app-wide wallpaper is rendered globally (see main.dart),
          // transparent scaffolds let it show through everywhere
          Column(
            children: [
              Expanded(
                child: _messages.isEmpty
                    ? Center(
                        child: Text(
                          L.t.emptyGroupHint,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                      )
                    : GestureDetector(
                        onTap: () => FocusScope.of(context).unfocus(),
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          itemCount: _entries.length + 1,
                          itemBuilder: (context, i) {
                            if (i == 0) {
                              return _GenesisHeader(
                                  groupName: widget.group.name);
                            }
                            final entry = _entries[i - 1];
                            if (entry.isGap) {
                              return _BlockedGap(
                                messages: entry.blocked,
                                expanded: _expandedGaps
                                    .contains(entry.blocked.first.id),
                                onToggle: () {
                                  setState(() {
                                    final key = entry.blocked.first.id;
                                    if (!_expandedGaps.remove(key)) {
                                      _expandedGaps.add(key);
                                    }
                                  });
                                },
                              );
                            }
                            final m = entry.message!;
                            final prev =
                                i == 1 ? null : _entries[i - 2].lastMessage;
                            final showAuthor = prev == null ||
                                prev.own != m.own ||
                                m.ts - prev.ts > 5 * 60 * 1000 ||
                                _isNewDay(prev.ts, m.ts);
                            final showDay =
                                prev == null || _isNewDay(prev.ts, m.ts);
                            return Column(
                              children: [
                                if (showDay) DayDivider(ts: m.ts),
                                // QQ-style: long-press gives BOTH text
                                // selection cursors (SelectionArea) and an
                                // anchored floating action popup (custom
                                // context menu) — not a bottom sheet.
                                SelectionArea(
                                  contextMenuBuilder: (ctx, state) =>
                                      _messageContextMenu(ctx, state, m),
                                  child: MessageBubble(
                                    message: m,
                                    showAuthor: showAuthor,
                                    onDownload: () => _downloadAttachment(m),
                                    prefs: widget.prefs,
                                  ),
                                ),
                              ],
                            );
                          },
                        )),
              ),
              if (_attJob != null)
                Material(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            switch (_attPhase) {
                              'copy' => L.t.attPhaseCopy,
                              'seed' => L.t.attPhaseSeed,
                              _ => L.t.attPhaseHash,
                            },
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              _InputBar(
                controller: _input,
                sending: _sending,
                onSend: _send,
                onAttach: _pickAndSendFile,
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: _showJump
          ? FloatingActionButton.small(
              heroTag: 'jump-bottom',
              onPressed: _scrollToBottom,
              child: Icon(Icons.keyboard_double_arrow_down),
            )
          : null,
    );
  }
}

String shortHash(String h, [int n = 12]) =>
    h.length > n ? '${h.substring(0, n)}…' : h;

bool _isNewDay(int a, int b) =>
    DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(a)) !=
    DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(b));

class _GenesisHeader extends StatelessWidget {
  const _GenesisHeader({required this.groupName});
  final String groupName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(Icons.link, color: theme.colorScheme.outlineVariant, size: 32),
          SizedBox(height: 8),
          Text(
            L.t.genesisTitle(groupName),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          Text(
            L.t.genesisSub,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outlineVariant),
          ),
        ],
      ),
    );
  }
}

class DayDivider extends StatelessWidget {
  const DayDivider({super.key, required this.ts});
  final int ts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            formatDayLabel(ts),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.showAuthor,
    this.onDownload,
    this.blockedMark = false,
    this.prefs,
  });

  final ChatMessage message;
  final bool showAuthor;
  final VoidCallback? onDownload;
  final bool blockedMark;
  final UiPrefs? prefs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = message;

    if (m.payloadKind == MsgPayloadKind.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: Text(
            (blockedMark ? '🛡 ' : '') + _systemText(m),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      );
    }

    final own = m.own;
    final bubbleColor = own
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHigh;
    final align = own ? Alignment.centerRight : Alignment.centerLeft;

    return Align(
      alignment: align,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          child: Column(
            crossAxisAlignment:
                own ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (showAuthor && !own)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 2),
                  child: Text(
                    m.authorName.isEmpty ? L.t.anonymous : m.authorName,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: HSLColor.fromAHSL(
                              1, colorFromKey(m.authorPk).toDouble(), 0.5, 0.4)
                          .toColor(),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Row(
                mainAxisAlignment:
                    own ? MainAxisAlignment.end : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!own) ...[
                    KeyAvatar(keyHex: m.authorPk, name: m.authorName, size: 30),
                    SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: bubbleColor,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(14),
                          topRight: const Radius.circular(14),
                          bottomLeft: Radius.circular(own ? 14 : 4),
                          bottomRight: Radius.circular(own ? 4 : 14),
                        ),
                      ),
                      child: m.payloadKind == MsgPayloadKind.attachment
                          ? _AttachmentBody(
                              message: m, onDownload: onDownload, prefs: prefs)
                          : _TextBody(message: m),
                    ),
                  ),
                  if (own) ...[
                    SizedBox(width: 6),
                    KeyAvatar(keyHex: m.authorPk, name: m.authorName, size: 30),
                  ],
                ],
              ),
              Padding(
                padding: EdgeInsets.only(
                    left: own ? 0 : 40, right: own ? 40 : 0, top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatClock(m.ts),
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline, fontSize: 10),
                    ),
                    if (own) ...[
                      SizedBox(width: 4),
                      Icon(
                        m.state == 1 ? Icons.done_all : Icons.schedule,
                        size: 12,
                        color: m.state == 1
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _systemText(ChatMessage m) {
    switch (m.systemCode) {
      case 'create':
        return L.t.sysCreate(m.authorName, m.systemDetail);
      case 'join':
        return L.t.sysJoin(m.authorName);
      case 'leave':
        return L.t.sysLeave(m.authorName);
      case 'rename':
        return L.t.sysRename(m.authorName, m.systemDetail);
      default:
        return L.t.sysGeneric(m.systemCode, m.systemDetail);
    }
  }
}

class _TextBody extends StatelessWidget {
  const _TextBody({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      message.text,
      style: const TextStyle(fontSize: 15, height: 1.35),
    );
  }
}

class _AttachmentBody extends StatelessWidget {
  const _AttachmentBody({required this.message, this.onDownload, this.prefs});
  final ChatMessage message;
  final VoidCallback? onDownload;
  final UiPrefs? prefs;

  bool get _have => message.haveFile && message.localPath != null;

  /// Full-screen viewer: the picture is contain-fitted to the screen (one
  /// side touches the edge, nothing is cropped) — the old dialog handed the
  /// image loose constraints, so it laid out at its intrinsic pixel size and
  /// got clipped by the screen.
  void _openImage(BuildContext context, String path) {
    final att = message.attachment;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PhotoViewerPage(
        path: path,
        title: att?.name,
        subtitle: att == null ? null : formatBytes(att.size),
      ),
    ));
  }

  Future<void> _openMedia(BuildContext context) async {
    final att = message.attachment!;
    final path = message.localPath!;
    final kind = mediaKindOf(att.name, att.mime);
    switch (kind) {
      case MediaKind.image:
        _openImage(context, path);
      case MediaKind.video:
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                VideoPlayerPage(path: path, title: att.name, prefs: prefs)));
      case MediaKind.text:
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TextPreviewPage(path: path, title: att.name)));
      case MediaKind.audio:
      case MediaKind.other:
        final ok = await openWithExternalApp(path, mimeFromName(att.name));
        if (!ok && context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(L.t.noAppForFile)));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final att = message.attachment!;
    final kind = mediaKindOf(att.name, att.mime);
    final dl = message.dl;

    // downloading: live progress
    if (!_have && dl != null && !dl.finished) {
      return SizedBox(
        width: 220,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, value: dl.progress),
                ),
                SizedBox(width: 8),
                Flexible(
                  child: Text(att.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: dl.progress, minHeight: 5),
            ),
            SizedBox(height: 2),
            Text(
              L.t.dlProgress((dl.progress * 100).toStringAsFixed(0),
                      formatSpeed(dl.rate), dl.peers) +
                  (dl.paused ? L.t.pausedMark : ''),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      );
    }

    // not downloaded yet
    if (!_have) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_fileIcon(att.name),
                  size: 28, color: theme.colorScheme.primary),
              SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(att.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('${formatBytes(att.size)} · ${_kindLabel(kind)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 6),
          TextButton.icon(
            onPressed: onDownload,
            icon: Icon(Icons.download, size: 18),
            label: Text(L.t.downloadViaBt),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      );
    }

    // have the file: media-aware presentation
    final path = message.localPath!;
    Widget media;
    switch (kind) {
      case MediaKind.image:
        media = GestureDetector(
          onTap: () => _openImage(context, path),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(path),
              height: 150,
              width: 210,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        );
      case MediaKind.audio:
        media = AudioRow(path: path, title: att.name);
      case MediaKind.video:
        media = GestureDetector(
          onTap: () => _openMedia(context),
          child: Container(
            width: 210,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Icon(Icons.smart_display,
                    size: 40, color: theme.colorScheme.primary),
                SizedBox(height: 4),
                Text(L.t.tapPlayVideo),
              ],
            ),
          ),
        );
      case MediaKind.text:
      case MediaKind.other:
        media = Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _openMedia(context),
            icon: Icon(
                kind == MediaKind.text
                    ? Icons.article_outlined
                    : Icons.open_in_new,
                size: 18),
            label:
                Text(kind == MediaKind.text ? L.t.previewText : L.t.openWith),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        media,
        SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_fileIcon(att.name),
                size: 16, color: theme.colorScheme.outline),
            SizedBox(width: 4),
            Flexible(
              child: Text(
                '${att.name} · ${formatBytes(att.size)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _kindLabel(MediaKind k) {
    switch (k) {
      case MediaKind.image:
        return L.t.kindImage;
      case MediaKind.audio:
        return L.t.kindAudio;
      case MediaKind.video:
        return L.t.kindVideo;
      case MediaKind.text:
        return L.t.kindText;
      case MediaKind.other:
        return L.t.kindFile;
    }
  }

  IconData _fileIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif')) {
      return Icons.image_outlined;
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.avi')) {
      return Icons.movie_outlined;
    }
    if (lower.endsWith('.mp3') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.ogg')) {
      return Icons.audiotrack_outlined;
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.gz') ||
        lower.endsWith('.7z')) {
      return Icons.folder_zip_outlined;
    }
    if (lower.endsWith('.apk')) return Icons.android_outlined;
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttach,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: L.t.sendFileTip,
              icon: Icon(Icons.attach_file),
              onPressed: sending ? null : onAttach,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: L.t.inputHint,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(22))),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  isDense: true,
                ),
              ),
            ),
            SizedBox(width: 6),
            SizedBox(
              width: 44,
              height: 44,
              child: FilledButton(
                onPressed: sending ? null : onSend,
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                ),
                child: sending
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.send, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 群详情底部弹层：邀请二维码/磁力链、成员、链状态、退群
class GroupDetailSheet extends StatefulWidget {
  const GroupDetailSheet({
    super.key,
    required this.groupId,
    required this.detail,
    this.onChanged,
  });

  final String groupId;
  final Map<String, dynamic> detail;
  final VoidCallback? onChanged;

  @override
  State<GroupDetailSheet> createState() => _GroupDetailSheetState();
}

class _GroupDetailSheetState extends State<GroupDetailSheet> {
  late final BitteApi _api = BitteApi.instance;
  late Map<String, dynamic> _detail = Map<String, dynamic>.from(widget.detail);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  void _refresh() {
    try {
      final d = _api.groupDetail(widget.groupId);
      if (!mounted) return;
      setState(() => _detail = d);
      widget.onChanged?.call();
    } catch (_) {}
  }

  Future<void> _startDmWith(String pk) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = _api.startDm(pk);
      Navigator.pop(context);
      if (r['existing'] == true) {
        messenger.showSnackBar(SnackBar(content: Text(L.t.dmAlreadyExists)));
      } else if (r['sent'] == true) {
        messenger.showSnackBar(SnackBar(content: Text(L.t.dmRequestSent)));
      } else {
        messenger.showSnackBar(SnackBar(content: Text(L.t.dmRequestQueued)));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _detail;
    final group = _asMap(d['group']);
    final magnet = (group['invite_magnet'] as String?) ?? '';
    final peers = (d['peers'] as List?) ?? [];
    final members = (d['members'] as List?) ?? [];
    final heads = (d['heads'] as List?) ?? [];
    final creator = _asMap(d['creator']);
    final kind = (d['kind'] as String?) ?? 'torrent';
    final isDm = kind == 'dm';
    final creatorName = (creator['name'] as String?) ?? '';
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.92,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          Row(
            children: [
              GroupAvatar(
                  name: (group['name'] as String?) ?? '?',
                  keyHex: widget.groupId,
                  size: 44),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((group['name'] as String?) ?? L.t.groupChat,
                        style: theme.textTheme.titleMedium),
                    Text(
                      creatorName.isNotEmpty
                          ? L.t.createdBy(
                              formatFull((group['created'] as int?) ?? 0),
                              creatorName)
                          : (isDm ? L.t.dmChannelKind : L.t.torrentRoomKind),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
              IconButton(
                  tooltip: L.t.refresh,
                  icon: Icon(Icons.refresh),
                  onPressed: _refresh),
            ],
          ),
          SizedBox(height: 16),
          _StatRow(label: L.t.msgCount, value: '${d['messages'] ?? 0}'),
          _StatRow(label: L.t.headsCount, value: '${heads.length}'),
          _StatRow(label: L.t.missingCount, value: '${d['missing'] ?? 0}'),
          _StatRow(label: L.t.headSeq, value: '${d['head_seq'] ?? 0}'),
          _StatRow(
              label: L.t.members,
              value: '${members.isNotEmpty ? members.length : peers.length}'),
          if (!isDm)
            _StatRow(
                label: L.t.infohashLabel,
                value: shortHash('${d['infohash'] ?? ''}', 16)),
          SizedBox(height: 16),
          if (isDm) ...[
            // v0.5.2 DM: purely local channel — no invite link/QR (the channel
            // was established by a signed request, not a shared secret)
            Row(
              children: [
                Icon(
                  (d['dm_online'] == true)
                      ? Icons.circle
                      : Icons.circle_outlined,
                  size: 10,
                  color: (d['dm_online'] == true)
                      ? Colors.green
                      : theme.colorScheme.outlineVariant,
                ),
                SizedBox(width: 6),
                Text(
                  (d['dm_online'] == true) ? L.t.dmOnline : L.t.dmOffline,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            SizedBox(height: 4),
            Text(L.t.dmLocalOnlyHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ] else ...[
            Text(L.t.roomInviteTitle, style: theme.textTheme.titleSmall),
            SizedBox(height: 4),
            Text(L.t.roomInviteHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            SizedBox(height: 8),
            if (magnet.isNotEmpty)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  color: Colors.white,
                  child: QrImageView(
                    data: magnet,
                    size: 180,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
            SizedBox(height: 8),
            OutlinedButton.icon(
              icon: Icon(Icons.copy, size: 18),
              label: Text(L.t.copyInviteLink),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: magnet));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(L.t.copiedInvite)),
                  );
                }
              },
            ),
          ],
          SizedBox(height: 12),
          if (!isDm && members.isNotEmpty) ...[
            Text(L.t.membersIdentified, style: theme.textTheme.titleSmall),
            SizedBox(height: 4),
            ...members.map((m) {
              final mm = _asMap(m);
              final pk = '${mm['pk'] ?? ''}';
              final name = '${mm['name'] ?? ''}';
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: KeyAvatar(keyHex: pk, name: name, size: 32),
                title: Text(name.isNotEmpty ? name : shortHash(pk, 12),
                    style: theme.textTheme.bodyMedium),
                subtitle: Text(shortHash(pk, 16),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                trailing: TextButton.icon(
                  icon: Icon(Icons.lock_person_outlined, size: 16),
                  label: Text(L.t.startDm),
                  onPressed: () => _startDmWith(pk),
                ),
              );
            }),
            SizedBox(height: 12),
          ],
          if (peers.isNotEmpty) ...[
            Text(L.t.p2pPeers, style: theme.textTheme.titleSmall),
            SizedBox(height: 4),
            ...peers.map((p) {
              final pm = _asMap(p);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  (pm['chat_capable'] == true)
                      ? Icons.chat
                      : Icons.cloud_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                title: Text('${pm['ip']}:${pm['port']}',
                    style: theme.textTheme.bodySmall),
                subtitle: Text(
                  '${pm['client'] ?? ''} · ${(pm['chat_capable'] == true) ? L.t.chatCapable : L.t.plainBtClient}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              );
            }),
          ],
          SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text(L.t.renameGroup),
            subtitle: Text(L.t.renameLocalNote),
            onTap: () async {
              final controller =
                  TextEditingController(text: (group['name'] as String?) ?? '');
              final name = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(L.t.renameGroup),
                  content: TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 32,
                    decoration: InputDecoration(border: OutlineInputBorder()),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(L.t.cancel)),
                    FilledButton(
                        onPressed: () =>
                            Navigator.pop(ctx, controller.text.trim()),
                        child: Text(L.t.save)),
                  ],
                ),
              );
              if (name == null || name.isEmpty) return;
              try {
                _api.renameGroup(widget.groupId, name);
                _refresh();
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            icon: Icon(Icons.logout),
            label: Text(L.t.leaveGroup),
            onPressed: () async {
              // Leaving deletes the LOCAL chain by default: the usual reason
              // to leave is "I ended up in the wrong hash chain", and keeping
              // a stale local DAG would just re-merge the wrong history on
              // re-entry. The box can be unticked to keep it.
              final res = await showDialog<_LeaveChoice>(
                context: context,
                builder: (ctx) => _LeaveDialog(isDm: isDm),
              );
              if (res == null || !context.mounted) return;
              try {
                _api.leaveGroup(widget.groupId,
                    deleteHistory: res.deleteHistory);
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          SizedBox(height: 24),
        ],
      ),
    );
  }

  Map<String, dynamic> _asMap(dynamic v) =>
      v is Map<String, dynamic> ? v : <String, dynamic>{};
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _ChatEntry {
  _ChatEntry.msg(this.message) : blocked = [];
  _ChatEntry.gap(this.blocked) : message = null;

  final ChatMessage? message;
  final List<ChatMessage> blocked;

  bool get isGap => message == null;
  ChatMessage? get lastMessage => isGap ? blocked.last : message;
}

class _BlockedGap extends StatelessWidget {
  const _BlockedGap({
    required this.messages,
    required this.expanded,
    required this.onToggle,
  });

  final List<ChatMessage> messages;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ActionChip(
            avatar: Icon(Icons.shield_outlined, size: 16),
            label: Text(L.t.blockedCount(messages.length)),
            onPressed: onToggle,
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        if (expanded)
          for (final m in messages)
            Opacity(
              opacity: 0.55,
              child: MessageBubble(
                message: m,
                showAuthor: true,
                blockedMark: true,
              ),
            ),
      ],
    );
  }
}

/// What the leave confirmation returns: leave, and whether to purge the
/// local messages + DAG heads.
class _LeaveChoice {
  const _LeaveChoice(this.deleteHistory);

  final bool deleteHistory;
}

class _LeaveDialog extends StatefulWidget {
  const _LeaveDialog({required this.isDm});

  /// DM channels have no torrent to keep, so they get their own hint text.
  final bool isDm;

  @override
  State<_LeaveDialog> createState() => _LeaveDialogState();
}

class _LeaveDialogState extends State<_LeaveDialog> {
  bool _deleteHistory = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(L.t.leaveGroupQ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.isDm ? L.t.leaveGroupHint : L.t.leaveRoomHint),
          const SizedBox(height: 4),
          CheckboxListTile(
            value: _deleteHistory,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(L.t.deleteLocalHistory),
            onChanged: (v) => setState(() => _deleteHistory = v ?? true),
          ),
          Text(
            L.t.deleteLocalHistoryHint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(L.t.cancel)),
        TextButton(
            onPressed: () =>
                Navigator.pop(context, _LeaveChoice(_deleteHistory)),
            child: Text(L.t.leave)),
      ],
    );
  }
}
