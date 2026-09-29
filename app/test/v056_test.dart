// Unit tests for the pure logic added in v0.5.6: log trimming, wallpaper
// padding fill, decode-ladder stall detection and the framing geometry.
// These run under `flutter test` in CI (app-analyze) with no device needed.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bittechat/core/applog.dart';
import 'package:bittechat/core/imgfx.dart';
import 'package:bittechat/core/video_decode.dart';
import 'package:bittechat/pages/wallpaper_edit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a [PixelBuffer] whose centre [inset] box is opaque white and the
/// surrounding margin is fully transparent — the shape a framed wallpaper
/// capture has.
PixelBuffer canvasWithHole(
    {int w = 12,
    int h = 10,
    int inset = 3,
    int r = 200,
    int g = 100,
    int b = 50}) {
  final p = PixelBuffer(w, h, Uint8List(w * h * 4));
  for (var y = inset; y < h - inset; y++) {
    for (var x = inset; x < w - inset; x++) {
      p.setPixel(y * w + x, r, g, b, 255);
    }
  }
  return p;
}

void main() {
  group('trimFrontHalf (app.log 64KiB policy)', () {
    test('keeps the newer half by line count and marks the trim', () {
      final text = '${List.generate(10, (i) => 'line $i').join('\n')}\n';
      final out = trimFrontHalf(text, marker: 'app.log');
      final lines = out.split('\n')..removeLast();
      expect(lines.first, '[app.log trimmed: 5 older lines dropped]');
      expect(lines, contains('line 5'));
      expect(lines, contains('line 9'));
      expect(lines, isNot(contains('line 4')));
      expect(lines.length, 6); // marker + 5 kept lines
    });

    test('odd line counts drop the smaller half', () {
      final text = '${List.generate(7, (i) => 'l$i').join('\n')}\n';
      final out = trimFrontHalf(text, marker: 'app.log');
      expect(out, contains('[app.log trimmed: 3 older lines dropped]'));
      expect(out, contains('l3'));
      expect(out, contains('l6'));
      expect(out, isNot(contains('l2\n')));
    });

    test('a repeated trim folds the previous marker instead of stacking', () {
      var text = '${List.generate(8, (i) => 'x$i').join('\n')}\n';
      text = trimFrontHalf(text, marker: 'app.log');
      // grow again, then trim once more
      text = '$text${List.generate(8, (i) => 'y$i').join('\n')}\n';
      final out = trimFrontHalf(text, marker: 'app.log');
      expect('[app.log trimmed:'.allMatches(out).length, 1,
          reason: 'markers must not accumulate: $out');
      expect(out, contains('y7'));
      expect(out, isNot(contains('x0\n')));
    });

    test('degenerate input is returned untouched', () {
      expect(trimFrontHalf('', marker: 'app.log'), '');
      expect(trimFrontHalf('only\n', marker: 'app.log'), 'only\n');
      expect(trimFrontHalf('a\nb\n', marker: 'app.log'),
          contains('[app.log trimmed: 1 older lines dropped]'));
    });

    test('trailing line without newline still counts as a line', () {
      final out = trimFrontHalf('a\nb\nc\ntail', marker: 'app.log');
      expect(out, contains('tail'));
      expect(out, contains('c'));
      expect(out, isNot(contains('a\n')));
    });
  });

  group('wallpaper padding fill', () {
    test('transparent leaves the margin untouched', () {
      final p = canvasWithHole();
      applyPadding(p, WallpaperPadding.transparent);
      expect(p.alphaAt(0, 0), 0);
      expect(p.alphaAt(6, 5), 255);
    });

    test('black and white fill only the transparent margin', () {
      final black = canvasWithHole();
      applyPadding(black, WallpaperPadding.black);
      expect(black.alphaAt(0, 0), 255);
      expect(black.bytes.sublist(0, 3), [0, 0, 0]);
      // the picture itself keeps its colour
      expect(black.bytes.sublist((5 * 12 + 6) * 4, (5 * 12 + 6) * 4 + 3),
          [200, 100, 50]);

      final white = canvasWithHole();
      applyPadding(white, WallpaperPadding.white);
      expect(white.bytes.sublist(0, 4), [255, 255, 255, 255]);
    });

    test('extend option was removed by product decision (v0.5.7)', () {
      expect(WallpaperPadding.values, [
        WallpaperPadding.transparent,
        WallpaperPadding.black,
        WallpaperPadding.white
      ]);
      expect(WallpaperPadding.fromName('extend'), WallpaperPadding.white);
      expect(WallpaperPadding.fromName('nope'), WallpaperPadding.white);
      expect(WallpaperPadding.fromName(null), WallpaperPadding.white);
      expect(WallpaperPadding.fromName('black'), WallpaperPadding.black);
    });

    // Regression for the on-device report: white picture + white fill showed a
    // grey/black hairline at the seam. The cause was semi-transparent
    // anti-aliased edge pixels carrying a DARKENED colour; healFringe must
    // re-colour them from the nearest opaque pixel BEFORE blending.
    test('a dark anti-aliased fringe never survives a white fill', () {
      final p = PixelBuffer(6, 3, Uint8List(6 * 3 * 4));
      // opaque white core
      for (var x = 2; x < 4; x++) {
        p.setPixel(1 * 6 + x, 255, 255, 255, 255);
      }
      // a poisoned fringe pixel: semi-transparent DARK grey (the old bug)
      p.setPixel(1 * 6 + 1, 40, 40, 40, 128);
      p.setPixel(1 * 6 + 4, 40, 40, 40, 128);
      applyPadding(p, WallpaperPadding.white);
      // the seam must be white-ish (fringe healed to the core colour, then
      // blended over white), never the poisoned dark grey
      for (var x = 0; x < 6; x++) {
        final o = (1 * 6 + x) * 4;
        expect(p.bytes[o], greaterThan(180),
            reason:
                'pixel x=$x kept a dark seam: ${p.bytes.sublist(o, o + 4)}');
        expect(p.bytes[o + 3], 255);
      }
    });

    test('toPremultiplied matches the manual definition', () {
      final p = PixelBuffer(2, 1, Uint8List(8));
      p.setPixel(0, 200, 100, 50, 128); // straight
      p.setPixel(1, 9, 9, 9, 255); // opaque == premultiplied
      final pm = toPremultiplied(p);
      expect(pm[0], (200 * 128 + 127) ~/ 255);
      expect(pm[3], 128);
      expect(pm.sublist(4, 8), [9, 9, 9, 255]);
    });

    test('round-trips through a real PNG encode', () async {
      final p = canvasWithHole(w: 8, h: 6, inset: 2);
      applyPadding(p, WallpaperPadding.white);
      final png = await encodePng(p);
      expect(png.length, greaterThan(8));
      expect(png.sublist(1, 4), [0x50, 0x4e, 0x47], reason: 'PNG magic');
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 8);
      expect(frame.image.height, 6);
      frame.image.dispose();
      codec.dispose();
    });
  });

  group('wallpaper framing geometry', () {
    test('the canvas is wider than a phone screen (room to shift)', () {
      expect(kCanvasAspect, closeTo(13.5 / 24, 1e-9));
      // a 1080x2400 phone is 0.45 — the 0.5625 canvas leaves side margin
      expect(kCanvasAspect, greaterThan(1080 / 2400));
    });

    test('contain leaves a 25% larger framing ring by default', () {
      // 1 / 0.8 == 1.25: the picture is 25% smaller than "contain" in each
      // axis, which is the padding ring the user asked for
      expect(1 / kInitialScale, closeTo(1.25, 1e-9));
    });

    test('baseSizeFor fits the picture inside the canvas on one axis', () {
      const canvas = Size(540, 960); // 13.5:24
      // a wider-than-canvas picture is limited by width
      final wide =
          WallpaperEditPageState.baseSizeFor(const Size(1600, 900), canvas);
      expect(wide.width, closeTo(540, 1e-9));
      expect(wide.height, lessThan(960));
      // a taller picture is limited by height (900x2000 = 0.45, narrower
      // than the 0.5625 canvas — note 900x1600 would match it exactly)
      final tall =
          WallpaperEditPageState.baseSizeFor(const Size(900, 2000), canvas);
      expect(tall.height, closeTo(960, 1e-9));
      expect(tall.width, closeTo(432, 1e-9));
      // same proportion fills both
      final same =
          WallpaperEditPageState.baseSizeFor(const Size(135, 240), canvas);
      expect(same.width, closeTo(540, 1e-9));
      expect(same.height, closeTo(960, 1e-9));
    });
  });

  group('video decode ladder', () {
    test('the ladder ends in a rung that always works', () {
      expect(VideoDecodeChain.tiers.length, greaterThanOrEqualTo(2));
      final last = VideoDecodeChain.tiers.last;
      expect(last.hwdec, 'no', reason: 'the last rung must be software');
      expect(last.hardware, isFalse);
      expect(last.index, VideoDecodeChain.tiers.length - 1);
      for (var i = 0; i < VideoDecodeChain.tiers.length; i++) {
        expect(VideoDecodeChain.tiers[i].index, i);
      }
    });

    test('tier() clamps out-of-range indices', () {
      expect(VideoDecodeChain.tier(-3).index, 0);
      expect(
          VideoDecodeChain.tier(99).index, VideoDecodeChain.tiers.length - 1);
    });

    test('detects the on-device aimagereader fingerprint', () {
      // the exact lines from the field report
      expect(
          VideoDecodeChain.isStallLine(
              'mpv[vo/gpu/aimagereader/warn] Waiting for frame timed out!'),
          isTrue);
      expect(
          VideoDecodeChain.isStallLine(
              'mpv[vo/gpu/aimagereader/error] acquireLatestImage failed: -30001'),
          isTrue);
      // unrelated chatter must not trigger a downgrade
      expect(
          VideoDecodeChain.isStallLine('mpv[vo/gpu] Context resized'), isFalse);
      expect(
          VideoDecodeChain.isStallLine('mpv[ao/opensles] underrun'), isFalse);
      expect(VideoDecodeChain.isStallLine(''), isFalse);
    });

    test('three hits are required before acting', () {
      expect(VideoDecodeChain.stallHitsToDowngrade, 3);
    });

    test('hardware-looking video params arm the watchdog, rgba does not', () {
      expect(
          VideoDecodeChain.paramsLookHardware(
              'VideoParams(pixelformat: mediacodec, hwPixelformat: null, w: 1280, h: 720)'),
          isTrue);
      expect(
          VideoDecodeChain.paramsLookHardware(
              'VideoParams(pixelformat: rgba, hwPixelformat: null, w: 960, h: 540)'),
          isFalse);
      expect(
          VideoDecodeChain.paramsLookHardware(
              'VideoParams(pixelformat: null, hwPixelformat: null, w: null)'),
          isFalse);
      expect(
          VideoDecodeChain.paramsLookHardware(
              'VideoParams(pixelformat: nv12, hwPixelformat: videotoolbox_vld)'),
          isTrue);
    });

    test('start tier honours the test override', () {
      VideoDecodeChain.debugForceStartTier = 1;
      expect(VideoDecodeChain.instance.startTier, 1);
      VideoDecodeChain.debugForceStartTier = null;
      expect(VideoDecodeChain.instance.startTier, 0);
    });
  });
}
