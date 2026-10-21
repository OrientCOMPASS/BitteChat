// Shared in-test screenshot + CI pull-sentinel helpers (emulator suite).
//
// The flutter test runner uninstalls the app (wiping its data dir) the
// moment the whole invocation returns, so screenshots must be written into
// the app data dir DURING the run and pulled concurrently by
// scripts/emu-run-and-pull.sh; the last test file holds the process until
// the script drops the `pull-done` sentinel.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:bittechat/core/api.dart';
import 'package:bittechat/main.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Render the live widget tree (the RepaintBoundary ancestor of
/// BitteChatApp) to a PNG inside the app data dir and log one line per step
/// into shot-log.txt for forensics.
Future<void> shotWidget(WidgetTester tester, String name) async {
  final log = File('${BitteApi.instance.dataDir}/shot-log.txt');
  Future<void> note(String s) async {
    try {
      await log.writeAsString('$name: $s\n', mode: FileMode.append);
    } catch (_) {}
  }

  try {
    await tester.pump();
    final ctx = find.byType(BitteChatApp).evaluate().first;
    final boundary =
        ctx.findAncestorRenderObjectOfType<RenderRepaintBoundary>();
    if (boundary == null) {
      await note('no RenderRepaintBoundary ancestor');
      return;
    }
    final image = await boundary.toImage();
    await note('raster ${image.width}x${image.height}');
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      await note('toByteData returned null');
      return;
    }
    final f = File('${BitteApi.instance.dataDir}/$name.png');
    await f.writeAsBytes(data.buffer.asUint8List());
    await note('wrote ${f.path} (${data.lengthInBytes} B)');
  } catch (e) {
    await note('error: $e');
  }
}

/// Hold the test process (and thus the installed app + its files) until the
/// CI pull script drops its sentinel (<=90 s).
Future<void> waitForPullSentinel() async {
  final sentinel = File('${BitteApi.instance.dataDir}/pull-done');
  for (var i = 0; i < 180; i++) {
    if (sentinel.existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}
