// On-device (emulator) verification of the VueTorrent-style torrent detail
// page (BtViewPage: piece bar, Overview groups, Files tree, Peers table,
// qBittorrent trackers), the per-tab settings redistribution (BT settings
// sheet with the global tracker list dialog, RSS settings dialog) and the
// qBittorrent-style BT list UX. Screenshots of THIS round's features are
// pulled concurrently by scripts/emu-run-and-pull.sh.
//
// Run: flutter test integration_test/bt_view_test.dart -d <device>

import 'dart:io';

import 'package:bittechat/core/api.dart';
import 'package:bittechat/core/prefs.dart';
import 'package:bittechat/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'shot_util.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bt detail page + per-tab settings: tree, peers table, tracker list',
    (tester) async {
      await BitteApi.init();
      final api = BitteApi.instance;
      expect(api.available, isTrue,
          reason: 'libbitte_core.so failed to load on device');

      // one finished (seeding) torrent to open the detail page on
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final f = File('${api.dataDir}/BtView$stamp.bin');
      await f.writeAsString('detail seed $stamp');
      final seeded = api.call('bt.create_seed', {'path': f.path});
      final name = seeded['name'] as String;
      final ih = seeded['infohash'] as String;

      final prefs = UiPrefs(File('${api.dataDir}/ui_prefs_btview_it.json'));
      await tester
          .pumpWidget(RepaintBoundary(child: BitteChatApp(prefs: prefs)));
      await tester.pumpAndSettle();

      // BT tab: qBit-style chips + bottom status bar, then the BT settings
      // sheet (settings live in their own tab now)
      await tester.tap(find.byIcon(Icons.cloud_download_outlined));
      await tester.pumpAndSettle();
      expect(find.textContaining('All ('), findsOneWidget);
      expect(find.byIcon(Icons.public), findsOneWidget);
      await shotWidget(tester, 'shot-bt-tab-ux');
      await tester.tap(find.byKey(const ValueKey('bt-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('btset-dir')), findsOneWidget);
      expect(find.byKey(const ValueKey('btset-tracker-list')), findsOneWidget);
      await shotWidget(tester, 'shot-bt-settings');
      await tester.tap(find.byKey(const ValueKey('btset-tracker-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trklist-enable')), findsOneWidget);
      await shotWidget(tester, 'shot-tracker-list');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // tap the task row -> animated detail route
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
      for (final tab in ['Overview', 'Files', 'Peers', 'Trackers']) {
        expect(
          find.descendant(of: find.byType(TabBar), matching: find.text(tab)),
          findsOneWidget,
          reason: 'tab $tab missing',
        );
      }
      expect(find.byKey(const ValueKey('btdetail-pieces')), findsOneWidget);
      final bar = tester.getRect(find.byKey(const ValueKey('btdetail-pieces')));
      await tester.tapAt(bar.center);
      await tester.pumpAndSettle();
      expect(find.textContaining('downloaded'), findsWidgets);
      expect(find.text(ih), findsOneWidget);
      await shotWidget(tester, 'shot-bt-detail-overview');

      // Files tab: VueTorrent-Content-style tree (root row, checkbox,
      // search field, priority menu)
      await tester.tap(find.descendant(
          of: find.byType(TabBar), matching: find.text('Files')));
      await tester.pumpAndSettle();
      expect(find.text('(root)'), findsOneWidget);
      expect(find.byKey(const ValueKey('btfiles-search')), findsOneWidget);
      expect(find.byKey(const ValueKey('btfile-check-0')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('btfile-prio-0')));
      await tester.pumpAndSettle();
      expect(find.text('High priority'), findsOneWidget);
      await tester.tap(find.text('High priority'));
      await tester.pumpAndSettle();
      await shotWidget(tester, 'shot-bt-detail-files');

      // Peers tab: sortable table header + search (empty swarm on emulator)
      await tester.tap(find.descendant(
          of: find.byType(TabBar), matching: find.text('Peers')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('btpeers-search')), findsOneWidget);
      await shotWidget(tester, 'shot-bt-detail-peers');

      // Trackers tab: qBit-style add + reannounce + edit menu
      await tester.tap(find.descendant(
          of: find.byType(TabBar), matching: find.text('Trackers')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bttracker-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'udp://tracker.opentrackr.org:1337/announce',
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.textContaining('opentrackr'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bttracker-menu-0')));
      await tester.pumpAndSettle();
      expect(find.text('Force reannounce'), findsOneWidget);
      expect(find.text('Edit tracker URL'), findsOneWidget);
      await tester.tap(find.text('Force reannounce'));
      await tester.pumpAndSettle();
      await shotWidget(tester, 'shot-bt-detail-trackers');

      // RSS tab settings live in the RSS tab
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.rss_feed_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rss-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Manual only'), findsOneWidget);
      await shotWidget(tester, 'shot-rss-settings');
      await tester.tap(find.text('30 minutes'));
      await tester.pumpAndSettle();

      // chat tab exposes the filter rules entry (chat settings in chat tab)
      await tester.tap(find.byIcon(Icons.chat_bubble_outline));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-filter-rules')), findsOneWidget);

      // hold the install alive until CI pulled the screenshots
      await waitForPullSentinel();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
