// 设置页：身份、核心信息、数据目录

import 'package:flutter/material.dart';

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../core/api.dart';
import '../core/prefs.dart';
import '../models.dart';
import '../widgets/avatar.dart';
import 'home.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.prefs});

  final UiPrefs prefs;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final BitteApi _api = BitteApi.instance;
  Identity? _identity;
  Map<String, dynamic> _info = {};
  List<FilterRule> _rules = [];

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
      _rules = _api.filterRules();
    });
  }

  void _saveRules() {
    try {
      _api.setFilterRules(_rules);
      _reload();
    } catch (e) {
      showError(context, e);
    }
  }

  Future<void> _editRule(FilterRule? existing) async {
    final rule = existing ??
        FilterRule(
          id: DateTime.now().millisecondsSinceEpoch % 1000000,
          enabled: true,
          field: 'text',
          mode: 'contains',
          value: '',
        );
    final valueCtrl = TextEditingController(text: rule.value);
    String field = rule.field;
    String mode = rule.mode;
    bool caseSensitive = rule.caseSensitive;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: Text(existing == null ? '添加过滤规则' : '编辑过滤规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: field,
                items: const [
                  DropdownMenuItem(value: 'text', child: Text('消息内容')),
                  DropdownMenuItem(value: 'author_name', child: Text('作者昵称')),
                  DropdownMenuItem(value: 'author_pk', child: Text('作者公钥')),
                ],
                onChanged: (v) => setSheet(() => field = v!),
              ),
              DropdownButtonFormField<String>(
                initialValue: mode,
                items: const [
                  DropdownMenuItem(value: 'contains', child: Text('包含')),
                  DropdownMenuItem(value: 'equals', child: Text('等于')),
                  DropdownMenuItem(value: 'regex', child: Text('正则表达式')),
                ],
                onChanged: (v) => setSheet(() => mode = v!),
              ),
              TextField(
                controller: valueCtrl,
                decoration: const InputDecoration(
                    labelText: '匹配值', border: OutlineInputBorder()),
              ),
              SwitchListTile(
                value: caseSensitive,
                title: const Text('区分大小写'),
                onChanged: (v) => setSheet(() => caseSensitive = v),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    rule.field = field;
    rule.mode = mode;
    rule.caseSensitive = caseSensitive;
    rule.value = valueCtrl.text;
    if (existing == null) _rules.add(rule);
    _saveRules();
  }

  Future<void> _pickSeedSource(BuildContext context) async {
    final labels = const {
      SeedSource.brand: ('品牌蓝', Icons.branding_watermark_outlined),
      SeedSource.wallpaper: ('壁纸自动取色', Icons.wallpaper),
      SeedSource.custom: ('自定义颜色', Icons.palette_outlined),
    };
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in SeedSource.values)
              ListTile(
                leading: Icon(labels[s]!.$2),
                title: Text(labels[s]!.$1),
                trailing: widget.prefs.seedSource == s
                    ? Icon(Icons.check_circle,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () async {
                  Navigator.pop(ctx);
                  widget.prefs.seedSource = s;
                  if (s == SeedSource.custom) {
                    await _pickCustomColor(context);
                    return;
                  }
                  await widget.prefs.save();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCustomColor(BuildContext context) async {
    const swatches = [
      0xFF2E7CF6,
      0xFFE5484D,
      0xFF30A46C,
      0xFFF5D90A,
      0xFF8E4EC6,
      0xFFE93D82,
      0xFF0090FF,
      0xFF12A594,
      0xFFFF6E27,
      0xFF64748B,
    ];
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择主题色'),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in swatches)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, c),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Color(c),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      widget.prefs.customColor = picked;
      await widget.prefs.save();
    }
  }

  Future<void> _pickWallpaper(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.image,
        dialogTitle: '选择聊天背景图',
      );
      if (files.isEmpty) return;
      final srcPath = files.single.path;
      if (srcPath == null) return;
      final dest = '${_api.dataDir}/wallpaper.img';
      await File(srcPath).copy(dest);
      widget.prefs.wallpaperPath = dest;
      await widget.prefs.refreshWallpaperSeed();
      await widget.prefs.save();
      messenger.showSnackBar(
          const SnackBar(content: Text('背景已应用；若主题色来源为"壁纸取色"将同时更新')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                    child: Text('消息过滤规则', style: theme.textTheme.titleSmall)),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加'),
                  onPressed: () => _editRule(null),
                ),
              ],
            ),
          ),
          if (_rules.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('无规则。可按昵称/公钥/内容屏蔽恶意消息；'
                  '被屏蔽消息在聊天中折叠显示。'),
            ),
          for (final r in _rules)
            ListTile(
              dense: true,
              leading: Switch(
                value: r.enabled,
                onChanged: (v) {
                  r.enabled = v;
                  _saveRules();
                },
              ),
              title: Text(r.describe()),
              subtitle: Text('#${r.id}'
                  '${r.caseSensitive ? " · 区分大小写" : ""}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _editRule(r),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () {
                      _rules.remove(r);
                      _saveRules();
                    },
                  ),
                ],
              ),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('外观', style: theme.textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemeModePref>(
              segments: const [
                ButtonSegment(
                    value: ThemeModePref.system,
                    label: Text('跟随系统'),
                    icon: Icon(Icons.brightness_auto, size: 18)),
                ButtonSegment(
                    value: ThemeModePref.light,
                    label: Text('浅色'),
                    icon: Icon(Icons.light_mode, size: 18)),
                ButtonSegment(
                    value: ThemeModePref.dark,
                    label: Text('深色'),
                    icon: Icon(Icons.dark_mode, size: 18)),
              ],
              selected: {widget.prefs.themeMode},
              onSelectionChanged: (s) {
                widget.prefs.themeMode = s.first;
                widget.prefs.save();
              },
            ),
          ),
          const SizedBox(height: 4),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题色来源'),
            subtitle: Text(const {
              SeedSource.brand: '品牌蓝',
              SeedSource.wallpaper: '壁纸自动取色',
              SeedSource.custom: '自定义颜色',
            }[widget.prefs.seedSource]!),
            trailing: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: widget.prefs.effectiveSeed(),
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            onTap: () => _pickSeedSource(context),
          ),
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('聊天背景图'),
            subtitle: Text(widget.prefs.wallpaperPath == null
                ? '未设置'
                : '不透明度 ${(widget.prefs.wallpaperOpacity * 100).round()}%'
                    '${widget.prefs.wallpaperBlur ? " · 已模糊" : ""}'),
            trailing: widget.prefs.wallpaperPath != null
                ? IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      widget.prefs.wallpaperPath = null;
                      await widget.prefs.refreshWallpaperSeed();
                      await widget.prefs.save();
                    },
                  )
                : null,
            onTap: () => _pickWallpaper(context),
          ),
          if (widget.prefs.wallpaperPath != null)
            ListTile(
              leading: const Icon(Icons.blur_on),
              title: const Text('背景模糊'),
              trailing: Switch(
                value: widget.prefs.wallpaperBlur,
                onChanged: (v) {
                  widget.prefs.wallpaperBlur = v;
                  widget.prefs.save();
                },
              ),
            ),
          if (widget.prefs.wallpaperPath != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Text('不透明度'),
                  Expanded(
                    child: Slider(
                      value: widget.prefs.wallpaperOpacity,
                      min: 0.05,
                      max: 0.6,
                      onChanged: (v) {
                        widget.prefs.wallpaperOpacity = v;
                        widget.prefs.save();
                      },
                    ),
                  ),
                ],
              ),
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
          const SizedBox(height: 8),
          const Divider(),
          const AboutListTile(
            icon: Icon(Icons.favorite_outline),
            applicationName: 'BitteChat',
            applicationVersion: '0.4.0',
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
