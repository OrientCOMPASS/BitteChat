// 群聊视图：消息流（哈希链 DAG 的线性化展示）+ 输入框 + 群详情/邀请

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/api.dart';
import '../core/files.dart';
import '../models.dart';
import '../widgets/audio_row.dart';
import 'media_pages.dart';
import '../widgets/avatar.dart';
import '../widgets/time_fmt.dart';
import 'home.dart';

class ChatViewPage extends StatefulWidget {
  const ChatViewPage({super.key, required this.group});

  final GroupSummary group;

  @override
  State<ChatViewPage> createState() => _ChatViewPageState();
}

class _ChatViewPageState extends State<ChatViewPage> {
  late final BitteApi _api = BitteApi.instance;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = [];
  bool _sending = false;
  StreamSubscription<CoreEvent>? _sub;
  Map<String, dynamic> _detail = {};
  Timer? _detailTimer;
  bool _showJump = false;

  String get _gid => widget.group.id;
  bool get _isDm => widget.group.dm;

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
      setState(() => _messages = msgs);
      if (markRead) _api.markRead(_gid);
      if (stick) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (_) {}
  }

  void _loadDetail({bool silent = false}) {
    try {
      _detail = _api.groupDetail(_gid);
      if (!silent && mounted) setState(() {});
    } catch (_) {}
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

  void _longPressMessage(ChatMessage m) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!m.own && !_isDm)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('发起私聊'),
                subtitle: Text('与 ${m.authorName} 的端到端加密频道'),
                onTap: () async {
                  Navigator.pop(ctx);
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
                        builder: (_) => ChatViewPage(group: summary)));
                    _reload();
                  } catch (e) {
                    if (mounted) showError(context, e);
                  }
                },
              ),
            if (m.payloadKind == MsgPayloadKind.text)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('复制消息内容'),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: m.text));
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('已复制')));
                },
              ),
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text('复制消息 ID（SHA-1）'),
              subtitle: Text(shortHash(m.id, 16)),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: m.id));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('已复制消息 ID')));
              },
            ),
            ListTile(
              leading: const Icon(Icons.verified_user),
              title: const Text('签名信息'),
              subtitle: Text('作者公钥 ${shortHash(m.authorPk, 16)}\n'
                  '状态 ${m.state == 1 ? "已确认（DHT 已存储）" : "待确认"}'),
              onTap: () => Navigator.pop(ctx),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
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
        dialogTitle: '选择要发送的文件',
        type: FileType.any,
      );
      if (files.isEmpty) return;
      final path = files.single.path;
      final name = files.single.name;
      if (path == null) return;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        const SnackBar(content: Text('正在做种并发送……')),
      );
      final r = _api.sendFile(_gid, path, name: name);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text('已发送，正在做种：${shortHash('${r['infohash'] ?? ''}')}'),
      ));
      _reload();
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
          SnackBar(content: Text('已开始下载「${att.name}」（聊天内传输，不占用种子页）')),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
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
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(widget.group.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            if (missing > 0)
              Text(
                '同步中：缺 $missing 条历史消息',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              )
            else if (_isDm)
              Text(
                '端到端加密私聊（X25519 + ChaCha20-Poly1305）',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              )
            else
              Text(
                '历史已同步 · ${_detail['peers'] is List ? (_detail['peers'] as List).length : 0} 节点在线',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '重新同步',
            icon: const Icon(Icons.sync),
            onPressed: () {
              _api.syncGroup(_gid);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已向 DHT 与相邻节点发起同步')),
              );
            },
          ),
          IconButton(
            tooltip: '群详情',
            icon: const Icon(Icons.info_outline),
            onPressed: _openGroupSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      '群刚创建，还没有消息\n说点什么吧 👇',
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
                      itemCount: _messages.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return _GenesisHeader(groupName: widget.group.name);
                        }
                        final m = _messages[i - 1];
                        final showAuthor = i == 1 ||
                            !_messages[i - 2].own != !m.own ||
                            m.ts - _messages[i - 2].ts > 5 * 60 * 1000 ||
                            _isNewDay(_messages[i - 2].ts, m.ts);
                        final showDay =
                            i == 1 || _isNewDay(_messages[i - 2].ts, m.ts);
                        return Column(
                          children: [
                            if (showDay) DayDivider(ts: m.ts),
                            GestureDetector(
                              onLongPress: () => _longPressMessage(m),
                              child: MessageBubble(
                                message: m,
                                showAuthor: showAuthor,
                                onDownload: () => _downloadAttachment(m),
                              ),
                            ),
                          ],
                        );
                      },
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
      floatingActionButton: _showJump
          ? FloatingActionButton.small(
              heroTag: 'jump-bottom',
              onPressed: _scrollToBottom,
              child: const Icon(Icons.keyboard_double_arrow_down),
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
          const SizedBox(height: 8),
          Text(
            '「$groupName」的哈希链从这里开始',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          Text(
            '每条消息都经作者签名并链接前序消息，任何篡改都会被网络拒绝',
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
  });

  final ChatMessage message;
  final bool showAuthor;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = message;

    if (m.payloadKind == MsgPayloadKind.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: Text(
            _systemText(m),
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
                    m.authorName.isEmpty ? '匿名' : m.authorName,
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
                    const SizedBox(width: 6),
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
                          ? _AttachmentBody(message: m, onDownload: onDownload)
                          : _TextBody(message: m),
                    ),
                  ),
                  if (own) ...[
                    const SizedBox(width: 6),
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
                      const SizedBox(width: 4),
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
        return '🎉 ${m.authorName} 创建了群聊「${m.systemDetail}」';
      case 'join':
        return '👋 ${m.authorName} 加入了群聊';
      case 'leave':
        return '${m.authorName} 退出了群聊';
      case 'rename':
        return '📛 ${m.authorName} 将群名改为「${m.systemDetail}」';
      default:
        return '[系统] ${m.systemCode} ${m.systemDetail}';
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
  const _AttachmentBody({required this.message, this.onDownload});
  final ChatMessage message;
  final VoidCallback? onDownload;

  bool get _have => message.haveFile && message.localPath != null;

  void _openImage(BuildContext context, String path) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: IconButton.filled(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
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
            builder: (_) => VideoPlayerPage(path: path, title: att.name)));
      case MediaKind.text:
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TextPreviewPage(path: path, title: att.name)));
      case MediaKind.audio:
      case MediaKind.other:
        final ok = await openWithExternalApp(path, mimeFromName(att.name));
        if (!ok && context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('没有可打开该文件的应用')));
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
                const SizedBox(width: 8),
                Flexible(
                  child: Text(att.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: dl.progress, minHeight: 5),
            ),
            const SizedBox(height: 2),
            Text(
              '${(dl.progress * 100).toStringAsFixed(0)}% · '
              '${formatSpeed(dl.rate)} · ${dl.peers} peers'
              '${dl.paused ? " · 已暂停" : ""}',
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
              const SizedBox(width: 8),
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
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('通过 BT 下载'),
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
                const SizedBox(height: 4),
                const Text('点击播放视频'),
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
            label: Text(kind == MediaKind.text ? '预览文本' : '用其他应用打开'),
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
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_fileIcon(att.name),
                size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 4),
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
        return '图片';
      case MediaKind.audio:
        return '音频';
      case MediaKind.video:
        return '视频';
      case MediaKind.text:
        return '文本';
      case MediaKind.other:
        return '文件';
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
              tooltip: '发送文件（做种）',
              icon: const Icon(Icons.attach_file),
              onPressed: sending ? null : onAttach,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: '说点什么……（消息将签名并写入哈希链）',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(22))),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 6),
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
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send, size: 20),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _detail;
    final group = _asMap(d['group']);
    final magnet = (group['invite_magnet'] as String?) ?? '';
    final peers = (d['peers'] as List?) ?? [];
    final heads = (d['heads'] as List?) ?? [];
    final creator = _asMap(d['creator']);
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
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((group['name'] as String?) ?? '群聊',
                        style: theme.textTheme.titleMedium),
                    Text(
                      '创建于 ${formatFull((group['created'] as int?) ?? 0)} · '
                      '创建者 ${(creator['name'] as String?) ?? '?'}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
              IconButton(
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh),
                  onPressed: _refresh),
            ],
          ),
          const SizedBox(height: 16),
          _StatRow(label: '消息总数', value: '${d['messages'] ?? 0}'),
          _StatRow(label: '链头 (heads)', value: '${heads.length}'),
          _StatRow(label: '缺失历史', value: '${d['missing'] ?? 0}'),
          _StatRow(label: '头指针版本 (seq)', value: '${d['head_seq'] ?? 0}'),
          _StatRow(label: '在线成员', value: '${peers.length}'),
          _StatRow(
              label: '清单种子',
              value: shortHash('${d['manifest_infohash'] ?? ''}', 16)),
          const SizedBox(height: 16),
          Text('邀请链接', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
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
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制磁力邀请链接'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: magnet));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制：对方在聊天页「加入群聊」粘贴即可')),
                );
              }
            },
          ),
          const SizedBox(height: 12),
          if (peers.isNotEmpty) ...[
            Text('P2P 节点', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
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
                  '${pm['client'] ?? ''} · ${(pm['chat_capable'] == true) ? "支持聊天" : "普通 BT 客户端"}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              );
            }),
          ],
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_outlined),
            title: const Text('修改群名'),
            subtitle: const Text('以签名系统消息广播给全群'),
            onTap: () async {
              final controller =
                  TextEditingController(text: (group['name'] as String?) ?? '');
              final name = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('修改群名'),
                  content: TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 32,
                    decoration:
                        const InputDecoration(border: OutlineInputBorder()),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () =>
                            Navigator.pop(ctx, controller.text.trim()),
                        child: const Text('保存')),
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
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            icon: const Icon(Icons.logout),
            label: const Text('退出群聊（保留本地历史）'),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('退出群聊？'),
                  content: const Text('将停止做种群清单，本地聊天记录默认保留。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('退出')),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                try {
                  _api.leaveGroup(widget.groupId);
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              }
            },
          ),
          const SizedBox(height: 24),
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

/// 建群后展示的邀请弹层（二维码 + 复制）
class InviteSheet extends StatelessWidget {
  const InviteSheet({super.key, required this.magnet});
  final String magnet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('群聊已创建 🎉', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '把邀请链接发给朋友（对方需能连上你或任一在线成员的种子网络）',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 16),
          if (magnet.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(10),
              color: Colors.white,
              child: QrImageView(
                  data: magnet, size: 200, backgroundColor: Colors.white),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制链接'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: magnet));
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                },
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
