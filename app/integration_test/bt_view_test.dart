// On-device (emulator) verification of the VueTorrent-style dashboard
// (BtViewPage) against the REAL core: session stats header + sparkline,
// table/grid view modes, status filter chips and the multi-select bulk bar.
// Screenshots of THIS round's feature are captured in both view modes and
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
    'bt dashboard: stats header, table/grid, filters, bulk bar',
    (tester) async {
      await BitteApi.init();
      final api = BitteApi.instance;
      expect(api.available, isTrue,
          reason: 'libbitte_core.so failed to load on device');

      // one finished (seeding) torrent so the dashboard has content
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final f = File('${api.dataDir}/BtView$stamp.bin');
      await f.writeAsString('dashboard seed $stamp');
      final seeded = api.call('bt.create_seed', {'path': f.path});
      final name = seeded['name'] as String;

      final prefs = UiPrefs(File('${api.dataDir}/ui_prefs_btview_it.json'));
      await tester
          .pumpWidget(RepaintBoundary(child: BitteChatApp(prefs: prefs)));
      await tester.pumpAndSettle();

      // BT tab -> dashboard entry in the AppBar
      await tester.tap(find.byIcon(Icons.cloud_download_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bt-open-dashboard')));
      await tester.pumpAndSettle();

      // VueTorrent-style header: session speeds + sparkline + counts
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_downward), findsWidgets);
      expect(find.byIcon(Icons.arrow_upward), findsWidgets);
      // the seeded torrent shows up in table mode
      expect(find.text(name), findsOneWidget);
      // status filter chips are present with counts
      expect(find.textContaining('All ('), findsOneWidget);
      await shotWidget(tester, 'shot-bt-view-table');

      // switch to the card (grid) mode: property chips appear
      await tester.tap(find.byKey(const ValueKey('btview-mode')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.table_rows), findsOneWidget);
      expect(find.textContaining('P/'), findsWidgets);
      await shotWidget(tester, 'shot-bt-view-grid');

      // back to table, then filter: paused must hide the seeding torrent
      await tester.tap(find.byKey(const ValueKey('btview-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Paused ('));
      await tester.pumpAndSettle();
      expect(find.text(name), findsNothing);
      expect(find.textContaining('No matching tasks'), findsOneWidget);
      await tester.tap(find.textContaining('All ('));
      await tester.pumpAndSettle();
      expect(find.text(name), findsOneWidget);

      // long-press enters multi-select with the bulk action bar
      await tester.longPress(find.text(name));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byKey(const ValueKey('btview-clear-sel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('btview-clear-sel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('btview-clear-sel')), findsNothing);

      // hold the install alive until CI pulled the screenshots
      await waitForPullSentinel();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
