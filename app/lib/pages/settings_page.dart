// 设置页：身份、核心信息、数据目录

import 'package:flutter/material.dart';

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../core/api.dart';
import '../core/prefs.dart';
import '../models.dart';
import '../widgets/avatar.dart';
import 'home.dart';
import '../core/l10n.dart';

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
          title: Text(existing == null ? L.t.addRule : L.t.editRule),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: field,
                items: [
                  DropdownMenuItem(value: 'text', child: Text(L.t.fieldText)),
                  DropdownMenuItem(
                      value: 'author_name', child: Text(L.t.fieldName)),
                  DropdownMenuItem(
                      value: 'author_pk', child: Text(L.t.fieldPk)),
                ],
                onChanged: (v) => setSheet(() => field = v!),
              ),
              DropdownButtonFormField<String>(
                initialValue: mode,
                items: [
                  DropdownMenuItem(
                      value: 'contains', child: Text(L.t.modeContains)),
                  DropdownMenuItem(
                      value: 'equals', child: Text(L.t.modeEquals)),
                  DropdownMenuItem(value: 'regex', child: Text(L.t.modeRegex)),
                ],
                onChanged: (v) => setSheet(() => mode = v!),
              ),
              TextField(
                controller: valueCtrl,
                decoration: InputDecoration(
                    labelText: L.t.matchValue, border: OutlineInputBorder()),
              ),
              SwitchListTile(
                value: caseSensitive,
                title: Text(L.t.caseSensitive),
                onChanged: (v) => setSheet(() => caseSensitive = v),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(L.t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(L.t.save)),
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
    final labels = {
      SeedSource.brand: (L.t.seedBrand, Icons.branding_watermark_outlined),
      SeedSource.wallpaper: (L.t.seedWallpaper, Icons.wallpaper),
      SeedSource.custom: (L.t.seedCustom, Icons.palette_outlined),
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
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCustomColor(BuildContext context) async {
    final swatches = [
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
        title: Text(L.t.pickColor),
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
        dialogTitle: L.t.pickWallpaper,
      );
      if (files.isEmpty) return;
      final srcPath = files.single.path;
      if (srcPath == null) return;
      final dest = '${_api.dataDir}/wallpaper.img';
      await File(srcPath).copy(dest);
      widget.prefs.wallpaperPath = dest;
      await widget.prefs.refreshWallpaperSeed();
      await widget.prefs.save();
      messenger.showSnackBar(SnackBar(content: Text(L.t.wallpaperApplied)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _identity?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.editName),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(L.t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(L.t.save)),
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
      appBar: AppBar(title: Text(L.t.settings)),
      body: ListView(
        children: [
          SizedBox(height: 8),
          if (id != null)
            ListTile(
              leading: KeyAvatar(keyHex: id.pk, name: id.name, size: 48),
              title: Text(id.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(L.t.pubkeyLabel(
                  id.pk.length > 16 ? '${id.pk.substring(0, 16)}…' : id.pk)),
              trailing: Icon(Icons.edit),
              onTap: _editName,
            )
          else
            ListTile(
              leading: Icon(Icons.person_off),
              title: Text(L.t.coreUnavailableShort),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                    child: Text(L.t.filterRules,
                        style: theme.textTheme.titleSmall)),
                TextButton.icon(
                  icon: Icon(Icons.add, size: 18),
                  label: Text(L.t.add),
                  onPressed: () => _editRule(null),
                ),
              ],
            ),
          ),
          if (_rules.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(L.t.noRules + L.t.noRules2),
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
              subtitle: Text(
                  '#${r.id}${r.caseSensitive ? L.t.caseSensitiveMark : ''}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _editRule(r),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, size: 18),
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
            child: Text(L.t.appearance, style: theme.textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemeModePref>(
              segments: [
                ButtonSegment(
                    value: ThemeModePref.system,
                    label: Text(L.t.themeSystem),
                    icon: Icon(Icons.brightness_auto, size: 18)),
                ButtonSegment(
                    value: ThemeModePref.light,
                    label: Text(L.t.themeLight),
                    icon: Icon(Icons.light_mode, size: 18)),
                ButtonSegment(
                    value: ThemeModePref.dark,
                    label: Text(L.t.themeDark),
                    icon: Icon(Icons.dark_mode, size: 18)),
              ],
              selected: {widget.prefs.themeMode},
              onSelectionChanged: (s) {
                widget.prefs.themeMode = s.first;
                widget.prefs.save();
              },
            ),
          ),
          SizedBox(height: 4),
          ListTile(
            leading: Icon(Icons.palette_outlined),
            title: Text(L.t.seedSource),
            subtitle: Text({
              SeedSource.brand: L.t.seedBrand,
              SeedSource.wallpaper: L.t.seedWallpaper,
              SeedSource.custom: L.t.seedCustom,
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
            leading: Icon(Icons.image_outlined),
            title: Text(L.t.wallpaper),
            subtitle: Text(widget.prefs.wallpaperPath == null
                ? L.t.wallpaperNone
                : L.t.wallpaperSet(
                        (widget.prefs.wallpaperOpacity * 100).round()) +
                    (widget.prefs.wallpaperBlur ? L.t.blurredMark : '')),
            trailing: widget.prefs.wallpaperPath != null
                ? IconButton(
                    tooltip: L.t.clear,
                    icon: Icon(Icons.delete_outline),
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
              leading: Icon(Icons.blur_on),
              title: Text(L.t.wallpaperBlur),
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
                  Text(L.t.opacity),
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
            leading: Icon(Icons.info_outline),
            title: Text(L.t.coreVersion),
            subtitle: Text(L.t.coreVersionValue(
                '${_info['version'] ?? '?'}', '${_info['engine'] ?? '?'}')),
          ),
          ListTile(
            leading: Icon(Icons.folder_outlined),
            title: Text(L.t.dataDir),
            subtitle: Text(_info['data_dir'] ?? _api.dataDir,
                style: theme.textTheme.bodySmall),
          ),
          ListTile(
            leading: Icon(Icons.shield_outlined),
            title: Text(L.t.msgSecurity),
            subtitle: Text(
              L.t.msgSecurityDesc + L.t.privKeyLocal,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          const Divider(),
          SizedBox(height: 8),
          const Divider(),
          AboutListTile(
            icon: Icon(Icons.favorite_outline),
            applicationName: 'BitteChat',
            applicationVersion: '0.4.0',
            aboutBoxChildren: [
              Text(
                '${L.t.aboutDesc}${L.t.aboutDesc2}'
                'Flutter + Rust + libtorrent · Unlicense',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
