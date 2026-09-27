// QQ 风格三页签主框架：聊天 / 种子 / 订阅

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import 'bt_tab.dart';
import 'chat_tab.dart';
import 'rss_tab.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;
  int _chatUnread = 0;
  StreamSubscription<CoreEvent>? _sub;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final api = BitteApi.instance;
    _reloadBadge();
    _sub = api.events.listen((e) {
      if (e.isChatMessage || e.isChatGroupUpdated) _reloadBadge();
    });
    _timer = Timer.periodic(const Duration(seconds: 12), (_) => _reloadBadge());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
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
      body: IndexedStack(
        index: _index,
        children: [
          ChatTab(onOpenSettings: _openSettings),
          const BtTab(),
          const RssTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: _chatBadgeIcon(false),
            selectedIcon: _chatBadgeIcon(true),
            label: '聊天',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_download_outlined),
            selectedIcon: Icon(Icons.cloud_download),
            label: '种子',
          ),
          NavigationDestination(
            icon: Icon(Icons.rss_feed_outlined),
            selectedIcon: Icon(Icons.rss_feed),
            label: '订阅',
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
      MaterialPageRoute(builder: (_) => const SettingsPage()),
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
    showError(context, '原生核心不可用：请安装 CI 构建的 APK');
    return false;
  }
  return true;
}
