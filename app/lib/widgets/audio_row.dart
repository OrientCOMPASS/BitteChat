// 气泡内紧凑音频播放器（audioplayers 本地文件）

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

class AudioRow extends StatefulWidget {
  const AudioRow({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<AudioRow> createState() => _AudioRowState();
}

class _AudioRowState extends State<AudioRow> {
  final AudioPlayer _player = AudioPlayer();
  PlayerState _state = PlayerState.stopped;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) {
      await _player.pause();
    } else {
      await _player.play(DeviceFileSource(widget.path));
    }
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playing = _state == PlayerState.playing;
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
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_fmt(_pos), style: theme.textTheme.labelSmall),
            Expanded(
              child: Slider(
                value: _dur.inMilliseconds > 0
                    ? _pos.inMilliseconds
                        .clamp(0, _dur.inMilliseconds)
                        .toDouble()
                    : 0,
                max: _dur.inMilliseconds > 0
                    ? _dur.inMilliseconds.toDouble()
                    : 1,
                onChanged: (v) async {
                  await _player.seek(Duration(milliseconds: v.round()));
                },
              ),
            ),
            Text(_fmt(_dur), style: theme.textTheme.labelSmall),
          ],
        ),
      ],
    );
  }
}
