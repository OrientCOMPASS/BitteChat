// On-device (emulator) verification of the VueTorrent-style torrent detail
// page (BtViewPage, opened by tapping a task in the BT tab): piece-level
// progress bar with probe tooltip, Overview property groups, Files tab with
// sort + per-file priority actions, qBittorrent-style Trackers tab (add +
// force reannounce). Screenshots of THIS round's feature (overview / files /
// trackers) are pulled concurrently by scripts/emu-run-and-pull.sh.
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
    'bt detail page: piece bar probe, files sort/priority, trackers mgmt',
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

      // BT tab -> qBittorrent-style list UX: status filter chips with
      // counts and the session stats bar docked at the bottom
      await tester.tap(find.byIcon(Icons.cloud_download_outlined));
      await tester.pumpAndSettle();
      expect(find.textContaining('All ('), findsOneWidget);
      expect(find.byIcon(Icons.public), findsOneWidget);
      await shotWidget(tester, 'shot-bt-tab-ux');
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();

      // VueTorrent-style tab bar
      for (final tab in ['Overview', 'Files', 'Peers', 'Trackers']) {
        expect(
          find.descendant(of: find.byType(TabBar), matching: find.text(tab)),
          findsOneWidget,
          reason: 'tab $tab missing',
        );
      }
      // piece-level progress bar + probe tooltip (finished seed => all done)
      expect(find.byKey(const ValueKey('btdetail-pieces')), findsOneWidget);
      final bar = tester.getRect(find.byKey(const ValueKey('btdetail-pieces')));
      await tester.tapAt(bar.center);
      await tester.pumpAndSettle();
      expect(find.textContaining('downloaded'), findsWidgets);
      expect(find.text(ih), findsOneWidget);
      expect(find.text('BT'), findsOneWidget);
      await shotWidget(tester, 'shot-bt-detail-overview');

      // Files tab: sort controls + per-file priority action
      await tester.tap(find.descendant(
          of: find.byType(TabBar), matching: find.text('Files')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('btfiles-sort')), findsOneWidget);
      expect(find.byKey(const ValueKey('btfiles-asc')), findsOneWidget);
      expect(
        find.descendant(of: find.byType(ListView), matching: find.text(name)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('btfile-prio-0')));
      await tester.pumpAndSettle();
      expect(find.text('High priority'), findsOneWidget);
      await tester.tap(find.text('High priority'));
      await tester.pumpAndSettle();
      await shotWidget(tester, 'shot-bt-detail-files');

      // Trackers tab (qBittorrent-style): add, then force reannounce
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
      // edit dialog opens prefilled and cancels cleanly
      await tester.tap(find.byKey(const ValueKey('bttracker-menu-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit tracker URL'));
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await shotWidget(tester, 'shot-bt-detail-trackers');

      // settings: qBittorrent-style global tracker list dialog
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chat_bubble_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.person_outline));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('settings-tracker-list')), 300);
      await tester.tap(find.byKey(const ValueKey('settings-tracker-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trklist-enable')), findsOneWidget);
      expect(find.byKey(const ValueKey('trklist-url')), findsOneWidget);
      await shotWidget(tester, 'shot-tracker-list');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // hold the install alive until CI pulled the screenshots
      await waitForPullSentinel();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
