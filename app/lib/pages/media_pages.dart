// 视频播放页 与 文本文件预览页
//
// 视频栈 = media_kit（libmpv，PiliPala/PiliPlus 同源方案）：
//   * 解码：hwdec=mediacodec,auto-safe —— 纯硬件解码链，不启用 FFmpeg 软解；
//     解码失败通过 mpv 错误事件明确告知用户（外部播放器兜底）。
//   * 渲染：mpv 经 EGL 渲染进 SurfaceTexture，与 PiliPlus 完全一致的成熟路径
//     （fvp/mdk 在部分机型上"有声无画"，见 flutter#159503 / fvp#235 一类
//     外部纹理合成问题；本项目实机测试确认后整体切换到该方案）。
//   * 诊断：mpv 日志（warn 级）+ 视频参数 + 错误全量写入 app.log，可随
//     「设置 → 导出日志」反馈。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/applog.dart';
import '../core/files.dart';
import '../core/l10n.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  Player? _player;
  VideoController? _videoController;
  bool _failed = false;
  String? _error;
  bool _playing = false;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final player = await Player.create(
        configuration: PlayerConfiguration(
          logLevel: MPVLogLevel.warn,
          options: {
            // strict hardware chain: no silent ffmpeg software fallback —
            // an undecodable track must surface as an explicit error
            'vd-lavc-software-fallback': 'no',
          },
        ),
      );
      _player = player;
      _subs.addAll([
        player.stream.error.listen((e) {
          if (e.isEmpty) return;
          appLog('mpv error: ${widget.path} -> $e');
          if (mounted) {
            setState(() {
              _failed = true;
              _error = e;
            });
          }
        }),
        player.stream.log
            .listen((l) => appLog('mpv[${l.prefix}/${l.level}] ${l.text}')),
        player.stream.videoParams.listen((v) =>
            appLog('mpv video params: ${widget.path} -> ${v.toString()}')),
        player.stream.playing.listen((v) {
          if (mounted) setState(() => _playing = v);
        }),
        player.stream.completed.listen((v) {
          if (mounted) setState(() => _completed = v);
        }),
        player.stream.position.listen((v) {
          if (mounted) setState(() => _position = v);
        }),
        player.stream.duration.listen((v) {
          if (mounted) setState(() => _duration = v);
        }),
      ]);
      await _logFileIntegrity();
      final vc = await VideoController.create(
        player,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: true,
          hwdec: 'mediacodec,auto-safe',
          androidAttachSurfaceAfterVideoParameters: false,
        ),
      );
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() => _videoController = vc);
      appLog('video open: ${widget.path} (media_kit/mpv hwdec=mediacodec)');
      await player.open(
        Media(widget.path, extras: {'cache': 'no'}),
        play: true,
      );
    } catch (e) {
      appLog('video init FAILED: ${widget.path} err=$e');
      if (mounted) {
        setState(() {
          _failed = true;
          _error = '$e';
        });
      }
    }
  }

  /// Forensic snapshot of the file on disk — distinguishes "player broken"
  /// from "file is not a complete mp4" in exported logs: size, ftyp magic
  /// at offset 4, and whether a moov box appears in the head or tail of the
  /// file (a partial BT download typically lacks the trailing moov).
  Future<void> _logFileIntegrity() async {
    try {
      final f = File(widget.path);
      final len = await f.length();
      final raf = await f.open();
      try {
        final head = await raf.read(16);
        String where = 'none';
        if (head.length >= 12 &&
            head[4] == 0x66 &&
            head[5] == 0x74 &&
            head[6] == 0x79 &&
            head[7] == 0x70) {
          where = 'ftyp-ok';
        }
        bool moovHead = false, moovTail = false;
        moovHead = _contains(head, 'moov');
        if (len > 16) {
          final tailStart = len > 262144 ? len - 262144 : 0;
          await raf.setPosition(tailStart);
          final tail = await raf.read(len - tailStart);
          moovTail = _contains(tail, 'moov');
        }
        appLog('video file: len=$len magic=$where '
            'moov(head)=$moovHead moov(tail256k)=$moovTail '
            'zeroHead=${head.every((b) => b == 0)}');
      } finally {
        await raf.close();
      }
    } catch (e) {
      appLog('video file introspection failed: $e');
    }
  }

  static bool _contains(List<int> bytes, String tag) {
    final pat = tag.codeUnits;
    outer:
    for (var i = 0; i + pat.length <= bytes.length; i++) {
      for (var j = 0; j < pat.length; j++) {
        if (bytes[i + j] != pat[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  Future<void> _playPause() async {
    final p = _player;
    if (p == null) return;
    if (_completed) {
      await p.seek(Duration.zero);
      await p.play();
      return;
    }
    await p.playOrPause();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    final p = _player;
    _player = null;
    if (p != null) {
      // pause first so the render pipeline quiesces before teardown —
      // disposing mid-frame during activity recreation races the native
      // surface cleanup
      p.pause().catchError((_) {}).whenComplete(() => p.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vc = _videoController;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: _failed
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(L.t.videoFail,
                        style: const TextStyle(color: Colors.white70)),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12)),
                    ],
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: Text(L.t.openWith),
                      onPressed: () =>
                          openWithExternalApp(widget.path, 'video/*'),
                    ),
                    const SizedBox(height: 8),
                    Text(L.t.videoDecoderTip,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                    const SizedBox(height: 4),
                    Text(L.t.videoDecoderHardwareOnly,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ],
                ),
              ),
            )
          : vc == null
              ? const Center(child: CircularProgressIndicator())
              : Video(
                  controller: vc,
                  controls: NoVideoControls,
                  fit: BoxFit.contain,
                  fill: Colors.black,
                ),
      bottomNavigationBar: vc == null || _failed
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    IconButton(
                      color: Colors.white,
                      icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                      onPressed: _playPause,
                    ),
                    Text(_fmt(_position),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _duration > Duration.zero
                            ? _position.inMilliseconds
                                .clamp(0, _duration.inMilliseconds)
                                .toDouble()
                            : 0,
                        max: _duration > Duration.zero
                            ? _duration.inMilliseconds.toDouble()
                            : 1,
                        onChanged: (v) =>
                            _player?.seek(Duration(milliseconds: v.toInt())),
                      ),
                    ),
                    Text(_fmt(_duration),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                    IconButton(
                      color: Colors.white,
                      tooltip: L.t.openWith,
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: () =>
                          openWithExternalApp(widget.path, 'video/*'),
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
        setState(() => _error = L.t.fileTooBig);
        return;
      }
      final bytes = await f.readAsBytes();
      // naive binary sniff: NUL byte means not text
      if (bytes.take(4096).contains(0)) {
        setState(() => _error = L.t.notPlainText);
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
              ? Center(child: CircularProgressIndicator())
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
