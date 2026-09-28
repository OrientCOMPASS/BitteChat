// On-device (emulator or real) end-to-end test against the REAL libtorrent
// engine and the REAL DHT: boots the core, creates a group, sends a message
// and waits for the BEP44 put confirmation, then verifies the UI renders on
// top of the live core.
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
    'real libtorrent core: group + message + DHT confirmation + UI',
    (tester) async {
      await BitteApi.init();
      final api = BitteApi.instance;

      // the native library must load on-device
      expect(api.available, isTrue,
          reason:
              'libbitte_core.so failed to load: ${BitteBridge.lastOpenError}');
      final info = api.sysInfo();
      expect(info['engine'], 'libtorrent');

      // full chat pipeline: create group -> send -> DHT immutable put confirm
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final groupName = 'Emulator IT $stamp';
      final created = api.createGroup(groupName);
      final gid = created['group_id'] as String;
      expect(gid.length, 40);
      expect(
        (created['invite_magnet'] as String).startsWith('magnet:?xt=urn:btih:'),
        isTrue,
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

      // UI renders on top of the live core
      final prefs =
          UiPrefs(File('${BitteApi.instance.dataDir}/ui_prefs_it.json'));
      await tester.pumpWidget(BitteChatApp(prefs: prefs));
      await tester.pumpAndSettle();
      // locale-independent: the nav bar exists with three destinations
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      // the freshly created group shows up in the chat list
      expect(find.textContaining('Emulator IT'), findsWidgets);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
