// UI 偏好（主题模式 / 取色来源 / 自定义色 / 聊天壁纸），JSON 持久化在
// 核心数据目录下的 ui_prefs.json（与聊天库同生命周期，无需额外插件）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum ThemeModePref { system, light, dark }

enum SeedSource { brand, wallpaper, custom }

class UiPrefs extends ChangeNotifier {
  UiPrefs(this._file);

  final File _file;

  ThemeModePref themeMode = ThemeModePref.system;
  SeedSource seedSource = SeedSource.brand;
  int customColor = 0xFF2E7CF6;
  String? wallpaperPath;
  double wallpaperOpacity = 0.16;

  /// blur strength in sigma px; 0 = no blur (replaces the old bool switch)
  double wallpaperBlurSigma = 0;

  bool get wallpaperBlur => wallpaperBlurSigma > 0;

  /// 运行时缓存：从壁纸提取的主色
  Color? wallpaperSeed;

  /// bumped whenever the wallpaper FILE content changes in place (the crop
  /// editor rewrites the same path) so listeners re-decode it
  int wallpaperRev = 0;

  static Future<UiPrefs> load(String dataDir) async {
    final f = File('$dataDir/ui_prefs.json');
    final prefs = UiPrefs(f);
    try {
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map<String, dynamic>) {
          prefs.themeMode = ThemeModePref.values.firstWhere(
            (m) => m.name == j['themeMode'],
            orElse: () => ThemeModePref.system,
          );
          prefs.seedSource = SeedSource.values.firstWhere(
            (m) => m.name == j['seedSource'],
            orElse: () => SeedSource.brand,
          );
          prefs.customColor = (j['customColor'] as int?) ?? prefs.customColor;
          prefs.wallpaperPath = j['wallpaper'] as String?;
          prefs.wallpaperOpacity =
              (j['wallpaperOpacity'] as num?)?.toDouble() ?? 0.16;
          // migrate the old bool switch: true -> sigma 6
          prefs.wallpaperBlurSigma =
              (j['wallpaperBlurSigma'] as num?)?.toDouble() ??
                  ((j['wallpaperBlur'] as bool?) == true ? 6.0 : 0.0);
        }
      }
    } catch (_) {}
    await prefs.refreshWallpaperSeed();
    return prefs;
  }

  Future<void> save() async {
    try {
      await _file.writeAsString(jsonEncode({
        'themeMode': themeMode.name,
        'seedSource': seedSource.name,
        'customColor': customColor,
        'wallpaper': wallpaperPath,
        'wallpaperOpacity': wallpaperOpacity,
        'wallpaperBlur': wallpaperBlur,
        'wallpaperBlurSigma': wallpaperBlurSigma,
      }));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> refreshWallpaperSeed() async {
    final p = wallpaperPath;
    if (p == null) {
      wallpaperSeed = null;
      return;
    }
    try {
      final bytes = await File(p).readAsBytes();
      wallpaperSeed = await dominantColor(bytes);
    } catch (_) {
      wallpaperSeed = null;
    }
  }

  Color effectiveSeed() {
    switch (seedSource) {
      case SeedSource.brand:
        return const Color(0xFF2E7CF6);
      case SeedSource.wallpaper:
        return wallpaperSeed ?? const Color(0xFF2E7CF6);
      case SeedSource.custom:
        return Color(customColor);
    }
  }

  ThemeMode materialThemeMode() {
    switch (themeMode) {
      case ThemeModePref.system:
        return ThemeMode.system;
      case ThemeModePref.light:
        return ThemeMode.light;
      case ThemeModePref.dark:
        return ThemeMode.dark;
    }
  }
}

/// 提取图片主色：解码后按 4x4x4 色桶统计最高频桶的平均色。
Future<Color?> dominantColor(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final px = data.buffer.asUint8List();
    final buckets = <int, List<int>>{};
    final step = 4 * 997; // sample ~ every 997th pixel
    for (var i = 0; i + 3 < px.length; i += step) {
      final r = px[i], g = px[i + 1], b = px[i + 2];
      // skip near-white/near-black (backgrounds / text)
      final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      if (mx > 235 && mn > 235) continue;
      if (mx < 24) continue;
      if (mx - mn < 18) continue; // grey-ish
      final key = (r >> 6) << 8 | (g >> 6) << 4 | (b >> 6);
      final acc = buckets.putIfAbsent(key, () => [0, 0, 0, 0]);
      acc[0] += r;
      acc[1] += g;
      acc[2] += b;
      acc[3]++;
    }
    if (buckets.isEmpty) return null;
    var best = buckets.values.first;
    for (final v in buckets.values) {
      if (v[3] > best[3]) best = v;
    }
    final n = best[3];
    return Color.fromARGB(255, best[0] ~/ n, best[1] ~/ n, best[2] ~/ n);
  } catch (_) {
    return null;
  }
}
