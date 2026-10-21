// 壁纸取景的像素级后处理（纯 Dart，无插件依赖，可单测）。
//
// 取景画布比屏幕比例宽一圈（见 pages/wallpaper_edit.dart），保存出来的 PNG 里
// 图片四周会留空。留空区域怎么填由用户选择（v0.5.7 起：透明 / 纯黑 / 纯白，
// 默认纯白）。
//
// ## 为什么所有计算都在 straight alpha 空间做
//
// 实机反馈：白底图 + 白色填充时，图片与留白的**拼接处**出现一圈黑/灰细线。
// 根源是 alpha 空间混用：
//   * `Image.toByteData(rawRgba)` 返回的是 **premultiplied** RGBA；
//   * `ImageDescriptor.raw(pixelFormat: rgba8888)` 期望的也是 **premultiplied**；
//   * 而截图边缘的反锯齿像素是「边缘色 × 部分 alpha」，一旦中间任何一步把
//     premultiplied 当成 straight（或反过来）去填充/混合，这圈半透明像素就会
//     变成偏暗的颜色，落在浅色留白上就是一条灰线。
// 所以这里统一：
//   1. 截图用 `rawStraightRgba` 读（引擎负责 un-premultiply，拿到真实颜色）；
//   2. 填充/混合全部在 straight 空间按 `out = src·a + fill·(1-a)` 计算；
//   3. 对 0<a<255 的像素再做一次 **fringe heal**：RGB 直接取最近的全不透明
//      邻居（alpha 不变）。这样无论截图边缘带了多少插值/反锯齿残留，拼接处
//      都只会是「图片边缘色 → 填充色」的平滑过渡，不可能出现暗线；
//   4. 编码前再乘回 premultiplied（rgba8888 的要求），PNG 往返一致。
//
// 所有函数直接操作 RGBA 字节，输入输出都是 [PixelBuffer]，方便测试。

import 'dart:typed_data';
import 'dart:ui' as ui;

/// How the area around the framed image is filled.
enum WallpaperPadding {
  transparent,
  black,
  white;

  static WallpaperPadding fromName(String? n) => WallpaperPadding.values
      .firstWhere((e) => e.name == n, orElse: () => WallpaperPadding.white);
}

/// A tightly packed **straight-alpha** RGBA8 bitmap plus its geometry.
class PixelBuffer {
  PixelBuffer(this.width, this.height, this.bytes);

  /// Wrap straight-alpha RGBA bytes with explicit geometry.
  factory PixelBuffer.straight(int width, int height, ByteData data) =>
      PixelBuffer(
        width,
        height,
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );

  /// Wrap the straight-alpha bytes returned by
  /// `Image.toByteData(format: ImageByteFormat.rawStraightRgba)`.
  factory PixelBuffer.fromStraightImage(ui.Image img, ByteData data) =>
      PixelBuffer.straight(img.width, img.height, data);

  final int width;
  final int height;
  final Uint8List bytes;

  int get length => width * height;

  int alphaAt(int x, int y) => bytes[((y * width) + x) * 4 + 3];

  int redAt(int x, int y) => bytes[((y * width) + x) * 4];

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

int _blend(int src, int alpha, int dst) =>
    (src * alpha + dst * (255 - alpha) + 127) ~/ 255;

/// Composite every non-opaque pixel over the solid [r,g,b] fill, in straight
/// alpha space: fully transparent pixels become the fill, semi-transparent
/// (anti-aliased edge) pixels become a proper blend of edge colour and fill.
void blendOverFill(PixelBuffer p, int r, int g, int b) {
  final n = p.length;
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    final a = p.bytes[o + 3];
    if (a == 255) continue;
    if (a == 0) {
      p.bytes[o] = r;
      p.bytes[o + 1] = g;
      p.bytes[o + 2] = b;
      p.bytes[o + 3] = 255;
      continue;
    }
    p.bytes[o] = _blend(p.bytes[o], a, r);
    p.bytes[o + 1] = _blend(p.bytes[o + 1], a, g);
    p.bytes[o + 2] = _blend(p.bytes[o + 2], a, b);
    p.bytes[o + 3] = 255;
  }
}

/// Replace the RGB of every semi-transparent pixel with the RGB of the nearest
/// fully opaque pixel (search radius [radius], alpha untouched).
///
/// Kills dark halos: after this, an anti-aliased edge pixel carries the colour
/// of the picture it belongs to, so blending it over ANY fill colour can never
/// produce a grey/black seam line.
void healFringe(PixelBuffer p, {int radius = 2}) {
  final w = p.width, h = p.height;
  // collect the work list first: healing must read the ORIGINAL colours
  final pending = <int>[];
  for (var i = 0; i < p.length; i++) {
    final a = p.bytes[i * 4 + 3];
    if (a != 0 && a != 255) pending.add(i);
  }
  for (final i in pending) {
    final x = i % w, y = i ~/ w;
    var found = -1;
    for (var d = 1; d <= radius && found < 0; d++) {
      for (var dy = -d; dy <= d && found < 0; dy++) {
        for (var dx = -d; dx <= d; dx++) {
          if ((dx.abs() != d) && (dy.abs() != d)) continue; // ring only
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final j = ny * w + nx;
          if (p.bytes[j * 4 + 3] == 255) {
            found = j;
            break;
          }
        }
      }
    }
    if (found < 0) continue;
    p.bytes[i * 4] = p.bytes[found * 4];
    p.bytes[i * 4 + 1] = p.bytes[found * 4 + 1];
    p.bytes[i * 4 + 2] = p.bytes[found * 4 + 2];
  }
}

/// Apply the chosen [mode] to a captured canvas (straight alpha, transparent
/// margin around the framed picture).
void applyPadding(PixelBuffer p, WallpaperPadding mode) {
  switch (mode) {
    case WallpaperPadding.transparent:
      break;
    case WallpaperPadding.black:
      healFringe(p);
      blendOverFill(p, 0, 0, 0);
    case WallpaperPadding.white:
      healFringe(p);
      blendOverFill(p, 255, 255, 255);
  }
}

/// straight → premultiplied, as `ImageDescriptor.raw(rgba8888)` requires.
Uint8List toPremultiplied(PixelBuffer p) {
  final out = Uint8List.fromList(p.bytes);
  for (var i = 0; i < p.length; i++) {
    final o = i * 4;
    final a = out[o + 3];
    if (a == 255) continue;
    if (a == 0) {
      out[o] = 0;
      out[o + 1] = 0;
      out[o + 2] = 0;
      continue;
    }
    out[o] = (out[o] * a + 127) ~/ 255;
    out[o + 1] = (out[o + 1] * a + 127) ~/ 255;
    out[o + 2] = (out[o + 2] * a + 127) ~/ 255;
  }
  return out;
}

/// Re-encode a straight-alpha [PixelBuffer] as PNG bytes.
Future<Uint8List> encodePng(PixelBuffer p) async {
  // ImageDescriptor.raw is a synchronous factory (no decoding work)
  final desc = ui.ImageDescriptor.raw(
    await ui.ImmutableBuffer.fromUint8List(toPremultiplied(p)),
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

/// Read a [ui.Image] into a straight-alpha RGBA [PixelBuffer].
Future<PixelBuffer> pixelBufferOf(ui.Image img) async {
  final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  if (data == null) throw Exception('cannot read image pixels');
  return PixelBuffer.fromStraightImage(img, data);
}
