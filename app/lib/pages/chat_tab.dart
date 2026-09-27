// 聊天页：群组列表 + 创建/加入群聊

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../models.dart';
import '../widgets/avatar.dart';
import '../widgets/time_fmt.dart';
import 'chat_view.dart';
import 'home.dart';

class ChatTab extends StatefulWidget {
  const ChatTab({super.key, this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  late final BitteApi _api = BitteApi.instance;
  List<GroupSummary> _groups = [];
  StreamSubscription<CoreEvent>? _sub;
  Timer? _refreshTimer;

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
  }

  @override
  void dispose() {
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
      MaterialPageRoute(builder: (_) => ChatViewPage(group: g)),
    );
    _reload();
  }

  Future<void> _createGroup() async {
    final name = await _promptText(
      context,
      title: '创建群聊',
      label: '群名称',
      hint: '例如：BT 爱好者',
      confirm: '创建',
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      final r = _api.createGroup(name.trim());
      if (!mounted) return;
      _reload();
      await _showInviteSheet(r['invite_magnet'] as String? ?? '');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _joinGroup() async {
    final magnet = await _promptText(
      context,
      title: '加入群聊',
      label: '邀请磁力链接',
      hint: 'magnet:?xt=urn:btih:...',
      confirm: '加入',
      multiline: true,
      pasteButton: true,
    );
    if (magnet == null || magnet.trim().isEmpty) return;
    try {
      final r = _api.joinGroup(magnet.trim());
      if (!mounted) return;
      if (r['already'] == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已经在该群中')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('正在从 BT 网络获取群清单……需要群内有成员在线做种'),
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
        title: const Text('聊天'),
        actions: [
          IconButton(
            tooltip: '身份设置',
            icon: const Icon(Icons.person_outline),
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: !_api.available
          ? const _DemoModeHint()
          : _groups.isEmpty
              ? _EmptyState(
                  icon: Icons.forum_outlined,
                  title: '还没有群聊',
                  subtitle: '一个 BT 种子就是一个群。\n创建群聊，或粘贴邀请磁力链接加入。',
                  actions: [
                    FilledButton.icon(
                      onPressed: _createGroup,
                      icon: const Icon(Icons.add),
                      label: const Text('创建群聊'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _joinGroup,
                      icon: const Icon(Icons.link),
                      label: const Text('加入群聊'),
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
                    itemBuilder: (context, i) =>
                        _GroupTile(group: _groups[i], onTap: () => _openGroup(_groups[i])),
                  ),
                ),
      floatingActionButton: !_api.available || _groups.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showAddMenu(context),
              icon: const Icon(Icons.add_comment),
              label: const Text('群聊'),
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
              leading: const Icon(Icons.group_add),
              title: const Text('创建群聊'),
              subtitle: const Text('生成邀请磁力链接，分享给朋友'),
              onTap: () {
                Navigator.pop(ctx);
                _createGroup();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_link),
              title: const Text('加入群聊'),
              subtitle: const Text('粘贴或扫描他人分享的邀请链接'),
              onTap: () {
                Navigator.pop(ctx);
                _joinGroup();
              },
            ),
            const SizedBox(height: 8),
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
        ? (group.messages == 0 ? '暂无消息' : '…')
        : '${group.previewOwn ? '我' : group.previewAuthor}: ${group.previewText}';
    return ListTile(
      onTap: onTap,
      leading: GroupAvatar(name: group.name, keyHex: group.id, size: 48),
      title: Row(
        children: [
          Flexible(
            child: Text(
              group.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (group.syncing) ...[
            const SizedBox(width: 6),
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
            formatListTime(group.previewTs > 0 ? group.previewTs : group.lastTs),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
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
            Text('${group.online} 在线',
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
          return '系统消息';
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
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 24),
            Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center,
                children: actions),
          ],
        ),
      ),
    );
  }
}

class _DemoModeHint extends StatelessWidget {
  const _DemoModeHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.memory, size: 56, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 16),
            Text('演示模式', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '未找到 libbitte_core.so。\n请安装 CI 构建的 Android APK 以启用完整功能。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
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
  String confirm = '确定',
  bool multiline = false,
  bool pasteButton = false,
}) async {
  final controller = TextEditingController();
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
                icon: const Icon(Icons.content_paste, size: 18),
                label: const Text('粘贴'),
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
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(confirm),
        ),
      ],
    ),
  );
}
