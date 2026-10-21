// 全局壁纸：解码缓存 + 无 saveLayer 的不透明度绘制。
//
// v0.5.6 之前壁纸是 AppWallpaper 自己 State 里的一张 ui.Image：
//   * State 一旦重建（Activity 重建、根 Builder 换 widget、热重载）就要重新
//     读盘 + 解码 + 重新烘焙模糊 → 用户看到的就是「从聊天详情页切回主页时
//     背景图要隔一段时间才出来」的卡顿；
//   * 绘制时套了一层 Opacity（全屏 saveLayer），每帧都要走一次离屏合成。
//
// 现在：
//   * [WallpaperCache] 是 app 级单例，缓存 key 只包含**需要重新解码**的因素
//     （路径 / 内容版本 / 目标宽度 / 模糊 sigma）。命中即一次 Map 查找，任何
//     widget 重建都是零延迟；不透明度**不进 key**——否则拖动滑杆会每 tick 重新
//     解码整张图，比原来还卡。
//   * 不透明度在绘制时用 `Paint.color` 的 alpha 调制：一次 drawImageRect，
//     没有 Opacity 层、没有 saveLayer（`Opacity` 对 0<α<1 会强制离屏合成，
//     全屏壁纸每帧都要付这个代价）。
//   * 新图解码期间旧图继续挂着（不会先黑一下再出现）；main() 在 runApp 之前
//     预热一次，首帧就带壁纸。

import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

// widgets.dart is what exposes CustomPainter / ChangeNotifier plus the
// dart:ui value types (Color, Paint, Rect, Size, Offset, FilterQuality) that
// painting.dart re-exports; the image/filter APIs stay `ui.`-prefixed.
import 'package:flutter/widgets.dart';

import 'applog.dart';

/// One decoded (and blur-baked) wallpaper, ready to paint at any opacity.
class WallpaperEntry {
  WallpaperEntry({required this.image, required this.key});

  /// Decoded bitmap with the blur already baked in, full alpha.
  final ui.Image image;

  final String key;

  double get aspect => image.width / image.height;

  void dispose() => image.dispose();
}

/// App-wide decoded-wallpaper cache (small LRU).
class WallpaperCache extends ChangeNotifier {
  WallpaperCache._();

  static final WallpaperCache instance = WallpaperCache._();

  /// Current entry plus one spare (e.g. the previous wallpaper while a new one
  /// decodes) — a full-screen RGBA bitmap is ~10 MB, so this is bounded.
  static const int _maxEntries = 2;

  final LinkedHashMap<String, WallpaperEntry> _entries = LinkedHashMap();
  String? _requestedKey;
  int _seq = 0;

  /// The entry to paint, or null while the first decode is in flight.
  WallpaperEntry? get current {
    final key = _requestedKey;
    return key == null ? null : _entries[key];
  }

  /// Cache key: everything that forces a NEW DECODE. Opacity is deliberately
  /// absent — it is a paint parameter (see [WallpaperPainter]).
  static String buildKey({
    required String? path,
    required int rev,
    required double sigma,
    int targetWidth = 1440,
  }) {
    if (path == null) return 'none';
    return '$path|rev=$rev|w=$targetWidth|s=${sigma.toStringAsFixed(2)}';
  }

  /// Make `key` the painted wallpaper, decoding it if it is not cached.
  ///
  /// Returns immediately when cached; while a new bitmap is being prepared the
  /// previous entry stays painted (no flash). Listeners are notified when the
  /// new entry lands.
  Future<void> load(String key, Future<WallpaperEntry> Function() build) async {
    _requestedKey = key;
    if (_entries.containsKey(key)) {
      _touch(key);
      notifyListeners();
      return;
    }
    final seq = ++_seq;
    try {
      final entry = await build();
      if (seq != _seq) {
        entry.dispose(); // a newer request superseded this decode
        return;
      }
      _entries[key] = entry;
      _touch(key);
      notifyListeners();
    } catch (e) {
      appLog('wallpaper decode failed ($key): $e');
      if (seq == _seq) notifyListeners();
    }
  }

  /// Drop the wallpaper (user cleared it).
  void clear() {
    _seq++;
    _requestedKey = null;
    for (final e in _entries.values) {
      e.dispose();
    }
    _entries.clear();
    notifyListeners();
  }

  void _touch(String key) {
    final e = _entries.remove(key);
    if (e != null) _entries[key] = e;
    while (_entries.length > _maxEntries) {
      final oldest = _entries.keys.first;
      final victim = _entries.remove(oldest);
      if (victim != null && oldest != _requestedKey) victim.dispose();
    }
  }

  /// Decode `path` with the blur baked in.
  static Future<WallpaperEntry> build({
    required String key,
    required String path,
    required double sigma,
    int targetWidth = 1440,
  }) async {
    final bytes = await File(path).readAsBytes();
    final codec =
        await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
    final frame = await codec.getNextFrame();
    codec.dispose();
    var img = frame.image;
    if (sigma > 0) img = await blurred(img, sigma);
    return WallpaperEntry(image: img, key: key);
  }

  /// Bake a gaussian blur into the bitmap once — an `ImageFiltered` layer would
  /// re-render a full-screen blur on every navigation frame.
  static Future<ui.Image> blurred(ui.Image src, double sigma) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final paint = Paint()
      ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    canvas.drawImage(src, Offset.zero, paint);
    final pic = rec.endRecording();
    final out = await pic.toImage(src.width, src.height);
    pic.dispose();
    src.dispose();
    return out;
  }
}

/// Paints a wallpaper bitmap cover-fitted into [size] with [opacity] applied
/// through the paint's alpha (no saveLayer, unlike the `Opacity` widget).
class WallpaperPainter extends CustomPainter {
  const WallpaperPainter({required this.image, required this.opacity});

  final ui.Image image;
  final double opacity;

  /// BoxFit.cover destination rect: fill the box, crop the overflow, centred.
  static Rect coverRect(Size imageSize, Size box) {
    final scale = imageSize.width / imageSize.height > box.width / box.height
        ? box.height / imageSize.height
        : box.width / imageSize.width;
    final w = imageSize.width * scale;
    final h = imageSize.height * scale;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final a = (opacity.clamp(0.0, 1.0) * 255).round();
    if (a <= 0) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      coverRect(Size(image.width.toDouble(), image.height.toDouble()), size),
      Paint()
        ..color = Color.fromARGB(a, 255, 255, 255)
        ..filterQuality = FilterQuality.low
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(WallpaperPainter old) =>
      old.image != image || (old.opacity - opacity).abs() > 0.001;
}
