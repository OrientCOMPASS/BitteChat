// 默认 Tracker 列表编辑器（共享组件）：种子页与设置迁移后由此入口打开。

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/l10n.dart';

/// Opens the default-tracker list editor dialog. Returns after the dialog
/// closes; [onSaved] fires when a new list was applied.
Future<void> showDefaultTrackersEditor(BuildContext context,
    {VoidCallback? onSaved}) async {
  final api = BitteApi.instance;
  List<String> current = [];
  try {
    current = api.defaultTrackers();
  } catch (_) {}
  final controller = TextEditingController(text: current.join('\n'));
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(L.t.defaultTrackers),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L.t.defaultTrackersHint,
                style: Theme.of(ctx)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(ctx).colorScheme.outline)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 8,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText:
                    'udp://tracker.opentrackr.org:1337/announce\nhttps://tracker.example.org/announce',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
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
  final text = controller.text;
  controller.dispose();
  if (saved != true || !context.mounted) return;
  final urls =
      text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  try {
    final r = api.setDefaultTrackers(urls);
    onSaved?.call();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(L.t.trackersApplied((r['applied_to'] as int?) ?? 0))));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
