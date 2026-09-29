// 壁纸取景页：所见即所得 + 四周留白可调。
//
// 设计原则（v0.5.6 重做）：
//   * **不做任何预裁剪**。取景画布比屏幕比例**宽出一圈**（[kCanvasAspect]），
//     全局壁纸层以 cover 方式铺满屏幕 → 画布左右两侧会被裁掉。这一圈就是
//     用户的「调整空间」：把图往左/往右挪一点、放大一点，都能立刻看到最终
//     效果；画布中央的虚线框 = 屏幕实际显示范围。
//   * 图片默认以 contain × [kInitialScale] 放入画布，四周**始终**留有一圈
//     空白（v0.5.5 只在图片比例 ≠ 屏幕比例时才有留白，比例一致时无处可调）。
//   * 手势取代按钮：**单指拖动、双指缩放 + 旋转、双击复位**。旋转角度是连续
//     的，不再是四个固定方向。
//   * 留白填充方式可选（透明 / 纯黑 / 纯白 / 按图片外圈像素延展），取代原来
//     的透明度与模糊滑杆——这两项在「设置 → 壁纸」里已经能调，取景页不必重复。
//   * 保存 = 对画布做 RepaintBoundary 截图，再按留白方式做像素级后处理
//     （见 core/imgfx.dart），最后写 PNG。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/applog.dart';
import '../core/imgfx.dart';
import '../core/l10n.dart';
import '../core/prefs.dart';

/// Framing canvas proportion: 13.5 : 24 (≈ 9:16) — deliberately wider than
/// any phone screen so there is always margin to shift the picture into.
const double kCanvasAspect = 13.5 / 24.0;

/// Default picture scale relative to "contain": leaves a 25 % larger framing
/// ring around the image (1 / 0.8 = 1.25).
const double kInitialScale = 0.8;

class WallpaperEditPage extends StatefulWidget {
  const WallpaperEditPage({
    super.key,
    required this.sourcePath,
    required this.prefs,
    required this.destPath,
  });

  /// picked image to frame
  final String sourcePath;

  /// global UI prefs (final commit bumps `wallpaperRev`)
  final UiPrefs prefs;

  /// where the framed wallpaper is written (usually <data>/wallpaper.img)
  final String destPath;

  @override
  State<WallpaperEditPage> createState() => WallpaperEditPageState();
}

class WallpaperEditPageState extends State<WallpaperEditPage> {
  final GlobalKey _shotKey = GlobalKey();

  ui.Image? _img;
  Size? _imgSize;
  String? _error;
  bool _saving = false;

  /// framing transform: scale relative to the contain-fitted base size,
  /// rotation in radians, translation in canvas pixels
  double _scale = kInitialScale;
  double _rotation = 0;
  Offset _offset = Offset.zero;

  double _startScale = kInitialScale;
  double _startRotation = 0;
  Offset _startOffset = Offset.zero;

  WallpaperPadding _padding = WallpaperPadding.extend;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  /// Decode the source ONCE: gestures rebuild this page dozens of times per
  /// second and an `Image.file` child would re-resolve/re-paint from disk.
  Future<void> _load() async {
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _img = frame.image;
        _imgSize =
            Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      });
    } catch (e) {
      appLog('wallpaper editor: decode failed: $e');
      if (mounted) setState(() => _error = '$e');
    }
  }

  // ---------------------------------------------------------------- framing

  /// Contain-fitted picture size for a canvas of [canvas].
  static Size baseSizeFor(Size img, Size canvas) {
    final s = (canvas.width / img.width) < (canvas.height / img.height)
        ? canvas.width / img.width
        : canvas.height / img.height;
    return Size(img.width * s, img.height * s);
  }

  /// Centre-anchored rotate+scale, then the user's pan:
  /// `T(canvas/2 + offset) · R · S · T(-base/2)`.
  ///
  /// Built from plain [Matrix4] operations on purpose: Flutter only re-exports
  /// `Matrix4` from vector_math, so `Matrix4.compose` (which needs Vector3 /
  /// Quaternion) is not available without a direct vector_math dependency.
  Matrix4 _matrixFor(Size canvas, Size base) {
    final c = canvas.center(Offset.zero) + _offset;
    return Matrix4.identity()
      ..translate(c.dx, c.dy)
      ..rotateZ(_rotation)
      ..scale(_scale, _scale, 1.0)
      ..translate(-base.width / 2, -base.height / 2);
  }

  void _resetView() {
    setState(() {
      _scale = kInitialScale;
      _rotation = 0;
      _offset = Offset.zero;
    });
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startScale = _scale;
    _startRotation = _rotation;
    _startOffset = _offset;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      _scale = (_startScale * d.scale).clamp(0.35, 6.0);
      _rotation = _startRotation + d.rotation;
      _offset = _startOffset + d.focalPointDelta;
    });
  }

  // ------------------------------------------------------------------- save

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final boundary =
          _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('viewport not ready');
      // 2x keeps the wallpaper crisp on 1080p+ panels
      final shot = await boundary.toImage(pixelRatio: 2.0);
      final data = await shot.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = shot.width, h = shot.height;
      shot.dispose();
      if (data == null) throw Exception('capture failed');

      // honour the ByteData window: the backing buffer can be larger than the
      // returned view, and a wrong offset would shift every pixel
      final px = PixelBuffer(w, h,
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      applyPadding(px, _padding);
      final png = await encodePng(px);

      final f = File(widget.destPath);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(png, flush: true);
      widget.prefs.wallpaperPath = widget.destPath;
      widget.prefs.wallpaperRev++;
      await widget.prefs.save();
      appLog('wallpaper framed+saved: ${w}x$h padding=${_padding.name} '
          'scale=${_scale.toStringAsFixed(2)} '
          'rot=${(_rotation * 57.2958).toStringAsFixed(1)}deg '
          '${png.length} bytes');
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

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final img = _img;
    final imgSize = _imgSize;
    final screen = MediaQuery.sizeOf(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(L.t.wallpaperEdit),
        actions: [
          IconButton(
            tooltip: L.t.wallpaperEditGestureHint,
            icon: const Icon(Icons.gesture),
            onPressed: _resetView,
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
                aspectRatio: kCanvasAspect,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: ClipRect(
                    child: LayoutBuilder(
                      builder: (context, vp) {
                        final canvas = Size(vp.maxWidth, vp.maxHeight);
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            _PaddingPreview(mode: _padding, source: img),
                            if (img != null && imgSize != null)
                              GestureDetector(
                                onScaleStart: _onScaleStart,
                                onScaleUpdate: _onScaleUpdate,
                                onDoubleTap: _resetView,
                                child: RepaintBoundary(
                                  key: _shotKey,
                                  child: SizedBox(
                                    width: canvas.width,
                                    height: canvas.height,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Transform(
                                          transform: _matrixFor(
                                            canvas,
                                            baseSizeFor(imgSize, canvas),
                                          ),
                                          filterQuality: FilterQuality.high,
                                          child: RawImage(
                                            image: img,
                                            width: baseSizeFor(imgSize, canvas)
                                                .width,
                                            height: baseSizeFor(imgSize, canvas)
                                                .height,
                                            fit: BoxFit.fill,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            else
                              const Center(child: CircularProgressIndicator()),
                            // what the screen will actually show: the global
                            // wallpaper layer paints this bitmap with
                            // BoxFit.cover, i.e. it crops to the screen ratio
                            Center(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  size: _safeAreaSize(canvas, screen),
                                  painter: _SafeAreaPainter(
                                    color: theme.colorScheme.outline
                                        .withValues(alpha: 0.75),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Text(L.t.wallpaperEditGestureHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
            child: Text(L.t.wallpaperCropHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                Text(L.t.wallpaperPadding, style: theme.textTheme.bodyMedium),
                const SizedBox(width: 8),
                Expanded(
                  child: SegmentedButton<WallpaperPadding>(
                    showSelectedIcon: false,
                    style:
                        const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: [
                      ButtonSegment(
                          value: WallpaperPadding.transparent,
                          label: Text(L.t.wallpaperPaddingTransparent,
                              style: const TextStyle(fontSize: 12))),
                      ButtonSegment(
                          value: WallpaperPadding.black,
                          label: Text(L.t.wallpaperPaddingBlack,
                              style: const TextStyle(fontSize: 12))),
                      ButtonSegment(
                          value: WallpaperPadding.white,
                          label: Text(L.t.wallpaperPaddingWhite,
                              style: const TextStyle(fontSize: 12))),
                      ButtonSegment(
                          value: WallpaperPadding.extend,
                          label: Text(L.t.wallpaperPaddingExtend,
                              style: const TextStyle(fontSize: 12))),
                    ],
                    selected: {_padding},
                    onSelectionChanged: (s) =>
                        setState(() => _padding = s.first),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              _padding == WallpaperPadding.extend
                  ? L.t.wallpaperPaddingExtendHint
                  : L.t.wallpaperEditHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
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

  /// Largest screen-aspect rect that fits inside the canvas.
  static Size _safeAreaSize(Size canvas, Size screen) {
    final a = screen.width / screen.height;
    var w = canvas.width;
    var h = w / a;
    if (h > canvas.height) {
      h = canvas.height;
      w = h * a;
    }
    return Size(w, h);
  }
}

/// What the margin around the picture will look like once saved.
///
/// `extend` is previewed as a blurred cover of the source (the real save does
/// a pixel-exact border extension — see [extendBorders]); the other three are
/// exact.
class _PaddingPreview extends StatelessWidget {
  const _PaddingPreview({required this.mode, required this.source});

  final WallpaperPadding mode;
  final ui.Image? source;

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case WallpaperPadding.transparent:
        return const CustomPaint(painter: _CheckerPainter());
      case WallpaperPadding.black:
        return const ColoredBox(color: Colors.black);
      case WallpaperPadding.white:
        return const ColoredBox(color: Colors.white);
      case WallpaperPadding.extend:
        final img = source;
        if (img == null) return const ColoredBox(color: Colors.black);
        return ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: RawImage(image: img, fit: BoxFit.cover),
        );
    }
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 12.0;
    final dark = Paint()..color = const Color(0xFF3A3A3A);
    final light = Paint()..color = const Color(0xFF2A2A2A);
    canvas.drawRect(Offset.zero & size, light);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        if (((x ~/ cell) + (y ~/ cell)).isEven) continue;
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), dark);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter oldDelegate) => false;
}

/// Dashed outline of the region that survives the global layer's cover-crop.
class _SafeAreaPainter extends CustomPainter {
  const _SafeAreaPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()
      ..addRect(Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1));
    const dash = 7.0, gap = 5.0;
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        canvas.drawPath(metric.extractPath(dist, dist + dash), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_SafeAreaPainter oldDelegate) =>
      oldDelegate.color != color;
}
