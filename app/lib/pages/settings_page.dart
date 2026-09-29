// 设置页：身份、核心信息、数据目录

import 'package:flutter/material.dart';

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../core/api.dart';
import '../core/applog.dart';
import '../widgets/filter_script_page.dart';
import '../core/prefs.dart';
import 'wallpaper_edit.dart';
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
  List<IdentityInfo> _identities = [];
  Map<String, dynamic> _dlDir = {};

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
      _identities = _api.identities();
      try {
        _dlDir = _api.getDownloadDir();
      } catch (_) {}
    });
  }

  Future<void> _editDownloadDir() async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController(text: '${_dlDir['path'] ?? ''}');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.downloadDir),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L.t.downloadDirHint,
                style: Theme.of(ctx)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(ctx).colorScheme.outline)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 2,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(L.t.downloadDirPick),
                  onPressed: () async {
                    final dir = await FilePicker.getDirectoryPath();
                    if (dir != null) controller.text = dir;
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: Text(L.t.downloadDirReset),
                  onPressed: () =>
                      controller.text = '${_dlDir['default'] ?? ''}',
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(L.t.save)),
        ],
      ),
    );
    if (saved != true) {
      controller.dispose();
      return;
    }
    final path = controller.text.trim();
    controller.dispose();
    try {
      // empty string resets to the app-private default
      final reset = path.isEmpty || path == '${_dlDir['default'] ?? ''}';
      final r = _api.setDownloadDir(reset ? '' : path);
      _reload();
      messenger.showSnackBar(SnackBar(
          content: Text('${L.t.downloadDirSaved}: ${r['path'] ?? ''}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
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
      if (!mounted) return;
      await _editWallpaper(srcPath);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// The editor must always re-frame the PRISTINE picture: the saved
  /// wallpaper already has padding/rotation baked in, so re-editing it would
  /// stack artifacts (users saw "this round starts from last round's result").
  /// The editor keeps a copy of the original at `<dest>.src`.
  String _wallpaperEditSource() {
    final pristine = File('${_api.dataDir}/wallpaper.img.src');
    if (pristine.existsSync()) return pristine.path;
    return widget.prefs.wallpaperPath!;
  }

  /// Open the crop/preview editor for [srcPath]; on save the cropped bitmap
  /// becomes the global wallpaper.
  Future<void> _editWallpaper(String srcPath) async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => WallpaperEditPage(
          sourcePath: srcPath,
          prefs: widget.prefs,
          destPath: '${_api.dataDir}/wallpaper.img',
        ),
      ),
    );
    if (saved == true) {
      await widget.prefs.refreshWallpaperSeed();
      messenger.showSnackBar(SnackBar(content: Text(L.t.wallpaperApplied)));
    }
  }

  Future<void> _exportLogs() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dest = await AppLog.exportToDownloads();
      messenger.showSnackBar(SnackBar(content: Text(L.t.logsExported(dest))));
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('${L.t.exportLogsFail} $e')));
    }
  }

  Future<void> _createIdentity() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.createIdentity),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L.t.identitiesHint,
                style: Theme.of(ctx)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(ctx).colorScheme.error)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 32,
              decoration: InputDecoration(
                  labelText: L.t.newIdentityName,
                  border: const OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(L.t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(L.t.create)),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      final r = _api.createIdentity(name);
      final id = (r['id'] as num).toInt();
      if (!mounted) return;
      final activate = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(L.t.identityCreated(name)),
          content: Text(L.t.switchIdentityHint),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(L.t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(L.t.switchIdentity)),
          ],
        ),
      );
      if (activate == true) {
        _api.switchIdentity(id);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(L.t.switched(name))));
        }
      }
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _switchIdentity(IdentityInfo i) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.switchIdentityQ(i.name)),
        content: Text(L.t.switchIdentityHint),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L.t.switchIdentity)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      _api.switchIdentity(i.id);
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t.switched(i.name))));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteIdentity(IdentityInfo i) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t.deleteIdentityQ(i.name)),
        content: Text(L.t.deleteIdentityWarn),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t.deleteIdentity),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      _api.deleteIdentity(i.id);
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t.identityDeleted)));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _setAvatar() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (files.isEmpty) return;
      final p = files.single.path;
      if (p == null) return;
      final bytes = await File(p).readAsBytes();
      if (bytes.length > 10 * 1024) {
        if (mounted) showError(context, Exception('avatar <= 10KB'));
        return;
      }
      _api.setAvatar(base64Encode(bytes));
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// `1.0× / 1.5× / 2.0×` — one decimal keeps the picker column tidy.
  String _fmtX(double r) => r == r.roundToDouble() ? '${r.toInt()}.0×' : '$r×';

  String _localeLabel(String v) {
    switch (v) {
      case 'zh':
        return L.t.langZh;
      case 'en':
        return L.t.langEn;
      default:
        return L.t.langSystem;
    }
  }

  Future<void> _pickLocale(BuildContext context) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(L.t.language),
        children: [
          for (final o in const ['system', 'zh', 'en'])
            ListTile(
              dense: true,
              leading: Icon(o == widget.prefs.localePref
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: Text(_localeLabel(o)),
              onTap: () => Navigator.pop(ctx, o),
            ),
        ],
      ),
    );
    if (picked == null) return;
    widget.prefs.localePref = picked;
    await widget.prefs.save();
    if (mounted) setState(() {});
  }

  /// Radio-style picker used by the playback-speed settings.
  Future<void> _pickSpeed(
    BuildContext context, {
    required String title,
    required List<double> options,
    required double current,
    required ValueChanged<double> onPick,
  }) async {
    final picked = await showDialog<double>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final o in options)
            ListTile(
              dense: true,
              leading: Icon(o == current
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: Text(_fmtX(o)),
              onTap: () => Navigator.pop(ctx, o),
            ),
        ],
      ),
    );
    if (picked == null) return;
    onPick(picked);
    if (mounted) setState(() {});
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
              leading: identityAvatar(id),
              title: Text(id.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(L.t.pubkeyLabel(shortPk(id.pk))),
              trailing: TextButton.icon(
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(L.t.setAvatar),
                onPressed: _setAvatar,
              ),
            ),
          if (id != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(L.t.avatarLocalOnly,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
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
                    child: Text(L.t.identities,
                        style: theme.textTheme.titleSmall)),
                TextButton.icon(
                  icon: const Icon(Icons.person_add_alt, size: 18),
                  label: Text(L.t.createIdentity),
                  onPressed: _createIdentity,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(L.t.identitiesHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
          for (final i in _identities)
            ListTile(
              leading: identityAvatar(
                  Identity(name: i.name, pk: i.pk, avatarB64: i.avatarB64)),
              title: Row(
                children: [
                  Flexible(child: Text(i.name)),
                  if (i.active) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(L.t.activeMark,
                          style: theme.textTheme.labelSmall),
                    ),
                  ],
                ],
              ),
              subtitle: Text(L.t.pubkeyLabel(shortPk(i.pk))),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!i.active)
                    TextButton(
                      onPressed: () => _switchIdentity(i),
                      child: Text(L.t.switchIdentity),
                    ),
                  if (!i.active)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => _deleteIdentity(i),
                    ),
                ],
              ),
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
                  icon: Icon(Icons.data_object, size: 18),
                  label: Text(L.t.filterScript),
                  onPressed: () async {
                    final changed = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const FilterScriptPage()),
                    );
                    if (changed == true) _reload();
                  },
                ),
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
            leading: Icon(Icons.language),
            title: Text(L.t.language),
            trailing: Text(_localeLabel(widget.prefs.localePref)),
            onTap: () => _pickLocale(context),
          ),
          ListTile(
            leading: Icon(Icons.image_outlined),
            title: Text(L.t.wallpaper),
            subtitle: widget.prefs.wallpaperPath == null
                ? Text(L.t.wallpaperNone)
                : (widget.prefs.wallpaperBlur ? Text(L.t.blurredMark) : null),
            trailing: widget.prefs.wallpaperPath != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: L.t.wallpaperEdit,
                        icon: Icon(Icons.crop_original_outlined),
                        onPressed: () => _editWallpaper(_wallpaperEditSource()),
                      ),
                      IconButton(
                        tooltip: L.t.clear,
                        icon: Icon(Icons.delete_outline),
                        onPressed: () async {
                          widget.prefs.wallpaperPath = null;
                          widget.prefs.wallpaperRev++;
                          await widget.prefs.refreshWallpaperSeed();
                          await widget.prefs.save();
                        },
                      ),
                    ],
                  )
                : null,
            onTap: () => _pickWallpaper(context),
          ),
          if (widget.prefs.wallpaperPath != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(Icons.blur_on, size: 20),
                  SizedBox(width: 12),
                  Text(L.t.wallpaperBlur),
                  Expanded(
                    child: Slider(
                      value: widget.prefs.wallpaperBlurSigma.clamp(0.0, 12.0),
                      min: 0,
                      max: 12,
                      divisions: 24,
                      label: widget.prefs.wallpaperBlurSigma == 0
                          ? L.t.wallpaperBlurOff
                          : widget.prefs.wallpaperBlurSigma.toStringAsFixed(1),
                      onChanged: (v) {
                        widget.prefs.wallpaperBlurSigma = v;
                        widget.prefs.save();
                      },
                    ),
                  ),
                ],
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
                  Text('${(widget.prefs.wallpaperOpacity * 100).round()}%'),
                ],
              ),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(L.t.playbackSection, style: theme.textTheme.titleSmall),
          ),
          SwitchListTile(
            value: widget.prefs.playDoubleTapSideSeek,
            title: Text(L.t.dblTapSideSeek),
            subtitle: Text(L.t.dblTapSideSeekHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            onChanged: (v) {
              widget.prefs.playDoubleTapSideSeek = v;
              widget.prefs.save();
            },
          ),
          ListTile(
            leading: Icon(Icons.touch_app_outlined),
            title: Text(L.t.longPressSpeed),
            subtitle: Text(L.t.longPressSpeedHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            trailing: Text(_fmtX(widget.prefs.playLongPressSpeed)),
            onTap: () => _pickSpeed(
              context,
              title: L.t.longPressSpeed,
              options: const [1.5, 2.0, 2.5, 3.0],
              current: widget.prefs.playLongPressSpeed,
              onPick: (v) {
                widget.prefs.playLongPressSpeed = v;
                widget.prefs.save();
              },
            ),
          ),
          ListTile(
            leading: Icon(Icons.speed),
            title: Text(L.t.defaultPlaySpeed),
            trailing: Text(_fmtX(widget.prefs.playDefaultSpeed)),
            onTap: () => _pickSpeed(
              context,
              title: L.t.defaultPlaySpeed,
              options: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0],
              current: widget.prefs.playDefaultSpeed,
              onPick: (v) {
                widget.prefs.playDefaultSpeed = v;
                widget.prefs.save();
              },
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(L.t.storage, style: theme.textTheme.titleSmall),
          ),
          ListTile(
            leading: Icon(Icons.drive_file_move_outlined),
            title: Text(L.t.downloadDir),
            subtitle: Text('${_dlDir['path'] ?? ''}',
                style: theme.textTheme.bodySmall),
            trailing: Icon(Icons.edit_outlined, size: 18),
            onTap: _editDownloadDir,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(L.t.downloadDirHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.bug_report_outlined),
            title: Text(L.t.exportLogs),
            subtitle: Text(L.t.exportLogsHint),
            onTap: _exportLogs,
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
            applicationVersion: '${_info['version'] ?? '0.5.10'}',
            aboutBoxChildren: [
              Text(
                '${L.t.aboutDesc}${L.t.aboutDesc2}'
                'App code: Unlicense\n'
                'Flutter (BSD-3-Clause) · Rust core & libtorrent (BSD-3-Clause)\n'
                'media_kit (MIT) · mpv/libmpv + FFmpeg (LGPL-2.1+, 动态链接)\n'
                'OpenSSL (Apache-2.0)',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String shortPk(String pk) => pk.length > 16 ? '${pk.substring(0, 16)}…' : pk;

Widget identityAvatar(Identity id) {
  if (id.avatarB64.isNotEmpty) {
    try {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(base64Decode(id.avatarB64),
            width: 48, height: 48, fit: BoxFit.cover),
      );
    } catch (_) {}
  }
  return KeyAvatar(keyHex: id.pk, name: id.name, size: 48);
}
