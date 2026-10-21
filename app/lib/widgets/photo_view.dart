// 聊天图片查看页（QQ 式）：整屏黑底，图片以「一个方向顶满」的方式铺进屏幕
// （contain，不裁剪），可双指缩放/拖动、双击在 1× 与 2.5× 之间切换。
//
// 之前的实现是 `Center(child: InteractiveViewer(child: Image.file(fit:
// contain)))`：Center 传下去的是**松散约束**，Image.file 于是按图片的固有像素
// 尺寸布局（一张 3024×4032 的照片就是 3024×4032 逻辑像素），远超屏幕后被裁
// 掉 —— 用户看到的就是「查看图片被裁剪了」。现在查看器把满屏的紧约束直接交给
// Image（不再套 Center），图片按屏幕比例 contain 缩放：长边顶满、短边居中留
// 黑边，与 QQ 一致。

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/files.dart';
import '../core/l10n.dart';

class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.path,
    this.title,
    this.subtitle,
  });

  final String path;
  final String? title;
  final String? subtitle;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _controller = TransformationController();
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(_onSnapTick);
  Matrix4? _snapFrom;
  String? _error;

  /// Native pixel size of the picture, resolved once — lets the zoom-out floor
  /// be resolution-aware (see [_minScaleFor]).
  Size? _native;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  static const double _zoomedScale = 2.5;

  /// Default zoom-out floor (fraction of the fit-to-screen size). The effective
  /// floor is LOWERED for pictures that `contain` upscales, so the user can
  /// always shrink the image down to 50% of its ORIGINAL size (the v0.5.7
  /// "pinch the whole picture smaller, spring back on release" behaviour, just
  /// with a longer reach). See [_minScaleFor].
  static const double _minScale = 0.3;

  @override
  void initState() {
    super.initState();
    _resolveNativeSize();
  }

  void _resolveNativeSize() {
    final provider = FileImage(File(widget.path));
    _stream = provider.resolve(const ImageConfiguration());
    _listener = ImageStreamListener(
      (info, _) {
        if (mounted) {
          setState(() => _native =
              Size(info.image.width.toDouble(), info.image.height.toDouble()));
        }
      },
      // a decode error leaves _native null → we fall back to the fixed floor
      onError: (e, st) {},
    );
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    final s = _stream;
    final l = _listener;
    if (s != null && l != null) s.removeListener(l);
    _snap
      ..removeListener(_onSnapTick)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Zoom-out floor for a [box]-sized viewport: low enough that the picture can
  /// be shrunk to 50% of its ORIGINAL pixel size, but never higher than the
  /// [_minScale] default. A big photo (which `contain` already shrinks) keeps
  /// the default; a small picture that `contain` UPSCALES gets a lower floor so
  /// 50%-of-original stays reachable.
  double _minScaleFor(Size box) {
    final n = _native;
    if (n == null || n.width <= 0 || n.height <= 0) return _minScale;
    if (box.width <= 0 || box.height <= 0) return _minScale;
    final fit = (box.width / n.width) < (box.height / n.height)
        ? box.width / n.width
        : box.height / n.height;
    if (fit <= 0) return _minScale;
    final target = 0.5 / fit; // InteractiveViewer scale == 50% of original
    if (target < 0.01) return 0.01;
    return target > _minScale ? _minScale : target;
  }

  /// If the user released the pinch while zoomed out, animate back to 1x.
  void _onInteractionEnd(ScaleEndDetails d) {
    final scale = _controller.value.getMaxScaleOnAxis();
    if (scale >= 0.999) return;
    _snapFrom = Matrix4.copy(_controller.value);
    _snap.forward(from: 0);
  }

  void _onSnapTick() {
    final from = _snapFrom;
    if (from == null) return;
    _controller.value = _lerpMatrix(from, Matrix4.identity(), _snap.value);
    if (_snap.isCompleted) _snapFrom = null;
  }

  /// Component-wise lerp is fine here: both matrices are translate+uniform
  /// scale (what InteractiveViewer produces for pinch/pan), so the path is a
  /// smooth zoom+slide back to the fit pose.
  static Matrix4 _lerpMatrix(Matrix4 a, Matrix4 b, double t) {
    final out = Matrix4.zero();
    for (var i = 0; i < 16; i++) {
      out.storage[i] = a.storage[i] + (b.storage[i] - a.storage[i]) * t;
    }
    return out;
  }

  void _onDoubleTap() {
    final scale = _controller.value.getMaxScaleOnAxis();
    _controller.value = scale > 1.4
        ? Matrix4.identity()
        : (Matrix4.identity()
          ..scaleByDouble(_zoomedScale, _zoomedScale, 1.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.title ?? File(widget.path).uri.pathSegments.last;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15)),
            if (widget.subtitle != null)
              Text(widget.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: L.t.openWith,
            icon: const Icon(Icons.open_in_new, size: 20),
            onPressed: () => openWithExternalApp(widget.path, 'image/*'),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) => InteractiveViewer(
                transformationController: _controller,
                // constrained: true hands the viewport's TIGHT constraints to
                // the child, so `BoxFit.contain` fits the picture to the screen
                // instead of laying it out at its intrinsic pixel size
                minScale: _minScaleFor(constraints.biggest),
                maxScale: 6,
                boundaryMargin: const EdgeInsets.all(96),
                onInteractionEnd: _onInteractionEnd,
                child: GestureDetector(
                  onDoubleTap: _onDoubleTap,
                  child: SizedBox.expand(
                    child: Image.file(
                      File(widget.path),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.high,
                      errorBuilder: (_, e, ___) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _error == null) {
                            setState(() => _error = '$e');
                          }
                        });
                        return const Center(
                          child:
                              CircularProgressIndicator(color: Colors.white38),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
