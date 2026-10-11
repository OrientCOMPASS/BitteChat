// On-device (emulator) verification of the v0.5.26/v0.5.27 attachment and
// jump-bottom behaviours against the REAL libtorrent core + REAL FFI event
// callback path (the part host tests cannot see):
//
//   1. `chat.attachment_progress` events actually reach Dart on Android
//      (the v0.5.26 "stuck hashing banner" device report),
//   2. the sender's own attachment resolves IN PLACE (have_file=true,
//      local_path == source) on the real engine,
//   3. the chat bubble renders it inline (no "Download via BT" card, no
//      hashing banner) — screenshot for the delivery checklist,
//   4. the jump-bottom chip follows the return-intent spec: hidden while
//      browsing history, visible after a slide toward the bottom, hidden
//      again at the bottom — screenshot included.
//
// Run: flutter test integration_test/attach_test.dart -d <device>

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bittechat/core/api.dart';
import 'package:bittechat/core/prefs.dart';
import 'package:bittechat/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 1x1 red PNG so the bubble must render an image thumbnail.
const String _kPngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42m'
    'P8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'sender attachment inline + jump-bottom return-intent spec',
    (tester) async {
      await BitteApi.init();
      final api = BitteApi.instance;
      expect(api.available, isTrue,
          reason: 'libbitte_core.so must load on-device for this test');

      // room = a real seeded torrent entered by bare infohash
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final seed = File('${api.dataDir}/AttRoom$stamp.bin');
      await seed.writeAsString('room seed $stamp');
      final seeded = api.call('bt.create_seed', {'path': seed.path});
      final ih = seeded['infohash'] as String;
      final gid = (api.joinGroup(ih))['group_id'] as String;
      expect(gid, ih);

      // history long enough to scroll (jump-bottom semantics below)
      for (var i = 0; i < 40; i++) {
        api.sendText(gid, 'fill $i');
      }

      // the attachment: a tiny valid PNG sent through the real worker path
      final png = File('${api.dataDir}/att$stamp.png');
      await png.writeAsBytes(base64.decode(_kPngB64));
      final phases = <String>[];
      final sub = api.events.listen((e) {
        if (e.type == 'chat.attachment_progress') {
          phases.add('${e.data['phase'] ?? ''}');
        }
      });
      final r = api.sendFile(gid, png.path, name: 'att$stamp.png');
      expect('${r['job_id'] ?? ''}', isNotEmpty,
          reason: 'send_file must return a job id');

      // 1) terminal progress event must reach Dart through the FFI callback
      var sent = false;
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0) < const Duration(seconds: 60)) {
        if (phases.contains('sent')) {
          sent = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(sent, isTrue,
          reason: 'attachment_progress sent event never reached Dart; '
              'phases seen: $phases');

      // 2) sender-side in-place resolution on the real engine
      final msgs = api.chatMessages(gid);
      expect(msgs.any((m) => m.attachment?.infohash != null), isTrue,
          reason: 'attachment message missing');
      final att = msgs.firstWhere((m) => m.attachment?.infohash != null);
      expect(att.haveFile, isTrue,
          reason: 'sender must report have_file for its own in-place seed');
      expect(att.localPath, png.path,
          reason: 'local_path must be the in-place source file');
      await sub.cancel();

      // 3) UI: open the room from the chat list
      final prefs =
          UiPrefs(File('${api.dataDir}/ui_prefs_attach_it.json'));
      await tester.pumpWidget(
          RepaintBoundary(child: BitteChatApp(prefs: prefs)));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('AttRoom').first);
      await tester.pumpAndSettle();

      // inline image, no BT-download card, no hashing banner
      expect(find.text('Download via BT'), findsNothing);
      expect(find.textContaining('Hashing file'), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image is FileImage),
        findsWidgets,
        reason: 'the bubble must render the local picture',
      );
      // at the bottom the jump chip is hidden
      expect(find.byIcon(Icons.keyboard_double_arrow_down), findsNothing);
      await _shot(tester, 'shot-chat-inline');

      // 4) jump-bottom semantics on the reverse (paper-tape) list
      final list = find.byType(ListView).first;
      // browse history (finger down): chip must NOT appear
      await tester.drag(list, const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.keyboard_double_arrow_down), findsNothing,
          reason: 'browsing history must not raise the chip');
      // slide toward the bottom (finger up), stopping short of it: chip up
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.keyboard_double_arrow_down), findsOneWidget,
          reason: 'a return-to-bottom slide must raise the chip');
      await _shot(tester, 'shot-jump-chip');
      // ...and back to the bottom: chip gone again
      await tester.drag(list, const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.keyboard_double_arrow_down), findsNothing,
          reason: 'at the bottom the chip must hide');
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

/// Render the live widget tree to a PNG inside the app's external files
/// dir; CI adb-pulls /storage/emulated/0/Android/data/*/files/shot-*.png
/// (the test framework force-stops the app afterwards, so host-side
/// screencaps only ever catch the launcher).
Future<void> _shot(WidgetTester tester, String name) async {
  try {
    await tester.pump();
    final ctx = find.byType(BitteChatApp).evaluate().first;
    final boundary =
        ctx.findAncestorRenderObjectOfType<RenderRepaintBoundary>();
    if (boundary == null) return;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    await File('${BitteApi.instance.dataDir}/$name.png')
        .writeAsBytes(data.buffer.asUint8List());
  } catch (_) {
    // screenshots are a verification aid, never a test failure
  }
}
