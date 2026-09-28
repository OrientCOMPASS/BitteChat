// 壁纸裁剪/预览页：所见即所得。
//
// 设计原则（v0.5.5 重做）：**不做任何预裁剪**。取景框 = 屏幕比例的视口，
// 原图以"完整可见"(contain) 的方式放入，用户可以：
//   * 双指缩放（可缩小到比 contain 更小 → 图片四周留出透明 padding）、平移
//   * 90° 旋转
//   * 滑杆实时调节透明度与模糊强度（sigma，0 = 关闭）
// 保存 = 对取景视口做 RepaintBoundary 截图：屏幕上看到什么，壁纸就是什么。
// 取景框内未被图片覆盖的区域保持透明（PNG alpha），全局壁纸层会透出主题底色。

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

  /// picked image to frame
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
  int _quarterTurns = 0;
  Size? _imgSize;

  @override
  void initState() {
    super.initState();
    _probeSize();
  }

  Future<void> _probeSize() async {
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final size =
          Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      if (mounted) setState(() => _imgSize = size);
    } catch (e) {
      appLog('wallpaper editor: size probe failed: $e');
      if (mounted) setState(() => _error = '$e');
    }
  }

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
      // 2x gives a crisp wallpaper on typical 1080p+ panels
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
      appLog('wallpaper framed+saved: ${data.lengthInBytes} bytes');
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
    final imgSize = _imgSize;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(L.t.wallpaperEdit),
        actions: [
          IconButton(
            tooltip: L.t.rotate,
            icon: const Icon(Icons.rotate_90_degrees_cw),
            onPressed: () =>
                setState(() => _quarterTurns = (_quarterTurns + 1) % 4),
          ),
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
                // the framing viewport = device screen proportion
                aspectRatio: MediaQuery.sizeOf(context).aspectRatio,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: ClipRect(
                    // opacity/blur preview wrap the CAPTURE boundary so the
                    // saved PNG records the raw framed image (the global
                    // wallpaper layer re-applies the treatment from prefs)
                    child: _treated(
                      RepaintBoundary(
                        key: _shotKey,
                        child: LayoutBuilder(
                          builder: (context, vp) {
                            final viewport = Size(vp.maxWidth, vp.maxHeight);
                            return Stack(
                              alignment: Alignment.center,
                              children: [
                                if (imgSize != null)
                                  InteractiveViewer(
                                    transformationController: _controller,
                                    minScale: 0.4,
                                    maxScale: 5.0,
                                    child: SizedBox(
                                      width: viewport.width,
                                      height: viewport.height,
                                      child: Center(
                                        child: _containSized(imgSize, viewport),
                                      ),
                                    ),
                                  )
                                else
                                  const Center(
                                      child: CircularProgressIndicator()),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(L.t.wallpaperBlur, style: theme.textTheme.bodyMedium),
                Expanded(
                  child: Slider(
                    value: widget.prefs.wallpaperBlurSigma.clamp(0.0, 12.0),
                    min: 0,
                    max: 12,
                    divisions: 24,
                    label: widget.prefs.wallpaperBlurSigma == 0
                        ? L.t.wallpaperBlurOff
                        : widget.prefs.wallpaperBlurSigma.toStringAsFixed(1),
                    onChanged: (v) {
                      widget.prefs.wallpaperBlurSigma = v;
                      widget.prefs.save();
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
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

  /// Whole image at "contain" size (rotated), centered — the user frames it
  /// from there; zooming below 1x leaves transparent padding around it.
  Widget _containSized(Size img, Size viewport) {
    final rotated = _quarterTurns % 2 == 1;
    final w = rotated ? img.height : img.width;
    final h = rotated ? img.width : img.height;
    final sw = viewport.width / w;
    final sh = viewport.height / h;
    final s = sw < sh ? sw : sh;
    return RotatedBox(
      quarterTurns: _quarterTurns,
      child: SizedBox(
        width: img.width * s,
        height: img.height * s,
        child: Image.file(
          File(widget.sourcePath),
          fit: BoxFit.fill,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) =>
              Center(child: Text(L.t.wallpaperLoadFail)),
        ),
      ),
    );
  }

  /// The same opacity+blur treatment AppWallpaper applies globally — the
  /// framing preview shows the FINAL look while the capture stays raw.
  Widget _treated(Widget child) {
    final opacity = widget.prefs.wallpaperOpacity.clamp(0.03, 1.0);
    final sigma = widget.prefs.wallpaperBlurSigma;
    Widget out = Opacity(opacity: opacity, child: child);
    if (sigma > 0) {
      out = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: out,
      );
    }
    return out;
  }
}
