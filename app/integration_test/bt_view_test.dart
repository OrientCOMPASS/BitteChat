// On-device (emulator) verification of the VueTorrent-style torrent detail
// page (BtViewPage, opened by tapping a task in the BT tab): summary header,
// Overview property groups, Files/Peers/Trackers tabs and the pause/resume
// action. Screenshots of THIS round's feature (overview + files tab) are
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
    'bt detail page: overview groups, files/peers/trackers tabs, pause',
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

      // BT tab -> tap the task row -> detail page
      await tester.tap(find.byIcon(Icons.cloud_download_outlined));
      await tester.pumpAndSettle();
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
      // summary header shows the finished progress and speeds
      expect(find.textContaining('100.0%'), findsWidgets);
      // overview property groups: infohash row (tap-to-copy) and type tag
      expect(find.text(ih), findsOneWidget);
      expect(find.text('SEED'), findsOneWidget);
      expect(find.textContaining('Transfer'), findsOneWidget);
      await shotWidget(tester, 'shot-bt-detail-overview');

      // Files tab: single-file content list with per-file progress
      await tester.tap(find.descendant(
          of: find.byType(TabBar), matching: find.text('Files')));
      await tester.pumpAndSettle();
      // the AppBar title carries the same name; scope to the tab's list
      expect(
        find.descendant(of: find.byType(ListView), matching: find.text(name)),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      await shotWidget(tester, 'shot-bt-detail-files');

      // Trackers tab renders (empty hint or rows) and add entry exists
      await tester.tap(find.descendant(
          of: find.byType(TabBar), matching: find.text('Trackers')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.add), findsOneWidget);

      // pause/resume action round-trip
      await tester.tap(find.byKey(const ValueKey('btdetail-pause-resume')));
      await tester.pumpAndSettle();
      // engine state cache refreshes on its 2 s post_torrent_updates cycle
      await Future<void>.delayed(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(TabBar), matching: find.text('Overview')));
      await tester.pumpAndSettle();
      expect(find.text('Paused'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('btdetail-pause-resume')));
      await tester.pumpAndSettle();

      // hold the install alive until CI pulled the screenshots
      await waitForPullSentinel();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
