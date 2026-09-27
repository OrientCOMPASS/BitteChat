// 纯 Dart 单元测试：模型解析、格式化、颜色稳定性（无需原生库）

import 'package:bittechat/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatMessage.fromJson', () {
    test('text payload', () {
      final m = ChatMessage.fromJson({
        'id': 'aa' * 20,
        'group': 'bb' * 20,
        'author_pk': 'cc' * 32,
        'author_name': 'alice',
        'ts': 1700000000000,
        'kind': 1,
        'own': false,
        'state': 1,
        'payload': {
          'Text': {'text': '你好'}
        },
      });
      expect(m.payloadKind, MsgPayloadKind.text);
      expect(m.text, '你好');
      expect(m.authorName, 'alice');
      expect(m.state, 1);
    });

    test('attachment payload', () {
      final m = ChatMessage.fromJson({
        'id': 'aa',
        'kind': 2,
        'payload': {
          'Attachment': {
            'infohash': 'dd' * 20,
            'name': 'ubuntu.iso',
            'size': 1234567,
            'mime': 'application/x-iso',
          }
        },
      });
      expect(m.payloadKind, MsgPayloadKind.attachment);
      expect(m.attachment?.name, 'ubuntu.iso');
      expect(m.attachment?.size, 1234567);
    });

    test('system payload', () {
      final m = ChatMessage.fromJson({
        'kind': 3,
        'payload': {
          'System': {'code': 'create', 'detail': '开发群'}
        },
      });
      expect(m.payloadKind, MsgPayloadKind.system);
      expect(m.systemCode, 'create');
      expect(m.systemDetail, '开发群');
    });

    test('missing fields do not crash', () {
      final m = ChatMessage.fromJson({});
      expect(m.payloadKind, MsgPayloadKind.unknown);
      expect(m.ts, 0);
      expect(m.id, '');
    });
  });

  group('GroupSummary.fromJson', () {
    test('with preview', () {
      final g = GroupSummary.fromJson({
        'group_id': 'ee' * 20,
        'name': '测试群',
        'unread': 3,
        'online': 2,
        'preview': {
          'author_name': 'bob',
          'text': '晚上好',
          'ts': 1700000000000,
          'own': false,
          'kind': 1,
        },
      });
      expect(g.name, '测试群');
      expect(g.unread, 3);
      expect(g.previewText, '晚上好');
      expect(g.syncing, false);
    });
  });

  group('TorrentInfo.fromJson', () {
    test('defaults', () {
      final t = TorrentInfo.fromJson({'infohash': 'ff', 'name': 'x'});
      expect(t.progress, 0.0);
      expect(t.kind, 0);
      expect(t.isChatInternal, false);
    });
    test('manifest kind', () {
      final t = TorrentInfo.fromJson({'kind': 1});
      expect(t.isChatInternal, true);
    });
  });

  group('RssItem.fromJson', () {
    test('parses flags', () {
      final i = RssItem.fromJson({
        'id': 5,
        'title': '新闻',
        'has_torrent': true,
        'has_download': true,
        'read': false,
        'ts': 1700000000000,
      });
      expect(i.hasTorrent, true);
      expect(i.read, false);
      expect(i.title, '新闻');
    });
  });

  group('helpers', () {
    test('formatBytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('formatSpeed', () {
      expect(formatSpeed(0), '0 B/s');
      expect(formatSpeed(1024), '1.0 KB/s');
    });

    test('colorFromKey is stable and in hue range', () {
      final c1 = colorFromKey('abcdef123456');
      final c2 = colorFromKey('abcdef123456');
      expect(c1, c2);
      expect(c1 >= 0 && c1 < 360, true);
    });
  });
}
