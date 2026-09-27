// 设置页：身份、核心信息、数据目录

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../widgets/avatar.dart';
import '../models.dart';
import 'home.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final BitteApi _api = BitteApi.instance;
  Identity? _identity;
  Map<String, dynamic> _info = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _identity = _api.identity();
      _info = _api.sysInfo();
    });
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _identity?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('昵称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      _api.setIdentity(name: name.trim());
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = _identity;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          if (id != null)
            ListTile(
              leading: KeyAvatar(keyHex: id.pk, name: id.name, size: 48),
              title: Text(id.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                  '公钥 ${id.pk.length > 16 ? '${id.pk.substring(0, 16)}…' : id.pk}'),
              trailing: const Icon(Icons.edit),
              onTap: _editName,
            )
          else
            const ListTile(
              leading: Icon(Icons.person_off),
              title: Text('原生核心不可用（演示模式）'),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('核心版本'),
            subtitle: Text(
                '${_info['version'] ?? '?'} · 引擎: ${_info['engine'] ?? '?'}'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('数据目录'),
            subtitle: Text(_info['data_dir'] ?? _api.dataDir,
                style: theme.textTheme.bodySmall),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('消息安全'),
            subtitle: Text(
              '每条消息使用你的 Ed25519 密钥签名并链接父消息（git 式哈希链）。'
              '私钥仅保存在本机，永不外传。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          const Divider(),
          const AboutListTile(
            icon: Icon(Icons.favorite_outline),
            applicationName: 'BitteChat',
            applicationVersion: '0.3.0',
            aboutBoxChildren: [
              Text(
                '去中心化 BitTorrent 群聊：一个种子就是一个群，'
                '消息以哈希链方式在 BT/DHT 网络中保存与传播，无法被单点篡改。\n\n'
                'Flutter + Rust + libtorrent · Unlicense',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
