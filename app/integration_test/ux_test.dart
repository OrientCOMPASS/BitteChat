// On-device (emulator) verification of the RETAINED 0.5.x UX behaviours that
// host tests cannot see (real layout, real gestures, real l10n):
//
//   * v0.5.25 paper-tape list: opening a conversation lands EXACTLY on the
//     newest message (offset 0 of the reverse list), no settle loop;
//   * v0.5.22 left-swipe arms the quote-reply preview (halved trigger
//     distance), cancel affordance clears it again;
//   * v0.5.17 quote-reply via the long-press popup: sending renders the
//     quote card; tapping the card jumps to the quoted original;
//   * v0.5.19 in-memory drafts: text survives leave/re-enter;
//   * v0.5.9/v0.5.10 long-press floating action card (not a bottom sheet);
//   * v0.5.10 language switch (zh/en) rebuilds the whole app;
//   * v0.5.16 self-published seed (kind 4) visible in the DEFAULT Torrents
//     list (own scope) — the UI face of in-place seeding.
//
// Run: flutter test integration_test/ux_test.dart -d <device>

import 'dart:io';

import 'package:bittechat/core/api.dart';
import 'package:bittechat/core/prefs.dart';
import 'package:bittechat/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'retained 0.5.x UX: tape entry, swipe-quote, draft, popup, i18n, bt scope',
      (tester) async {
    await BitteApi.init();
    final api = BitteApi.instance;
    expect(api.available, isTrue);

    // room + history (headless, real engine)
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final seed = File('${api.dataDir}/AttUx$stamp.bin');
    await seed.writeAsString('ux room seed $stamp');
    final ih =
        (api.call('bt.create_seed', {'path': seed.path}))['infohash'] as String;
    final gid = (api.joinGroup(ih))['group_id'] as String;
    for (var i = 0; i < 40; i++) {
      api.sendText(gid, 'ux $i');
    }

    await tester.pumpWidget(RepaintBoundary(
        child: BitteChatApp(
            prefs: UiPrefs(File('${api.dataDir}/ui_prefs_ux_it.json')))));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('AttUx').first);
    await tester.pumpAndSettle();
    final input = find.byType(TextField).last;

    // --- v0.5.25: entry lands exactly on the newest message ---------------
    expect(find.text('ux 39'), findsOneWidget,
        reason: 'paper-tape entry must show the newest message without scroll');
    expect(find.text('ux 0'), findsNothing,
        reason: 'oldest message must be off-screen at entry');

    // --- v0.5.19: draft survives leave/re-enter ---------------------------
    await tester.enterText(input, 'draft survives');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('AttUx').first);
    await tester.pumpAndSettle();
    expect(find.text('draft survives'), findsOneWidget,
        reason: 'in-memory draft must restore on re-enter');
    // the harness TextInput connection goes stale across leave/re-enter;
    // drive the page-owned controller directly from here on
    void setInput(String v) {
      (tester.widget(input) as TextField).controller!.text = v;
    }

    setInput('');
    await tester.pumpAndSettle();

    // --- scroll to the TOP of the tape (oldest window) --------------------
    // drop IME focus first (a focused field keeps the viewport shifted)
    await tester.tapAt(tester.getCenter(find.byType(ListView).first));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, 1500));
      await tester.pumpAndSettle();
    }
    expect(find.text('ux 0'), findsOneWidget,
        reason: 'staged scroll must reach the oldest window; visible: '
            '${find.textContaining('ux ').evaluate().map((e) => (e.widget as Text).data).toList()}');

    // --- v0.5.22: left swipe arms the reply preview, cancel clears it -----
    // gesture below the bubble text (timestamp strip): SelectionArea owns
    // the text span and would enter the arena for drags started on it
    final r4 = tester.getRect(find.text('ux 4'));
    final swipe = await tester.startGesture(
        Offset(r4.center.dx, r4.bottom + 10));
    for (var i = 0; i < 6; i++) {
      await swipe.moveBy(const Offset(-10, 0));
      await tester.pump();
    }
    await swipe.up();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsOneWidget,
        reason: 'swipe past the -35px trigger must arm the reply preview');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsNothing);

    // --- v0.5.9/10 popup + v0.5.17 quote via its reply action -------------
    await tester.longPress(find.text('ux 2'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fingerprint), findsOneWidget,
        reason: 'long-press must float the action card (not a sheet)');
    await tester.tap(find.byIcon(Icons.reply));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsOneWidget,
        reason: 'popup reply action must arm the quote preview');
    setInput('reply with quote');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    // dismissed the popup earlier; ensure it is gone now too
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fingerprint), findsNothing);

    // send-side proof first: the quoted reply must exist in the store
    expect(
        api.chatMessages(gid).any((m) => m.text == 'reply with quote'), isTrue,
        reason: 'quoted reply must be stored (send side); '
            'input now: '
            '${(tester.widget(input) as TextField).controller?.text}, '
            'snackbars: ${find.byType(SnackBar).evaluate().length}');

    // --- back to the bottom: the quote card is the only 'ux 2' in view ----
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -1500));
      await tester.pumpAndSettle();
    }
    expect(find.text('reply with quote'), findsOneWidget,
        reason: 'quoted reply bubble must be reachable at the tape head; '
            'visible: '
            '${find.textContaining('ux ').evaluate().map((e) => (e.widget as Text).data).toList()}');
    expect(find.text('ux 2'), findsOneWidget,
        reason: 'quote card renders the quoted text; original is off-screen');
    // tapping the card jumps to the quoted original (neighbours appear)
    await tester.tap(find.text('ux 2'));
    await tester.pumpAndSettle();
    expect(find.text('ux 1'), findsOneWidget,
        reason: 'quote tap must land on the quoted original');

    // --- v0.5.16: own in-place seed in the DEFAULT Torrents list ----------
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Torrents'));
    await tester.pumpAndSettle();
    expect(find.textContaining('AttUx$stamp'), findsWidgets,
        reason: 'kind-4 self seed must appear in the default BT scope');

    // --- v0.5.10: language switch rebuilds the app ------------------------
    // settings lives in the ChatTab app bar (person icon, tooltip Identity)
    await tester.tap(find.text('Chats'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simplified Chinese'));
    await tester.pumpAndSettle();
    expect(find.text('语言'), findsOneWidget,
        reason: 'zh locale must rebuild the settings page in place');
    // and back to en (we are still on the settings page, now in zh)
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsOneWidget);
  },
      timeout: const Timeout(Duration(minutes: 6)));
}
