// 视频播放页 与 文本文件预览页

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.file(File(widget.path));
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
      await c.play();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _failed
          ? const Center(
              child: Text('无法播放该视频', style: TextStyle(color: Colors.white70)))
          : c == null
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: AspectRatio(
                    aspectRatio: c.value.aspectRatio,
                    child: c.value.isInitialized
                        ? VideoPlayer(c)
                        : const SizedBox.shrink(),
                  ),
                ),
      bottomNavigationBar: c == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    IconButton(
                      color: Colors.white,
                      icon: Icon(
                          c.value.isPlaying ? Icons.pause : Icons.play_arrow),
                      onPressed: () async {
                        if (c.value.isPlaying) {
                          await c.pause();
                        } else {
                          await c.play();
                        }
                        setState(() {});
                      },
                    ),
                    Expanded(
                      child: ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: c,
                        builder: (_, v, __) => Slider(
                          value: v.duration.inMilliseconds > 0
                              ? v.position.inMilliseconds
                                  .clamp(0, v.duration.inMilliseconds)
                                  .toDouble()
                              : 0,
                          max: v.duration.inMilliseconds > 0
                              ? v.duration.inMilliseconds.toDouble()
                              : 1,
                          onChanged: (x) =>
                              c.seekTo(Duration(milliseconds: x.round())),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class TextPreviewPage extends StatefulWidget {
  const TextPreviewPage({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<TextPreviewPage> createState() => _TextPreviewPageState();
}

class _TextPreviewPageState extends State<TextPreviewPage> {
  String? _content;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = File(widget.path);
      final size = await f.length();
      if (size > 2 * 1024 * 1024) {
        setState(() => _error = '文件超过 2MB，请使用“其他应用打开”');
        return;
      }
      final bytes = await f.readAsBytes();
      // naive binary sniff: NUL byte means not text
      if (bytes.take(4096).contains(0)) {
        setState(() => _error = '该文件不是纯文本');
        return;
      }
      setState(() => _content = String.fromCharCodes(bytes));
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _error != null
          ? Center(
              child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!),
            ))
          : _content == null
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    _content!,
                    style: const TextStyle(
                        fontSize: 13, height: 1.5, fontFamily: 'monospace'),
                  ),
                ),
    );
  }
}
