// 过滤脚本编辑器：规则集的 JSON 文本视图 —— 直接编辑 / 从文件导入 / 导出到
// 文件。为"LLM 生成过滤脚本"的工作流准备（路线图项）：把 LLM 输出的 JSON
// 粘贴或导入即可生效。
//
// 脚本格式（与 filter.set_rules API 一致的规则数组）：
// [
//   {"id":1,"enabled":true,"field":"author_name","mode":"contains",
//    "value":"广告","case_sensitive":false},
//   {"id":2,"enabled":true,"field":"text","mode":"regex",
//    "value":"(加微信|QQ群)","case_sensitive":false}
// ]
// field: author_name | author_pk | text
// mode:  contains | equals | regex

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/applog.dart';
import '../core/l10n.dart';
import '../models.dart';

class FilterScriptPage extends StatefulWidget {
  const FilterScriptPage({super.key});

  @override
  State<FilterScriptPage> createState() => _FilterScriptPageState();
}

class _FilterScriptPageState extends State<FilterScriptPage> {
  late final BitteApi _api = BitteApi.instance;
  late final TextEditingController _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: _dump());
  }

  String _dump() {
    try {
      const enc = JsonEncoder.withIndent('  ');
      return enc.convert(_api.filterRules().map((r) => r.toJson()).toList());
    } catch (_) {
      return '[]';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _apply() {
    try {
      final decoded = jsonDecode(_text.text);
      if (decoded is! List) {
        throw const FormatException('top level must be a list');
      }
      final rules = decoded
          .map((e) => FilterRule.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      _api.setFilterRules(rules);
      appLog('filter script applied: ${rules.length} rules');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L.t.filterScriptApplied(rules.length))));
        Navigator.pop(context, true);
      }
    } catch (e) {
      setState(() => _error = '${L.t.filterScriptInvalid}: $e');
    }
  }

  Future<void> _import() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt', 'bcfilter'],
      );
      if (files.isEmpty) return;
      final p = files.single.path;
      if (p == null) {
        return;
      }
      final content = await File(p).readAsString();
      jsonDecode(content); // validate before touching the editor
      setState(() {
        _text.text = content;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '${L.t.filterScriptInvalid}: $e');
    }
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      jsonDecode(_text.text); // only export valid scripts
      final name =
          'bittechat-filter-${DateTime.now().millisecondsSinceEpoch}.json';
      final tmp = File('${_api.dataDir}/tmp/$name');
      await tmp.parent.create(recursive: true);
      await tmp.writeAsString(_text.text);
      final dest = await exportFileToDownloads(tmp.path, name);
      messenger.showSnackBar(SnackBar(content: Text(L.t.logsExported(dest))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t.filterScript),
        actions: [
          IconButton(
              tooltip: L.t.importFile,
              icon: const Icon(Icons.file_open_outlined),
              onPressed: _import),
          IconButton(
              tooltip: L.t.exportFile,
              icon: const Icon(Icons.save_alt),
              onPressed: _export),
          TextButton.icon(
            icon: const Icon(Icons.check, size: 18),
            label: Text(L.t.filterScriptApply),
            onPressed: _apply,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(L.t.filterScriptHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _text,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
