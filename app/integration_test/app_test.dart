// On-device (emulator or real) end-to-end test against the REAL libtorrent
// engine and the REAL DHT: boots the core, creates + seeds a real torrent,
// enters its chat room by BARE INFOHASH (a torrent IS a room), sends a
// message and waits for the BEP44 put confirmation, exercises the tracker
// settings against the live session, then verifies the UI renders on top of
// the live core.
//
// Run: flutter test integration_test/app_test.dart -d <device>

import 'dart:io';

import 'package:bittechat/core/api.dart';
import 'package:bittechat/core/bridge.dart';
import 'package:bittechat/core/prefs.dart';
import 'package:bittechat/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real libtorrent core: torrent room + message + DHT confirmation + UI',
    (tester) async {
      await BitteApi.init();
      final api = BitteApi.instance;

      // the native library must load on-device
      expect(api.available, isTrue,
          reason:
              'libbitte_core.so failed to load: ${BitteBridge.lastOpenError}');
      final info = api.sysInfo();
      expect(info['engine'], 'libtorrent');

      // create + seed a real torrent: its infohash IS the chat room id
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final f = File('${api.dataDir}/EmulatorIT$stamp.bin');
      await f.writeAsString('integration payload $stamp');
      final seeded = api.call('bt.create_seed', {'path': f.path});
      final ih = seeded['infohash'] as String;
      expect(ih.length, 40);
      expect((seeded['magnet'] as String).startsWith('magnet:?xt=urn:btih:'),
          isTrue);

      // enter the room with a BARE INFOHASH (hash-only input support)
      final room = api.joinGroup(ih);
      final gid = room['group_id'] as String;
      expect(gid, ih);

      // default trackers apply to the live torrent through the C++ ABI
      api.setDefaultTrackers(['udp://tracker.opentrackr.org:1337/announce']);
      final tr = api.call('bt.trackers', {'infohash': ih});
      expect(
        ((tr['trackers'] as List?) ?? [])
            .any((t) => '${t['url']}'.contains('opentrackr')),
        isTrue,
        reason: 'default tracker must be registered on the live session',
      );

      api.sendText(gid, 'integration hello');

      final deadline = DateTime.now().add(const Duration(seconds: 120));
      var confirmed = false;
      while (DateTime.now().isBefore(deadline)) {
        final msgs = api.chatMessages(gid);
        confirmed =
            msgs.any((m) => m.text == 'integration hello' && m.state == 1);
        if (confirmed) break;
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      expect(confirmed, isTrue,
          reason: 'sent message must reach DHT-confirmed state');

      // the torrent stays a regular BT task with the room bound to it
      final torrents = api.torrents();
      expect(
        torrents.any((t) => t.infohash == ih && t.groupId == ih),
        isTrue,
        reason: 'room torrent must stay visible on the BT page',
      );

      // UI renders on top of the live core
      final prefs =
          UiPrefs(File('${BitteApi.instance.dataDir}/ui_prefs_it.json'));
      await tester.pumpWidget(BitteChatApp(prefs: prefs));
      await tester.pumpAndSettle();
      // locale-independent: the nav bar exists with three destinations
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      // the freshly entered room shows up in the chat list (named after the
      // torrent, i.e. the seeded file)
      expect(find.textContaining('EmulatorIT'), findsWidgets);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
