// On-device (emulator) REAL-VIDEO pipeline test.
//
// Regression guard for the "decoded but black picture" class of failures:
// the workflow ffmpeg-generates a real H.264+AAC mp4 and adb-pushes it to
// /data/local/tmp/ci_video.mp4, then this test drives our actual
// VideoPlayerPage (media_kit/mpv) and asserts on the player's observable
// state instead of pixels:
//
//   1. REAL video parameters arrive (w:640 h:360 — the 960x540 rgba entry
//      is only the controller's initialization placeholder)
//   2. the playback clock advances (frames are actually being consumed)
//   3. the rung the player SETTLED on is free of renderer-stall signatures
//      (aimagereader timeouts / -30001 — the on-device black-screen
//      fingerprint). Earlier rungs may legitimately stall: that is exactly
//      what the decode ladder exists to recover from, so only the active
//      rung is asserted on (and any downgrade is reported in the failure
//      message).
//   4. no error events at all
//
// Run: flutter test integration_test/video_test.dart -d emulator-5554

import 'dart:io';

import 'package:bittechat/pages/media_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

const String kCiVideoPath = '/data/local/tmp/ci_video.mp4';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real video plays: params + advancing clock + clean mpv log',
      (tester) async {
    MediaKit.ensureInitialized();
    expect(File(kCiVideoPath).existsSync(), isTrue,
        reason: 'the workflow must generate and adb push $kCiVideoPath');

    await tester.pumpWidget(MaterialApp(
      home: const VideoPlayerPage(path: kCiVideoPath, title: 'ci_video'),
    ));
    await tester.pump();

    // helper: run real async waiting (integration_test pauses fake time
    // outside runAsync)
    Future<void> realWait(bool Function() cond,
        {Duration timeout = const Duration(seconds: 45)}) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (cond()) return;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }

    await tester.runAsync(() async {
      // 1) real video parameters (640x360 testsrc2) replace the placeholder
      await realWait(() {
        final p = VideoPlayerPage.debugLastVideoParams ?? '';
        return p.contains('w: 640') && p.contains('h: 360');
      });
      final params = VideoPlayerPage.debugLastVideoParams ?? '';
      expect(params, contains('w: 640'),
          reason: 'decoder must report the real video geometry; '
              'mpv log so far:\n${VideoPlayerPage.debugMpvLogs.join('\n')}');

      // 2) the clock advances — frames are being consumed by the renderer
      await realWait(
          () => VideoPlayerPage.debugLastPosition > const Duration(seconds: 1),
          timeout: const Duration(seconds: 60));
      expect(VideoPlayerPage.debugLastPosition,
          greaterThan(const Duration(seconds: 1)),
          reason: 'playback position must advance; '
              'mpv log so far:\n${VideoPlayerPage.debugMpvLogs.join('\n')}');
    });

    await tester.pump();

    // 3) the ACTIVE decode rung must be free of the stall fingerprint; a
    //    stall on a rung we already abandoned is the ladder doing its job
    expect(VideoPlayerPage.debugActiveTierStalls, isEmpty,
        reason: 'the settled decoder (tier '
            '${VideoPlayerPage.debugActiveTier}, '
            '${VideoPlayerPage.debugDowngrades} downgrade(s)) still stalls:\n'
            '${VideoPlayerPage.debugActiveTierStalls.join('\n')}');

    final stall = VideoPlayerPage.debugMpvLogs
        .where((l) =>
            l.contains('aimagereader') ||
            l.contains('-30001') ||
            l.contains('Waiting for frame timed out'))
        .toList();
    if (stall.isNotEmpty) {
      // not a failure, but CI must show that the ladder had to kick in
      debugPrint('video test: ${stall.length} stall line(s) before settling on '
          'tier ${VideoPlayerPage.debugActiveTier}');
    }

    // 4) no errors surfaced
    expect(VideoPlayerPage.debugLastError, isNull);
    expect(find.textContaining('无法播放'), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
