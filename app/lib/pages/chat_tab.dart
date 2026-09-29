// 聊天页：种子群聊列表 —— 一个种子就是一个群，添加种子即进入它的聊天室

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/bridge.dart';
import '../core/intent.dart';
import '../core/prefs.dart';
import '../models.dart';
import '../widgets/avatar.dart';
import '../widgets/time_fmt.dart';
import 'chat_view.dart';
import 'home.dart';
import '../core/l10n.dart';

class ChatTab extends StatefulWidget {
  const ChatTab({super.key, this.onOpenSettings, required this.prefs});

  final VoidCallback? onOpenSettings;
  final UiPrefs prefs;

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  late final BitteApi _api = BitteApi.instance;
  List<GroupSummary> _groups = [];
  StreamSubscription<CoreEvent>? _sub;
  Timer? _refreshTimer;
  VoidCallback? _magnetListener;

  @override
  void initState() {
    super.initState();
    _reload();
    _sub = _api.events.listen((e) {
      if (e.isChatGroupUpdated ||
          e.isChatMessage ||
          e.type == 'chat.dm_request' ||
          e.type == 'chat.dm_established' ||
          e.type == 'chat.dm_rejected') {
        _reload();
      }
      if (e.type == 'chat.dm_rejected' && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t.dmRejectedByPeer)));
      }
    });
    // light polling keeps previews fresh even without events
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _reload());
    _magnetListener = () {
      final m = pendingMagnet.value;
      if (m == null || m.isEmpty) return;
      pendingMagnet.value = null;
      _enterRoomDirect(m);
    };
    pendingMagnet.addListener(_magnetListener!);
  }

  @override
  void dispose() {
    if (_magnetListener != null) {
      pendingMagnet.removeListener(_magnetListener!);
    }
    _sub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    try {
      final g = _api.chatGroups();
      if (mounted) setState(() => _groups = g);
    } catch (_) {}
  }

  /// Pending DM request as a conversation-list row with INLINE
  /// accept / decline / block — no modal dialog, no forced immediate
  /// decision (requests persist across restarts until handled).
  Widget _requestTile(GroupSummary g) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.35),
      child: ListTile(
        leading: Badge(
          isLabelVisible: false,
          child: CircleAvatar(
            backgroundColor: theme.colorScheme.secondaryContainer,
            child: Icon(Icons.lock_person_outlined,
                color: theme.colorScheme.onSecondaryContainer),
          ),
        ),
        title: Text(
          g.name.isNotEmpty ? g.name : shortPkLabel(g.peerPk),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(L.t.dmRequestSubtitle,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.secondary)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filledTonal(
              tooltip: L.t.accept,
              icon: const Icon(Icons.check, size: 20),
              onPressed: () async {
                try {
                  _api.dmRespond(g.id, accept: true);
                } catch (_) {}
                _reload();
                await _openRoomById(g.id);
              },
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: L.t.decline,
              icon: const Icon(Icons.close, size: 20),
              onPressed: () {
                try {
                  _api.dmRespond(g.id, accept: false);
                } catch (_) {}
                _reload();
              },
            ),
            IconButton(
              tooltip: L.t.block,
              icon: const Icon(Icons.block, size: 20),
              onPressed: () {
                try {
                  _api.dmBlock(g.peerPk);
                } catch (_) {}
                _reload();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openGroup(GroupSummary g) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ChatViewPage(group: g, prefs: widget.prefs)),
    );
    _reload();
  }

  Future<GroupSummary?> _summaryFor(String gid) async {
    try {
      final groups = _api.chatGroups();
      for (final g in groups) {
        if (g.id == gid) return g;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _openRoomById(String gid) async {
    final summary = await _summaryFor(gid) ??
        GroupSummary(
          id: gid,
          name: '${L.t.groupChat} ${gid.substring(0, 8)}',
          avatarB64: '',
          inviteMagnet: 'magnet:?xt=urn:btih:$gid',
          unread: 0,
          lastTs: 0,
          online: 0,
          syncing: false,
          messages: 0,
          missing: 0,
        );
    if (!mounted) return;
    await _openGroup(summary);
  }

  /// Prompt for a magnet link / bare infohash, add the torrent and enter
  /// its chat room right away.
  Future<void> _enterRoom() async {
    final input = await _promptText(
      context,
      title: L.t.enterRoomTitle,
      label: L.t.roomInputLabel,
      hint: L.t.magnetHashHint,
      confirm: L.t.enterRoom,
      multiline: true,
      pasteButton: true,
    );
    if (input == null || input.trim().isEmpty) return;
    await _enterRoomDirect(input.trim());
  }

  Future<void> _enterRoomDirect(String input) async {
    try {
      final r = _api.joinGroup(input);
      final gid = r['group_id'] as String? ?? '';
      _reload();
      if (gid.isEmpty) return;
      if (r['dm'] == true) {
        // pasted a DM channel invite — open the DM
        await _openRoomById(gid);
        return;
      }
      final already = r['already'] == true;
      if (mounted && !already) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L.t.roomEntered('${r['name'] ?? ''}'))),
        );
      }
      await _openRoomById(gid);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Import a .torrent file: it becomes a BT task and we enter its room.
  Future<void> _importTorrentRoom() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['torrent'],
      );
      if (files.isEmpty) return;
      final file = files.single;
      final bytes = await file.xFile.readAsBytes();
      if (!mounted) return;
      try {
        final added = _api.btAddFile(bytes, name: file.name);
        final ih = added['infohash'] as String? ?? '';
        if (ih.isEmpty) return;
        await _enterRoomDirect(ih);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t.chatTab),
        actions: [
          IconButton(
            tooltip: L.t.identitySettings,
            icon: Icon(Icons.person_outline),
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: !_api.available
          ? _DemoModeHint(error: BitteBridge.lastOpenError)
          : _groups.isEmpty
              ? _EmptyState(
                  icon: Icons.forum_outlined,
                  title: L.t.noGroups,
                  subtitle: L.t.noGroupsHint,
                  actions: [
                    FilledButton.icon(
                      onPressed: _enterRoom,
                      icon: Icon(Icons.add_link),
                      label: Text(L.t.addTorrentRoom),
                    ),
                    OutlinedButton.icon(
                      onPressed: _importTorrentRoom,
                      icon: Icon(Icons.upload_file),
                      label: Text(L.t.importTorrent),
                    ),
                  ],
                )
              : RefreshIndicator(
                  onRefresh: () async {
                    for (final g in _groups) {
                      _api.syncGroup(g.id);
                    }
                    await Future.delayed(const Duration(milliseconds: 600));
                    _reload();
                  },
                  child: ListView.separated(
                    itemCount: _groups.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) => _groups[i].dmRequest
                        ? _requestTile(_groups[i])
                        : _GroupTile(
                            group: _groups[i],
                            onTap: () => _openGroup(_groups[i]),
                            onLongPress: () =>
                                _showConversationMenu(_groups[i]),
                          ),
                  ),
                ),
      floatingActionButton: !_api.available || _groups.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showAddMenu(context),
              icon: Icon(Icons.add_comment),
              label: Text(L.t.fabGroup),
            ),
    );
  }

  void _showAddMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.add_link),
              title: Text(L.t.addTorrentRoom),
              subtitle: Text(L.t.addTorrentRoomDesc),
              onTap: () {
                Navigator.pop(ctx);
                _enterRoom();
              },
            ),
            ListTile(
              leading: Icon(Icons.upload_file),
              title: Text(L.t.importTorrent),
              subtitle: Text(L.t.importTorrentRoomDesc),
              onTap: () {
                Navigator.pop(ctx);
                _importTorrentRoom();
              },
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------- long-press menu

  /// Long-press a conversation row for quick actions (mark read / rename note /
  /// copy invite / resync / block / leave) without opening the room. Mirrors
  /// the actions in the room's own info sheet, using the same strings.
  void _showConversationMenu(GroupSummary g) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    GroupAvatar(name: g.name, keyHex: g.id, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(g.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (g.unread > 0)
                ListTile(
                  leading: const Icon(Icons.mark_chat_read_outlined),
                  title: Text(L.t.markAsRead),
                  onTap: () {
                    Navigator.pop(ctx);
                    _markRead(g);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(L.t.renameGroup),
                subtitle: Text(L.t.renameLocalNote),
                onTap: () {
                  Navigator.pop(ctx);
                  _renameGroup(g);
                },
              ),
              if (!g.dm)
                ListTile(
                  leading: const Icon(Icons.link),
                  title: Text(L.t.copyInviteLink),
                  onTap: () {
                    Navigator.pop(ctx);
                    _copyInvite(g);
                  },
                ),
              if (!g.dm)
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: Text(L.t.resync),
                  onTap: () {
                    Navigator.pop(ctx);
                    _resync(g);
                  },
                ),
              if (g.dm)
                ListTile(
                  leading: const Icon(Icons.block),
                  title: Text(L.t.block),
                  onTap: () {
                    Navigator.pop(ctx);
                    _blockPeer(g);
                  },
                ),
              ListTile(
                leading: Icon(Icons.logout, color: theme.colorScheme.error),
                title: Text(L.t.leaveGroup,
                    style: TextStyle(color: theme.colorScheme.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  _leaveGroup(g);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _markRead(GroupSummary g) {
    try {
      _api.markRead(g.id);
    } catch (_) {}
    _reload();
  }

  Future<void> _renameGroup(GroupSummary g) async {
    final name = await _promptText(
      context,
      title: L.t.renameGroup,
      label: L.t.renameGroup,
      hint: L.t.renameLocalNote,
      confirm: L.t.save,
      initial: g.name,
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      _api.renameGroup(g.id, name.trim());
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _copyInvite(GroupSummary g) async {
    final magnet = g.inviteMagnet.isNotEmpty
        ? g.inviteMagnet
        : 'magnet:?xt=urn:btih:${g.id}';
    await Clipboard.setData(ClipboardData(text: magnet));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L.t.copiedInvite)));
    }
  }

  void _resync(GroupSummary g) {
    try {
      _api.syncGroup(g.id);
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L.t.resyncStarted)));
    }
    _reload();
  }

  void _blockPeer(GroupSummary g) {
    try {
      _api.dmBlock(g.peerPk);
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L.t.dmBlocked)));
    }
    _reload();
  }

  Future<void> _leaveGroup(GroupSummary g) async {
    final del = await _confirmLeave(context, isDm: g.dm);
    if (del == null || !mounted) return;
    try {
      _api.leaveGroup(g.id, deleteHistory: del);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Leave confirmation with the "also delete local history" checkbox.
  /// Returns null on cancel, otherwise the deleteHistory choice.
  Future<bool?> _confirmLeave(BuildContext context, {required bool isDm}) {
    var deleteHistory = true;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            title: Text(L.t.leaveGroupQ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isDm ? L.t.leaveGroupHint : L.t.leaveRoomHint),
                const SizedBox(height: 4),
                CheckboxListTile(
                  value: deleteHistory,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(L.t.deleteLocalHistory),
                  onChanged: (v) => setSt(() => deleteHistory = v ?? true),
                ),
                Text(L.t.deleteLocalHistoryHint,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: Text(L.t.cancel)),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, deleteHistory),
                  child: Text(L.t.leave)),
            ],
          );
        },
      ),
    );
  }
}

String shortPkLabel(String pk) =>
    pk.length > 12 ? '${pk.substring(0, 12)}…' : pk;

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.group,
    required this.onTap,
    this.onLongPress,
  });

  final GroupSummary group;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = group.previewText.isEmpty
        ? (group.messages == 0 ? L.t.noMessages : '…')
        : '${group.previewOwn ? '我' : group.previewAuthor}: ${group.previewText}';
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: Stack(
        children: [
          GroupAvatar(name: group.name, keyHex: group.id, size: 48),
          if (group.dm)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.lock,
                    size: 12, color: Theme.of(context).colorScheme.primary),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          if (group.dm) ...[
            Icon(Icons.lock_outline,
                size: 14, color: theme.colorScheme.primary),
            SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              group.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (group.syncing) ...[
            SizedBox(width: 6),
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        group.kind3Preview(preview),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatListTime(
                group.previewTs > 0 ? group.previewTs : group.lastTs),
            style: theme.textTheme.bodySmall,
          ),
          SizedBox(height: 4),
          if (group.unread > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                group.unread > 99 ? '99+' : '${group.unread}',
                style: TextStyle(
                    color: theme.colorScheme.onError,
                    fontSize: 11,
                    fontWeight: FontWeight.bold),
              ),
            )
          else if (group.dm && group.awaitingAccept)
            Text(L.t.dmAwaitingAccept,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.tertiary))
          else if (group.dm)
            Icon(
              group.online > 0 ? Icons.circle : Icons.circle_outlined,
              size: 10,
              color: group.online > 0
                  ? Colors.green
                  : theme.colorScheme.outlineVariant,
            )
          else if (group.online > 0)
            Text(L.t.onlinePeers(group.online),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }
}

extension on GroupSummary {
  String kind3Preview(String fallback) {
    if (previewKind == 3) {
      switch (previewText) {
        case '':
          return L.t.sysMsg;
        default:
          return fallback;
      }
    }
    return fallback;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.outlineVariant),
            SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            SizedBox(height: 24),
            Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: actions),
          ],
        ),
      ),
    );
  }
}

class _DemoModeHint extends StatelessWidget {
  const _DemoModeHint({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.memory,
                size: 56, color: theme.colorScheme.outlineVariant),
            SizedBox(height: 16),
            Text(L.t.demoMode, style: theme.textTheme.titleMedium),
            SizedBox(height: 8),
            Text(
              L.t.demoHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (error != null) ...[
              SizedBox(height: 8),
              Text(error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Text input dialog with optional paste button.
Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String label,
  String hint = '',
  String? confirm,
  bool multiline = false,
  bool pasteButton = false,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: multiline ? 4 : 1,
            decoration: InputDecoration(labelText: label, hintText: hint),
          ),
          if (pasteButton)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: Icon(Icons.content_paste, size: 18),
                label: Text(L.t.paste),
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) controller.text = data!.text!;
                },
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(L.t.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(confirm ?? L.t.confirm),
        ),
      ],
    ),
  );
}
