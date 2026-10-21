// Chat-side settings: message filter rules (moved out of the global
// settings page so chat settings live in the chat tab).

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/l10n.dart';
import '../models.dart';
import '../pages/home.dart';
import 'filter_script_page.dart';

class FilterRulesPage extends StatefulWidget {
  const FilterRulesPage({super.key});

  @override
  State<FilterRulesPage> createState() => _FilterRulesPageState();
}

class _FilterRulesPageState extends State<FilterRulesPage> {
  late final BitteApi _api = BitteApi.instance;
  List<FilterRule> _rules = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _rules = _api.filterRules());
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(L.t.filterRules)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                    child: Text(L.t.filterRules,
                        style: theme.textTheme.titleSmall)),
                TextButton.icon(
                  icon: const Icon(Icons.data_object, size: 18),
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
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(L.t.add),
                  onPressed: () => _editRule(null),
                ),
              ],
            ),
          ),
          if (_rules.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
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
        ],
      ),
    );
  }
}
