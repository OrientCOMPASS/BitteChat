// QQ 风格三页签主框架：聊天 / 种子 / 订阅

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/l10n.dart';
import 'bt_tab.dart';
import 'chat_tab.dart';
import 'rss_tab.dart';
import 'settings_page.dart';
import '../core/prefs.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.prefs});

  final UiPrefs prefs;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _index = 0;
  int _chatUnread = 0;
  StreamSubscription<CoreEvent>? _sub;
  Timer? _timer;
  late final AnimationController _tabAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..value = 1;

  StreamSubscription<CoreEvent>? _errSub;

  @override
  void initState() {
    super.initState();
    final api = BitteApi.instance;
    _errSub = api.events.listen((e) {
      if (!mounted) return;
      String? msg;
      if (e.type == 'torrent_error') {
        msg = L.t.torrentError('${e.data['error'] ?? ''}');
      } else if (e.type == 'rss.error') {
        msg = L.t.rssError('${e.data['error'] ?? ''}');
      }
      if (msg != null && msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 4)));
      }
    });
    WidgetsBinding.instance.addObserver(this);
    _reloadBadge();
    _sub = api.events.listen((e) {
      if (e.isChatMessage || e.isChatGroupUpdated) _reloadBadge();
    });
    // v0.5.27: 3 s polling floor (was 12 s) — badge latency must not depend
    // on event delivery alone; PiliPlus-style: events + lifecycle + short poll
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _reloadBadge());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // foregrounding must refresh at once (background pushes land silently)
    if (state == AppLifecycleState.resumed) _reloadBadge();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _errSub?.cancel();
    _sub?.cancel();
    _timer?.cancel();
    _tabAnim.dispose();
    super.dispose();
  }

  void _reloadBadge() {
    if (!mounted) return;
    try {
      final total = BitteApi.instance
          .chatGroups()
          .fold<int>(0, (sum, g) => sum + g.unread);
      if (total != _chatUnread) setState(() => _chatUnread = total);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FadeTransition(
          opacity: CurvedAnimation(parent: _tabAnim, curve: Curves.easeOut),
          child: IndexedStack(
            index: _index,
            children: [
              ChatTab(onOpenSettings: _openSettings, prefs: widget.prefs),
              BtTab(prefs: widget.prefs),
              const RssTab(),
            ],
          )),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          if (i == _index) return;
          setState(() => _index = i);
          _tabAnim.forward(from: 0);
        },
        destinations: [
          NavigationDestination(
            icon: _chatBadgeIcon(false),
            selectedIcon: _chatBadgeIcon(true),
            label: L.t.chatTab,
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_download_outlined),
            selectedIcon: Icon(Icons.cloud_download),
            label: L.t.btTab,
          ),
          NavigationDestination(
            icon: Icon(Icons.rss_feed_outlined),
            selectedIcon: Icon(Icons.rss_feed),
            label: L.t.rssTab,
          ),
        ],
      ),
    );
  }

  Widget _chatBadgeIcon(bool selected) {
    final icon = Icon(selected ? Icons.chat_bubble : Icons.chat_bubble_outline);
    if (_chatUnread <= 0) return icon;
    return Badge(
      label: Text(_chatUnread > 99 ? '99+' : '$_chatUnread'),
      child: icon,
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsPage(prefs: widget.prefs)),
    );
  }
}

/// Shared page scaffold with per-tab app bar.
class TabScaffold extends StatelessWidget {
  const TabScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.fab,
  });

  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? fab;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: body,
      floatingActionButton: fab,
    );
  }
}

/// Small helper: show a snackbar with an error message.
void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$e'), duration: const Duration(seconds: 3)));
}

/// Helper: core available guard for actions.
bool ensureCore(BuildContext context, BitteApi api) {
  if (!api.available) {
    showError(context, L.t.installApkHint);
    return false;
  }
  return true;
}
