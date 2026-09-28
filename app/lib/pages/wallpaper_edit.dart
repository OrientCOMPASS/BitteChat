// 壁纸裁剪/预览页：所见即所得。
//
// 用户选图后进入本页：双指缩放/平移调整构图，下方滑杆实时预览透明度与
// 模糊效果（与全局壁纸层的最终渲染一致）。保存时用 RepaintBoundary 对
// 视口截图——屏幕上看到什么，壁纸就是什么，无需手算裁剪矩阵。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/applog.dart';
import '../core/l10n.dart';
import '../core/prefs.dart';

class WallpaperEditPage extends StatefulWidget {
  const WallpaperEditPage({
    super.key,
    required this.sourcePath,
    required this.prefs,
    required this.destPath,
  });

  /// picked image to crop
  final String sourcePath;

  /// global UI prefs (opacity/blur live preview + final commit)
  final UiPrefs prefs;

  /// where the cropped wallpaper is written (usually <data>/wallpaper.img)
  final String destPath;

  @override
  State<WallpaperEditPage> createState() => _WallpaperEditPageState();
}

class _WallpaperEditPageState extends State<WallpaperEditPage> {
  final GlobalKey _shotKey = GlobalKey();
  final TransformationController _controller = TransformationController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final boundary =
          _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('viewport not ready');
      // 2x gives a crisp wallpaper on typical 1080p+ panels without the
      // memory cost of full 3-4x sensor resolution
      final shot = await boundary.toImage(pixelRatio: 2.0);
      final data = await shot.toByteData(format: ui.ImageByteFormat.png);
      shot.dispose();
      if (data == null) throw Exception('encode failed');
      final f = File(widget.destPath);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      widget.prefs.wallpaperPath = widget.destPath;
      widget.prefs.wallpaperRev++;
      await widget.prefs.save();
      appLog('wallpaper cropped+saved: ${data.lengthInBytes} bytes');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      appLog('wallpaper save failed: $e');
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      // opaque: this is an editor, the live wallpaper behind would confuse
      // the framing judgement
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(L.t.wallpaperEdit),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            label: Text(L.t.save),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                // crop viewport = the device screen proportion: what you
                // frame here is exactly what every page will show
                aspectRatio: MediaQuery.sizeOf(context).aspectRatio,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: ClipRect(
                    // opacity/blur preview wrap the CAPTURE boundary so the
                    // saved file records the raw framed image (the global
                    // wallpaper layer re-applies the treatment from prefs)
                    child: _treated(
                      RepaintBoundary(
                        key: _shotKey,
                        child: InteractiveViewer(
                          transformationController: _controller,
                          minScale: 1.0,
                          maxScale: 5.0,
                          child: Image.file(
                            File(widget.sourcePath),
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            errorBuilder: (_, __, ___) =>
                                Center(child: Text(L.t.wallpaperLoadFail)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              L.t.wallpaperEditHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
              textAlign: TextAlign.center,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(L.t.opacity, style: theme.textTheme.bodyMedium),
                Expanded(
                  child: Slider(
                    value: widget.prefs.wallpaperOpacity,
                    min: 0.05,
                    max: 0.6,
                    onChanged: (v) {
                      widget.prefs.wallpaperOpacity = v;
                      widget.prefs.save();
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
          SwitchListTile(
            value: widget.prefs.wallpaperBlur,
            title: Text(L.t.wallpaperBlur),
            dense: true,
            onChanged: (v) {
              widget.prefs.wallpaperBlur = v;
              widget.prefs.save();
              setState(() {});
            },
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// The same opacity+blur treatment AppWallpaper applies globally — so the
  /// framing preview shows the FINAL look while the capture stays raw.
  Widget _treated(Widget child) {
    final opacity = widget.prefs.wallpaperOpacity.clamp(0.03, 1.0);
    if (widget.prefs.wallpaperBlur) {
      return Opacity(
        opacity: opacity,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: child,
        ),
      );
    }
    return Opacity(opacity: opacity, child: child);
  }
}
