// 会话草稿盒（v0.5.19，仅内存）：切换会话/返回不丢输入与回复引用，杀进程清空。
// 会话列表据此在预览行显示 铅笔+草稿文本（参考 QQ 列表样式）。

/// One conversation's unsent draft (text + optional quote-reply target).
class ChatDraft {
  ChatDraft({required this.text, this.replyTo, required this.ts});

  String text;
  String? replyTo;
  int ts;
}

/// Process-lifetime draft storage keyed by group id.
class DraftBox {
  DraftBox._();

  static final Map<String, ChatDraft> _drafts = {};

  /// The draft of [gid], or null when empty/absent.
  static ChatDraft? get(String gid) {
    final d = _drafts[gid];
    if (d == null) return null;
    if (d.text.trim().isEmpty && d.replyTo == null) return null;
    return d;
  }

  static void put(String gid, {required String text, String? replyTo}) {
    if (text.trim().isEmpty && replyTo == null) {
      _drafts.remove(gid);
      return;
    }
    _drafts[gid] = ChatDraft(
        text: text,
        replyTo: replyTo,
        ts: DateTime.now().millisecondsSinceEpoch);
  }

  static void clear(String gid) => _drafts.remove(gid);
}
