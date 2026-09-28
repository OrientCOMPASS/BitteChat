// 聊天页：群组列表 + 创建/加入群聊

import 'dart:async';

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
      if (e.isChatGroupUpdated || e.isChatMessage) _reload();
    });
    // light polling keeps previews fresh even without events
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _reload());
    _magnetListener = () {
      final m = pendingMagnet.value;
      if (m == null || m.isEmpty) return;
      pendingMagnet.value = null;
      _joinGroup(initial: m);
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

  Future<void> _openGroup(GroupSummary g) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ChatViewPage(group: g, prefs: widget.prefs)),
    );
    _reload();
  }

  Future<void> _createGroup() async {
    final name = await _promptText(
      context,
      title: L.t.createGroup,
      label: L.t.groupName,
      hint: L.t.groupNameHint,
      confirm: L.t.create,
    );
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;
    try {
      final r = _api.createGroup(name.trim());
      _reload();
      await _showInviteSheet(r['invite_magnet'] as String? ?? '');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _joinGroup({String initial = ''}) async {
    final magnet = await _promptText(
      context,
      title: L.t.joinGroup,
      label: L.t.inviteMagnet,
      hint: L.t.magnetHint,
      confirm: L.t.join,
      multiline: true,
      pasteButton: true,
      initial: initial,
    );
    if (magnet == null || magnet.trim().isEmpty) return;
    try {
      final r = _api.joinGroup(magnet.trim());
      if (!mounted) return;
      if (r['already'] == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t.alreadyInGroup)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(L.t.fetchingManifest),
          duration: Duration(seconds: 4),
        ));
      }
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _showInviteSheet(String magnet) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => InviteSheet(magnet: magnet),
    );
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
                      onPressed: _createGroup,
                      icon: Icon(Icons.add),
                      label: Text(L.t.createGroup),
                    ),
                    OutlinedButton.icon(
                      onPressed: _joinGroup,
                      icon: Icon(Icons.link),
                      label: Text(L.t.joinGroup),
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
                    itemBuilder: (context, i) => _GroupTile(
                        group: _groups[i], onTap: () => _openGroup(_groups[i])),
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
              leading: Icon(Icons.group_add),
              title: Text(L.t.createGroup),
              subtitle: Text(L.t.createGroupDesc),
              onTap: () {
                Navigator.pop(ctx);
                _createGroup();
              },
            ),
            ListTile(
              leading: Icon(Icons.add_link),
              title: Text(L.t.joinGroup),
              subtitle: Text(L.t.joinViaPaste),
              onTap: () {
                Navigator.pop(ctx);
                _joinGroup();
              },
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group, required this.onTap});

  final GroupSummary group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = group.previewText.isEmpty
        ? (group.messages == 0 ? L.t.noMessages : '…')
        : '${group.previewOwn ? '我' : group.previewAuthor}: ${group.previewText}';
    return ListTile(
      onTap: onTap,
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
