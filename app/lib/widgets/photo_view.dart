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

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  final TransformationController _controller = TransformationController();
  String? _error;

  static const double _zoomedScale = 2.5;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDoubleTap() {
    final scale = _controller.value.getMaxScaleOnAxis();
    _controller.value = scale > 1.4
        ? Matrix4.identity()
        : (Matrix4.identity()..scale(_zoomedScale));
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
          : InteractiveViewer(
              transformationController: _controller,
              // constrained: true hands the viewport's TIGHT constraints to
              // the child, so `BoxFit.contain` fits the picture to the screen
              // instead of laying it out at its intrinsic pixel size
              minScale: 1,
              maxScale: 6,
              boundaryMargin: const EdgeInsets.all(96),
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
                        child: CircularProgressIndicator(color: Colors.white38),
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }
}
