// 视频播放页 与 文本文件预览页
//
// 视频栈 = media_kit（libmpv，PiliPala/PiliPlus 同源方案）：
//   * 渲染：mpv 经 EGL 渲染进 SurfaceTexture（`--vo=gpu`），与 PiliPlus 一致的
//     成熟路径（fvp/mdk 在部分机型上"有声无画"，见 flutter#159503 / fvp#235
//     一类外部纹理合成问题；本项目实机测试确认后整体切换到该方案）。
//   * 解码：**分级降级链**（见 core/video_decode.dart）。v0.5.5 之前是
//     「hwdec=mediacodec,auto-safe + 禁用软解回退」的纯硬解策略，实机证明它
//     会在 mpv 的 aimagereader interop 上整体黑屏（解码器在跑、一帧都取不出
//     来，mpv 自己还不回退），所以从 v0.5.6 起改为「零拷贝硬解 → 硬解回读 →
//     软解」三档，按日志指纹/看门狗自动降级，并把该机型最终可用的档位记下来。
//   * 诊断：mpv 日志（warn 级）+ 视频参数 + 解码档位 + 错误全量写入 app.log，
//     可随「设置 → 导出日志」反馈。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/applog.dart';
import '../core/files.dart';
import '../core/l10n.dart';
import '../core/video_decode.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.path, required this.title});

  final String path;
  final String title;

  /// Test/observability hooks — the CI real-video test asserts on these
  /// instead of pixel-diffing a software-rendered emulator.
  @visibleForTesting
  static String? debugLastVideoParams;
  @visibleForTesting
  static Duration debugLastPosition = Duration.zero;
  @visibleForTesting
  static final List<String> debugMpvLogs = [];
  @visibleForTesting
  static String? debugLastError;

  /// Decode rung the page ended up playing on (see [VideoDecodeChain]).
  @visibleForTesting
  static int debugActiveTier = 0;

  /// How many times the page had to drop to a lower rung.
  @visibleForTesting
  static int debugDowngrades = 0;

  /// Renderer-stall lines seen on the rung that is CURRENTLY active. Reset on
  /// every downgrade, so a test can tell "stalled, then recovered on a lower
  /// rung" (empty) from "still stalling" (non-empty).
  @visibleForTesting
  static final List<String> debugActiveTierStalls = [];

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _videoController;
  bool _failed = false;
  String? _error;
  bool _playing = false;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final List<StreamSubscription<dynamic>> _subs = [];

  // --- decode chain state -------------------------------------------------
  int _generation = 0;
  int _tierIndex = 0;
  int _stallHits = 0;
  bool _firstFrameSeen = false;
  bool _hwDecodeObserved = false;
  bool _videoParamsSeen = false;
  bool _watchdogArmed = false;
  bool _switching = false;
  Timer? _watchdog;
  Timer? _promoteTimer;

  VideoDecodeTier get _tier => VideoDecodeChain.tier(_tierIndex);

  @override
  void initState() {
    super.initState();
    VideoPlayerPage.debugMpvLogs.clear();
    VideoPlayerPage.debugLastError = null;
    VideoPlayerPage.debugLastVideoParams = null;
    VideoPlayerPage.debugLastPosition = Duration.zero;
    VideoPlayerPage.debugActiveTier = VideoDecodeChain.instance.startTier;
    VideoPlayerPage.debugDowngrades = 0;
    VideoPlayerPage.debugActiveTierStalls.clear();
    _tierIndex = VideoDecodeChain.instance.startTier;
    WidgetsBinding.instance.addObserver(this);
    // snapshot native chatter (renderer banner, codec/driver lines) around
    // playback start — the Dart-side log cannot see any of these
    captureOwnLogcat('video-pre');
    _openAt(_tierIndex, seekTo: null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // backgrounding: quiesce mpv — surface races during fast
    // background/foreground switches were a native-crash suspect
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _player?.pause().catchError((_) {});
      appLog('video lifecycle: $state (paused player)');
    }
  }

  // ---------------------------------------------------------------- open

  /// (Re)build the whole player stack on decode rung [tierIndex], resuming at
  /// [seekTo] when given. A full rebuild (instead of flipping `--hwdec` on the
  /// live player) is deliberate: the hwdec interop is chosen while the
  /// decoder/vo are wired up, and a stalled interop leaves both in a state we
  /// would rather not reuse.
  Future<void> _openAt(int tierIndex, {Duration? seekTo}) async {
    final gen = ++_generation;
    final tier = VideoDecodeChain.tier(tierIndex);
    _tierIndex = tierIndex;
    _stallHits = 0;
    _firstFrameSeen = false;
    _hwDecodeObserved = false;
    _videoParamsSeen = false;
    _watchdogArmed = false;
    _watchdog?.cancel();
    _promoteTimer?.cancel();
    VideoPlayerPage.debugActiveTier = tierIndex;
    VideoPlayerPage.debugActiveTierStalls.clear();
    appLog('video decode tier -> ${tier.label} '
        '(hwdec=${tier.hwdec}, gen=$gen, resume=${seekTo?.inMilliseconds ?? 0}ms)');

    // tear the previous stack down first: one SurfaceTexture per player, and
    // two live mpv instances competing for MediaCodec is exactly the kind of
    // resource contention we are trying to diagnose.
    final oldPlayer = _player;
    final oldSubs = List<StreamSubscription<dynamic>>.from(_subs);
    _subs.clear();
    _player = null;
    if (_videoController != null && mounted) {
      setState(() => _videoController = null);
    }
    for (final s in oldSubs) {
      await s.cancel();
    }
    if (oldPlayer != null) {
      try {
        await oldPlayer.pause();
      } catch (_) {}
      try {
        await oldPlayer.dispose();
      } catch (_) {}
    }
    if (!mounted || gen != _generation) return;

    try {
      final player = await Player.create(
        configuration: PlayerConfiguration(
          logLevel: MPVLogLevel.warn,
          options: {
            // Only the software rung may fall back to ffmpeg on its own: on
            // the hardware rungs a silent fallback would hide the very
            // failure we are trying to detect and report.
            'vd-lavc-software-fallback': tier.hardware ? 'no' : 'yes',
            // display-referenced A/V sync (PiliPlus default): a flaky audio
            // device (underruns) must NOT stall the video clock — with mpv's
            // default video-sync=audio, audio underruns froze the renderer
            // (vo/gpu frame pile-up, black picture)
            'video-sync': 'display-resample',
            // audio backend fallback chain across Android AOs
            'ao': 'opensles,aaudio,audiotrack',
            // gentler audio-resync ramp (PiliPlus Android default)
            'autosync': '30',
            'volume': '100',
          },
        ),
      );
      if (!mounted || gen != _generation) {
        await player.dispose();
        return;
      }
      _player = player;
      _subs.addAll([
        player.stream.error.listen((e) => _onError(gen, e)),
        player.stream.log.listen((l) => _onMpvLog(gen, l)),
        player.stream.videoParams.listen((v) => _onVideoParams(gen, v)),
        player.stream.playing.listen((v) {
          if (mounted && gen == _generation) setState(() => _playing = v);
        }),
        player.stream.completed.listen((v) {
          if (mounted && gen == _generation) setState(() => _completed = v);
        }),
        player.stream.position.listen((v) {
          VideoPlayerPage.debugLastPosition = v;
          if (mounted && gen == _generation) setState(() => _position = v);
        }),
        player.stream.duration.listen((v) {
          if (mounted && gen == _generation) setState(() => _duration = v);
        }),
      ]);

      if (tierIndex == 0) {
        // first attempt of this page instance: forensic snapshot of the file
        await _logFileIntegrity();
        appLog('video open: ${widget.path} (media_kit/mpv tier=${tier.label})');
      }

      final vc = await VideoController.create(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: tier.hardware,
          hwdec: tier.hwdec,
          androidAttachSurfaceAfterVideoParameters: false,
        ),
      );
      if (!mounted || gen != _generation) {
        await player.dispose();
        return;
      }
      setState(() => _videoController = vc);

      // the SurfaceTexture's first onFrameAvailable → the renderer really
      // produced a picture (not just "the decoder is configured")
      unawaited(vc.waitUntilFirstFrameRendered.then((_) {
        if (gen != _generation) return;
        _firstFrameSeen = true;
        _watchdog?.cancel();
        appLog('video first frame rendered (tier=${tier.label})');
        _schedulePromotion();
      }).catchError((Object _) {}));

      await player.open(
        Media(widget.path, extras: {'cache': 'no'}),
        play: true,
      );
      if (gen != _generation) return;
      if (seekTo != null && seekTo > Duration.zero) {
        await player.seek(seekTo);
      }
      // fallback arming in case no video-params event ever reaches us (the
      // watchdog body is a no-op once a first frame has been seen)
      _armWatchdog(gen, tier);
      if (tierIndex == 0) {
        // let the render pipeline spin up, then snapshot native chatter
        Future.delayed(const Duration(seconds: 3), () {
          captureOwnLogcat('video-post');
        });
      }
    } catch (e) {
      appLog('video init FAILED (tier=${tier.label}): ${widget.path} err=$e');
      if (mounted && gen == _generation) {
        setState(() {
          _failed = true;
          _error = '$e';
        });
      }
    }
  }

  /// Arm the "decoder is running but nothing ever reaches the screen"
  /// watchdog. Called once per generation, when the first video-params with a
  /// real geometry arrive — i.e. when decoding has demonstrably started.
  ///
  /// This is the safety net for stalls that do NOT leave an aimagereader
  /// fingerprint (a different broken interop, a codec that decodes but never
  /// maps). On the last rung there is nothing left to downgrade to, so it just
  /// logs.
  void _armWatchdog(int gen, VideoDecodeTier tier) {
    if (_watchdogArmed) return;
    _watchdogArmed = true;
    _watchdog?.cancel();
    _watchdog = Timer(tier.firstFrameTimeout, () {
      if (gen != _generation || _firstFrameSeen || !mounted) return;
      appLog('video watchdog: ${tier.label} produced no rendered frame in '
          '${tier.firstFrameTimeout.inSeconds}s '
          '(paramsSeen=$_videoParamsSeen hwdec=$_hwDecodeObserved) '
          '-> downgrading');
      unawaited(_downgrade(
          'watchdog: no first frame in ${tier.firstFrameTimeout.inSeconds}s'));
    });
  }

  /// Playback stayed healthy on this rung for a while → remember it, so the
  /// next video on this device starts here instead of re-probing.
  void _schedulePromotion() {
    _promoteTimer?.cancel();
    final gen = _generation;
    final tier = _tierIndex;
    _promoteTimer = Timer(const Duration(seconds: 10), () {
      if (gen != _generation || !mounted) return;
      VideoDecodeChain.instance.remember(tier);
      appLog('video decode tier $tier settled (remembered for this device)');
    });
  }

  Future<void> _downgrade(String reason) async {
    if (_switching) return;
    final next = _tierIndex + 1;
    if (next >= VideoDecodeChain.tiers.length) {
      appLog('video decode chain exhausted ($reason) — no lower rung');
      return;
    }
    _switching = true;
    _watchdog?.cancel();
    _promoteTimer?.cancel();
    VideoPlayerPage.debugDowngrades++;
    final resume = _position;
    appLog('video downgrade ${_tier.label} -> '
        '${VideoDecodeChain.tier(next).label}: $reason '
        '(position=${resume.inMilliseconds}ms)');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(L.t.videoDecoderSwitch(VideoDecodeChain.tier(next).label)),
        duration: const Duration(seconds: 3),
      ));
    }
    await _openAt(next, seekTo: resume);
    _switching = false;
  }

  // ------------------------------------------------------------- mpv hooks

  void _onError(int gen, String e) {
    if (e.isEmpty) return;
    VideoPlayerPage.debugLastError = e;
    appLog('mpv error: ${widget.path} -> $e');
    if (!mounted || gen != _generation) return;
    setState(() {
      _failed = true;
      _error = e;
    });
  }

  void _onMpvLog(int gen, PlayerLog l) {
    final line = 'mpv[${l.prefix}/${l.level}] ${l.text}';
    VideoPlayerPage.debugMpvLogs.add(line);
    if (VideoPlayerPage.debugMpvLogs.length > 500) {
      VideoPlayerPage.debugMpvLogs
          .removeRange(0, VideoPlayerPage.debugMpvLogs.length - 500);
    }
    appLog(line);
    if (gen != _generation || _firstFrameSeen) return;
    // the on-device black-screen fingerprint: mpv's zero-copy MediaCodec
    // interop cannot pull a single frame out of its AImageReader
    if (VideoDecodeChain.isStallLine(line)) {
      _stallHits++;
      VideoPlayerPage.debugActiveTierStalls.add(line);
      if (_stallHits >= VideoDecodeChain.stallHitsToDowngrade) {
        final hits = _stallHits;
        // Deferred on purpose: we are INSIDE this player's log callback, and
        // media_kit delivers events on its native event loop — disposing the
        // player from there can deadlock. One event-loop turn is enough for
        // the callback to unwind.
        unawaited(Future<void>.delayed(Duration.zero, () {
          if (!mounted || gen != _generation) return;
          return _downgrade('renderer stall ($hits x aimagereader)');
        }));
      }
    }
  }

  void _onVideoParams(int gen, VideoParams v) {
    final text = v.toString();
    VideoPlayerPage.debugLastVideoParams = text;
    appLog('mpv video params: ${widget.path} -> $text');
    if (gen != _generation) return;
    if (VideoDecodeChain.paramsLookHardware(text)) {
      _hwDecodeObserved = true;
    }
    // a real geometry (w/h present) means a video track is actually being
    // decoded; the all-null params mpv emits while switching tracks do not
    if (v.w != null && v.h != null && v.w != 0) {
      _videoParamsSeen = true;
      _armWatchdog(gen, _tier);
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

  /// "视频解码: <rung>[ · 软解渲染]" — makes a field report readable without
  /// exporting logs.
  String _decoderNote() {
    final sw = _hwDecodeObserved ? '' : ' · ${L.t.videoDecoderSwActive}';
    return '${L.t.videoDecoder}: ${_tier.label}$sw';
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    _generation++;
    _watchdog?.cancel();
    _promoteTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
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
                    Text(L.t.videoDecoderChainNote,
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
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
                            onChanged: (v) => _player
                                ?.seek(Duration(milliseconds: v.toInt())),
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
                  // which decode rung is currently feeding the picture —
                  // makes a field report ("it fell back to copy/software")
                  // readable without exporting logs
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(_decoderNote(),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 10.5)),
                  ),
                ],
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
