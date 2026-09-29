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

    test('extend stretches the outermost picture pixels into the margin', () {
      final p = canvasWithHole(w: 12, h: 10, inset: 3);
      applyPadding(p, WallpaperPadding.extend);
      // nothing transparent is left
      for (var i = 0; i < p.length; i++) {
        expect(p.alphaAt(i % p.width, i ~/ p.width), 255,
            reason: 'pixel $i must be opaque after extend');
      }
      // the margin takes the colour of the nearest picture pixel
      expect(p.bytes.sublist(0, 3), [200, 100, 50],
          reason: 'top-left corner extends the picture border');
      expect(p.bytes.sublist((9 * 12 + 11) * 4, (9 * 12 + 11) * 4 + 3),
          [200, 100, 50]);
    });

    test('extend on an empty canvas is a no-op (no crash)', () {
      final p = PixelBuffer(4, 4, Uint8List(4 * 4 * 4));
      applyPadding(p, WallpaperPadding.extend);
      expect(p.alphaAt(0, 0), 0);
    });

    test('extend on a fully opaque canvas changes nothing', () {
      final p = PixelBuffer(3, 3, Uint8List(3 * 3 * 4));
      for (var i = 0; i < p.length; i++) {
        p.setPixel(i, 1, 2, 3, 255);
      }
      applyPadding(p, WallpaperPadding.extend);
      expect(p.bytes.sublist(0, 4), [1, 2, 3, 255]);
    });

    test('opaqueBounds reports the picture box', () {
      final b = opaqueBounds(canvasWithHole(w: 12, h: 10, inset: 3))!;
      expect((b.left, b.top, b.right, b.bottom), (3, 3, 8, 6));
      expect(opaqueBounds(PixelBuffer(2, 2, Uint8List(16))), isNull);
    });

    test('WallpaperPadding.fromName falls back to extend', () {
      expect(WallpaperPadding.fromName('black'), WallpaperPadding.black);
      expect(WallpaperPadding.fromName('nope'), WallpaperPadding.extend);
      expect(WallpaperPadding.fromName(null), WallpaperPadding.extend);
    });

    test('round-trips through a real PNG encode', () async {
      final p = canvasWithHole(w: 8, h: 6, inset: 2);
      applyPadding(p, WallpaperPadding.extend);
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
