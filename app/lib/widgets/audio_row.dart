// 气泡内紧凑音频播放器（media_kit/libmpv 本地文件）。
//
// 所有音频气泡共享一个全局 Player：同一时刻只播一条（新播放自动停止上一条），
// 避免为每条语音消息各建一个 mpv 实例的内存开销（旧 audioplayers 实现为
// 每行一个 AudioPlayer）。未播放过的行不触碰原生资源。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../core/applog.dart';

/// Process-wide audio player shared by all [AudioRow]s.
class _SharedAudio {
  _SharedAudio._();

  static final _SharedAudio instance = _SharedAudio._();

  Player? _player;
  String? currentPath;
  bool broken = false;

  Future<Player?> player() async {
    if (broken) return null;
    final p = _player;
    if (p != null) return p;
    try {
      return _player = await Player.create(
        configuration: PlayerConfiguration(
          logLevel: MPVLogLevel.warn,
          options: {
            'ao': 'opensles,aaudio,audiotrack',
            'volume': '100',
          },
        ),
      );
    } catch (e) {
      // host/demo mode without libmpv: degrade to a disabled row
      broken = true;
      appLog('audio player unavailable: $e');
      return null;
    }
  }

  Future<void> stop() async {
    final p = _player;
    if (p == null) return;
    try {
      await p.stop();
    } catch (_) {}
    currentPath = null;
  }
}

/// Public handle on the process-wide voice player, for other media surfaces.
///
/// A video that starts making noise must not mix with a voice message that is
/// already playing, so the video page calls [stopAll] when it takes over.
abstract class SharedVoicePlayer {
  SharedVoicePlayer._();

  static Future<void> stopAll() => _SharedAudio.instance.stop();
}

class AudioRow extends StatefulWidget {
  const AudioRow({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<AudioRow> createState() => _AudioRowState();
}

class _AudioRowState extends State<AudioRow> {
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _active = false; // this row owns the shared player
  bool _playing = false;
  bool _completed = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  bool get _mine => _SharedAudio.instance.currentPath == widget.path;

  void _bind(Player p) {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _subs.addAll([
      p.stream.playing.listen((v) {
        if (mounted && _mine) setState(() => _playing = v);
      }),
      p.stream.completed.listen((v) {
        if (mounted && _mine) {
          setState(() {
            _completed = v;
            if (v) _playing = false;
          });
        }
      }),
      p.stream.position.listen((v) {
        if (mounted && _mine) setState(() => _pos = v);
      }),
      p.stream.duration.listen((v) {
        if (mounted && _mine) setState(() => _dur = v);
      }),
      p.stream.error.listen((e) {
        if (e.isNotEmpty) appLog('audio error: ${widget.path} -> $e');
      }),
    ]);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    // leaving the list stops playback of this row's message
    if (_mine) _SharedAudio.instance.stop();
    super.dispose();
  }

  Future<void> _toggle() async {
    final shared = _SharedAudio.instance;
    final p = await shared.player();
    if (p == null || !mounted) return;
    if (_mine && _playing) {
      await p.pause();
      return;
    }
    if (_mine && _completed) {
      setState(() => _completed = false);
      await p.seek(Duration.zero);
      await p.play();
      return;
    }
    if (_mine) {
      await p.play();
      return;
    }
    // switching rows: (re)bind streams and open this file
    setState(() {
      _active = true;
      _playing = true;
      _completed = false;
      _pos = Duration.zero;
      _dur = Duration.zero;
    });
    shared.currentPath = widget.path;
    _bind(p);
    try {
      await p.open(Media(widget.path, extras: {'cache': 'no'}), play: true);
    } catch (e) {
      appLog('audio open failed: ${widget.path} -> $e');
      if (mounted) setState(() => _playing = false);
    }
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playing = _playing && _mine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filled(
              onPressed: _toggle,
              style: IconButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(34, 34),
              ),
              icon: Icon(playing ? Icons.pause : Icons.play_arrow, size: 20),
            ),
            const SizedBox(width: 8),
            Icon(Icons.audiotrack, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        if (_active || playing)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_fmt(_pos), style: theme.textTheme.bodySmall),
              SizedBox(
                width: 120,
                child: Slider(
                  value: _dur > Duration.zero
                      ? _pos.inMilliseconds
                          .clamp(0, _dur.inMilliseconds)
                          .toDouble()
                      : 0,
                  max:
                      _dur > Duration.zero ? _dur.inMilliseconds.toDouble() : 1,
                  onChanged: (v) async {
                    final p = _SharedAudio.instance._player;
                    if (p != null && _mine) {
                      await p.seek(Duration(milliseconds: v.toInt()));
                    }
                  },
                ),
              ),
              Text(_fmt(_dur), style: theme.textTheme.bodySmall),
            ],
          ),
      ],
    );
  }
}
