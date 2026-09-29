// 壁纸取景的像素级后处理（纯 Dart，无插件依赖，可单测）。
//
// 取景画布比屏幕比例宽一圈（见 pages/wallpaper_edit.dart），保存出来的 PNG
// 里图片四周会留空。留空区域怎么填由用户选择：
//   transparent → 保持 alpha=0，全局壁纸层透出主题底色
//   black/white → 填纯色
//   extend      → 「按图片外部圈层扩展填充」：把图片最外一圈像素向外复制，
//                 边缘自然延展（类似 PS 的内容识别填充的朴素版本）
//
// 所有函数都直接操作 RGBA 字节，输入输出都是 [PixelBuffer]，方便测试。

import 'dart:typed_data';
import 'dart:ui' as ui;

/// How the area around the framed image is filled.
enum WallpaperPadding {
  transparent,
  black,
  white,
  extend;

  static WallpaperPadding fromName(String? n) => WallpaperPadding.values
      .firstWhere((e) => e.name == n, orElse: () => WallpaperPadding.extend);
}

/// A tightly packed RGBA8 bitmap plus its geometry.
class PixelBuffer {
  PixelBuffer(this.width, this.height, this.bytes);

  factory PixelBuffer.fromImage(ui.Image img, ByteData data) => PixelBuffer(
        img.width,
        img.height,
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );

  final int width;
  final int height;
  final Uint8List bytes;

  int get length => width * height;

  int alphaAt(int x, int y) => bytes[((y * width) + x) * 4 + 3];

  /// Copy the RGBA of one pixel into [dst] at the same index.
  void copyPixel(int srcIndex, int dstIndex) {
    final s = srcIndex * 4, d = dstIndex * 4;
    bytes[d] = bytes[s];
    bytes[d + 1] = bytes[s + 1];
    bytes[d + 2] = bytes[s + 2];
    bytes[d + 3] = bytes[s + 3];
  }

  void setPixel(int index, int r, int g, int b, int a) {
    final o = index * 4;
    bytes[o] = r;
    bytes[o + 1] = g;
    bytes[o + 2] = b;
    bytes[o + 3] = a;
  }
}

/// Fill every fully transparent pixel with [color] (alpha is forced to 255).
void fillTransparent(PixelBuffer p, int r, int g, int b) {
  final n = p.length;
  for (var i = 0; i < n; i++) {
    if (p.bytes[i * 4 + 3] == 0) p.setPixel(i, r, g, b, 255);
  }
}

/// Extend the outermost ring of the opaque image outwards into the
/// transparent margin (two separable passes: horizontal, then vertical).
///
/// Result for a picture floating in a transparent canvas: every margin pixel
/// takes the colour of the nearest image pixel along its row (and, for the
/// corners/rows outside the picture, along its column) — i.e. the image's own
/// border is "stretched" around it.
void extendBorders(PixelBuffer p) {
  final w = p.width, h = p.height;
  if (w == 0 || h == 0) return;

  // --- horizontal: within each row, spread the first/last opaque pixel ---
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var first = -1, last = -1;
    for (var x = 0; x < w; x++) {
      if (p.bytes[(row + x) * 4 + 3] != 0) {
        if (first < 0) first = x;
        last = x;
      }
    }
    if (first < 0) continue; // nothing opaque on this row → vertical pass
    for (var x = 0; x < first; x++) {
      p.copyPixel(row + first, row + x);
    }
    for (var x = last + 1; x < w; x++) {
      p.copyPixel(row + last, row + x);
    }
  }

  // --- vertical: fill rows that had nothing opaque from the nearest row ---
  for (var x = 0; x < w; x++) {
    var first = -1, last = -1;
    for (var y = 0; y < h; y++) {
      if (p.bytes[(y * w + x) * 4 + 3] != 0) {
        if (first < 0) first = y;
        last = y;
      }
    }
    if (first < 0) continue;
    for (var y = 0; y < first; y++) {
      p.copyPixel(first * w + x, y * w + x);
    }
    for (var y = last + 1; y < h; y++) {
      p.copyPixel(last * w + x, y * w + x);
    }
  }
}

/// Apply the chosen [mode] to a captured canvas (transparent margin around
/// the framed picture).
void applyPadding(PixelBuffer p, WallpaperPadding mode) {
  switch (mode) {
    case WallpaperPadding.transparent:
      break;
    case WallpaperPadding.black:
      fillTransparent(p, 0, 0, 0);
    case WallpaperPadding.white:
      fillTransparent(p, 255, 255, 255);
    case WallpaperPadding.extend:
      extendBorders(p);
  }
}

/// Re-encode an RGBA [PixelBuffer] as PNG bytes.
Future<Uint8List> encodePng(PixelBuffer p) async {
  // ImageDescriptor.raw is a synchronous factory (no decoding work)
  final desc = ui.ImageDescriptor.raw(
    await ui.ImmutableBuffer.fromUint8List(p.bytes),
    width: p.width,
    height: p.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await desc.instantiateCodec();
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  desc.dispose();
  if (data == null) throw Exception('PNG encode failed');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Read a [ui.Image] into an RGBA [PixelBuffer].
Future<PixelBuffer> pixelBufferOf(ui.Image img) async {
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) throw Exception('cannot read image pixels');
  return PixelBuffer.fromImage(img, data);
}

/// Bounding box of the opaque region, or null when the buffer is empty.
/// Used by the tests and by the editor's diagnostics.
({int left, int top, int right, int bottom})? opaqueBounds(PixelBuffer p) {
  var left = p.width, top = p.height, right = -1, bottom = -1;
  for (var y = 0; y < p.height; y++) {
    for (var x = 0; x < p.width; x++) {
      if (p.bytes[(y * p.width + x) * 4 + 3] == 0) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  if (right < 0) return null;
  return (left: left, top: top, right: right, bottom: bottom);
}
