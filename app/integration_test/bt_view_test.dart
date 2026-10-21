// On-device (emulator) verification of the VueTorrent-style torrent detail
// page (BtViewPage: piece bar, Overview groups, Files tree, Peers table,
// qBittorrent trackers), the per-tab settings redistribution (BT settings
// sheet with the global tracker list dialog, RSS settings dialog) and the
// qBittorrent-style BT list UX. Screenshots of THIS round's features are
// pulled concurrently by scripts/emu-run-and-pull.sh.
//
// The detail page is exercised on a REAL dual-instance swarm: the CI host
// seeds the embedded torrent below with aria2 behind
// scripts/swarm/mini_tracker.py, reachable from the emulator through
// 10.0.2.2 (qemu's alias for the host loopback). The Peers tab therefore
// shows a live second BitTorrent client (real peer connection, real piece
// payload) instead of an empty swarm, and the Trackers tab shows a tracker
// that really announced + scraped.
//
// Run: flutter test integration_test/bt_view_test.dart -d <device>

import 'dart:convert';
import 'dart:io';

import 'package:bittechat/core/api.dart';
import 'package:bittechat/core/prefs.dart';
import 'package:bittechat/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'shot_util.dart';
import 'swarm_torrent.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bt detail page + per-tab settings: tree, peers table, tracker list',
    (tester) async {
      await BitteApi.init();
      final api = BitteApi.instance;
      expect(api.available, isTrue,
          reason: 'libbitte_core.so failed to load on device');

      // Real dual-instance swarm instead of a lone local seed: the CI host
      // seeds this exact torrent (aria2) behind a mini BEP-3 tracker, so the
      // emulator's libtorrent instance meets a REAL second client and the
      // Peers tab below has a live row to show.
      final added = api.btAddFile(base64Decode(kSwarmTorrentB64.join()),
          name: kSwarmName);
      final ih = (added['infohash'] as String?) ?? '';
      expect(ih, kSwarmInfohash,
          reason: 'embedded swarm torrent drifted from scripts/swarm');
      api.btAddTracker(ih, kSwarmTracker);

      // wait (<=150 s) for the host seeder to connect AND payload to flow;
      // this is the regression guard the mock-only e2e could never give us
      var peers = api.btPeers(ih);
      var prog = 0.0;
      for (var i = 0; i < 150 && (peers.isEmpty || prog <= 0); i++) {
        peers = api.btPeers(ih);
        for (final t in api.torrents()) {
          if (t.infohash == ih) prog = t.progress;
        }
        if (peers.isEmpty || prog <= 0) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      expect(peers, isNotEmpty,
          reason: 'dual-instance swarm: host seeder never connected '
              '(tracker/aria2 down on CI host?)');
      expect(prog, greaterThan(0),
          reason: 'dual-instance swarm: connected but no payload flowed');
      final name = kSwarmName;

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

      // Peers tab: sortable table header + search, now on a LIVE swarm
      await tester.tap(find.descendant(
          of: find.byType(TabBar), matching: find.text('Peers')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('btpeers-search')), findsOneWidget);
      // the host seeder's row must render (ip column shows 10.0.2.2:6881)
      var live = false;
      for (var i = 0; i < 40 && !live; i++) {
        live = find.textContaining('10.0.2.2').evaluate().isNotEmpty;
        if (!live) await tester.pump(const Duration(milliseconds: 500));
      }
      expect(live, isTrue, reason: 'Peers table shows no live host-seeder row');
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
      expect(find.textContaining('6969'), findsOneWidget,
          reason: 'swarm tracker row missing from Trackers tab');
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
    timeout: const Timeout(Duration(minutes: 9)),
  );
}
