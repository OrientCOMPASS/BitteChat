// 视频播放页 与 文本文件预览页
//
// 视频栈 = media_kit（libmpv，PiliPala/PiliPlus 同源方案）：
//   * 渲染：mpv 经 EGL 渲染进 SurfaceTexture（`--vo=gpu`），与 PiliPlus 一致的
//     成熟路径（fvp/mdk 在部分机型上"有声无画"，见 flutter#159503 / fvp#235
//     一类外部纹理合成问题；本项目实机测试确认后整体切换到该方案）。
//   * 解码：**分级降级链**（见 core/video_decode.dart）。mpv 的零拷贝 interop
//     在部分机型上会「解码器在跑、一帧都渲染不出来」且自身不回退（实机指纹
//     `vo/gpu/aimagereader … Waiting for frame timed out! / acquireLatestImage
//     failed: -30001`），所以从 v0.5.6 起按「零拷贝硬解 → 硬解回读 → 软解」
//     三档自动降级续播，并把该机型最终可用的档位记下来。
//   * 播放体验（v0.5.8）：单击画面**切换控制条显隐**（隐藏时进入沉浸模式，
//     3 秒无操作自动隐藏）；**画面上左右滑动微调进度**（带目标位置预览）；
//     **按视频宽高比自动决定全屏方向**（宽→横屏、竖→竖屏，离开页面恢复）；
//     「用其他应用打开」移到**右上角**；**倍速 0.5×–3×**。降级到**软解**档时
//     用 SnackBar 明确告知（硬解不支持该编码），不再常驻显示解码档位。
//   * 音频抢断（v0.5.8）：出声即经 core/media_focus.dart 申请 **Android 音频
//     焦点（AUDIOFOCUS_GAIN）**，让系统里其他正在播放的媒体暂停；并停掉应用内
//     另一个媒体（视频 ↔ 语音条互斥）；用户暂停 / 系统夺焦时不会把焦点抢回来。
//   * 诊断（v0.5.7 起瘦身）：mpv 的逐行日志只进内存（供降级判定与 CI 断言），
//     落盘的只有 error 级 + 每代前两条停摆指纹 + 档位/首帧/降级事件；logcat
//     快照只在**降级或报错时**采集，正常播放不再写那两大段。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/applog.dart';
import '../core/files.dart';
import '../core/l10n.dart';
import '../core/media_focus.dart';
import '../core/prefs.dart';
import '../core/video_decode.dart';
import '../widgets/audio_row.dart';

/// Playback rates offered in the speed menu (capped at 3× per product call).
const List<double> kPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.path,
    required this.title,
    this.prefs,
  });

  final String path;
  final String title;

  /// Playback preferences (double-tap side-seek / long-press speed / default
  /// speed) come from the shared [UiPrefs] (Settings → Playback). Nullable so
  /// the page still works in demo/test contexts without prefs.
  final UiPrefs? prefs;

  bool get _sideSeekOn => prefs?.playDoubleTapSideSeek ?? false;
  double get _longPressSpeed => prefs?.playLongPressSpeed ?? 2.0;

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
  double _rate = 1.0;
  final List<StreamSubscription<dynamic>> _subs = [];

  // --- control chrome auto-hide -------------------------------------------
  bool _uiVisible = true;
  Timer? _uiTimer;
  static const Duration _uiHideAfter = Duration(seconds: 3);

  // --- drag-to-seek: swipe left/right on the picture to fine-tune progress -
  bool _dragging = false;
  double _dragAccum = 0.0;
  Duration _dragStartPos = Duration.zero;
  Duration _dragTargetPos = Duration.zero;

  // --- fullscreen orientation derived from the video aspect ratio ---------
  bool _orientationApplied = false;

  // --- one-shot "we fell back to software decode" notice ------------------
  bool _notifiedSoftware = false;

  // --- v0.5.9 player UX (PiliPlus-inspired, filtered) --------------------
  bool _locked = false;
  BoxFit _fit = BoxFit.contain;
  bool _longPressSpeedActive = false;

  // double-tap side-seek flash (signed seconds), cleared after a beat
  int? _seekFlash;
  Timer? _seekFlashTimer;

  // vertical-drag OSD: volume (right half) / brightness (left half)
  double? _osdLevel;
  IconData? _osdIcon;
  Timer? _osdTimer;
  bool _vertBrightness = false;
  double? _brightness; // cached 0..1 screen brightness, fetched once
  double _volume = 100; // our own 0..100 volume; mpv read-back is too slow
  bool _volumeReady = false;
  String? _volumeModeInit;

  // subtitles (embedded tracks + optional external file)
  List<SubtitleTrack> _subtitleTracks = const [];
  String _activeSubtitleId = '';

  // --- decode chain state -------------------------------------------------
  int _generation = 0;
  int _tierIndex = 0;
  int _stallHits = 0;
  int _stallLogged = 0;
  String? _loggedParams;
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
    _rate = widget.prefs?.playDefaultSpeed ?? 1.0;
    _loadBrightness();
    WidgetsBinding.instance.addObserver(this);
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
      AppLog.breadcrumb('video lifecycle:$state');
    }
  }

  // ------------------------------------------------------------ audio focus

  /// Take over the audio path through the shared [MediaFocus]: stops the
  /// in-app voice row, then asks Android to interrupt whatever else is playing
  /// (music app, browser…) — the actual "playback preemption".
  Future<void> _acquireFocus() async {
    // Acquire first: a hand-off from the voice row keeps the system focus (no
    // abandon/re-request blip in other apps) and pauses it; then fully stop the
    // shared voice player. release() inside stopAll() is a no-op once we own it.
    await MediaFocus.instance.acquire(this, _onFocusLost);
    await SharedVoicePlayer.stopAll();
  }

  /// Android revoked our focus (another app grabbed it / a call came in):
  /// pause, and block the next `playing=true` from stealing focus straight
  /// back until playback genuinely stops or the page closes.
  Future<void> _onFocusLost() async {
    final p = _player;
    if (p != null && _playing) {
      try {
        await p.pause();
      } catch (_) {}
    }
    await MediaFocus.instance.setAcceptGain(false);
  }

  Future<void> _releaseFocus() => MediaFocus.instance.release(this);

  // ---------------------------------------------------------------- chrome

  void _setUiVisible(bool v) {
    if (_uiVisible == v) return;
    setState(() => _uiVisible = v);
    // immersive while the chrome is hidden so "fullscreen" really is full
    SystemChrome.setEnabledSystemUIMode(
      v ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  void _showUi() {
    _uiTimer?.cancel();
    _setUiVisible(true);
    _scheduleHideUi();
  }

  void _scheduleHideUi() {
    _uiTimer?.cancel();
    if (!_playing) return; // paused / failed: keep the controls reachable
    _uiTimer = Timer(_uiHideAfter, () {
      if (mounted && _uiVisible && _playing) _setUiVisible(false);
    });
  }

  void _toggleUi() {
    if (_uiVisible) {
      _uiTimer?.cancel();
      _setUiVisible(false);
    } else {
      _showUi();
    }
  }

  // ------------------------------------------------------------- seek drag

  /// A full screen-width of horizontal drag scrubs this many seconds — fine
  /// enough to "微调" the position without jumping the whole timeline.
  static const double _seekSecondsPerScreenWidth = 90;

  void _onSeekDragStart(DragStartDetails d) {
    _uiTimer?.cancel();
    _dragAccum = 0;
    _dragStartPos = _position;
    _dragTargetPos = _position;
    setState(() => _dragging = true);
  }

  void _onSeekDragUpdate(DragUpdateDetails d) {
    final width = MediaQuery.sizeOf(context).width;
    final span = width > 0 ? width : 1;
    _dragAccum += d.delta.dx;
    var targetMs = _dragStartPos.inMilliseconds +
        (_dragAccum / span * _seekSecondsPerScreenWidth * 1000).round();
    final maxMs = _duration.inMilliseconds;
    if (maxMs > 0) {
      targetMs = targetMs.clamp(0, maxMs).toInt();
    } else if (targetMs < 0) {
      targetMs = 0;
    }
    setState(() => _dragTargetPos = Duration(milliseconds: targetMs));
  }

  void _onSeekDragEnd(DragEndDetails d) {
    final target = _dragTargetPos;
    setState(() => _dragging = false);
    try {
      _player?.seek(target);
    } catch (e) {
      appLog('video drag-seek failed: $e');
    }
    // reflect the scrub immediately; the position stream reconciles it
    setState(() => _position = target);
    _showUi();
  }

  /// `+01:23` / `-00:45` — the scrub delta shown under the target position.
  static String _fmtDelta(Duration d) {
    final a = d.abs();
    final sign = d.isNegative ? '-' : '+';
    final m = a.inMinutes.toString().padLeft(2, '0');
    final s = a.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$sign$m:$s';
  }

  // ------------------------------------------------- v0.5.9 gesture extras

  static const MethodChannel _mediaCh = MethodChannel('bittechat/media');

  /// Relative/absolute seek used by double-tap side-seek.
  Future<void> _seekBy(Duration delta) async {
    final upper = _duration > Duration.zero ? _duration : _position;
    final ms =
        (_position + delta).inMilliseconds.clamp(0, upper.inMilliseconds);
    final target = Duration(milliseconds: ms);
    try {
      await _player?.seek(target);
    } catch (_) {}
    if (mounted) setState(() => _position = target);
  }

  void _flashSeek(int seconds) {
    _seekFlashTimer?.cancel();
    setState(() => _seekFlash = seconds);
    _seekFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFlash = null);
    });
  }

  /// Double-tap: centre = play/pause; left/right = ∓/+10s **only when the
  /// user enabled it** (Settings → Playback), otherwise centre behaviour.
  void _onDoubleTapDown(TapDownDetails d) {
    if (_locked || _failed) return;
    final width = MediaQuery.sizeOf(context).width;
    final x = d.localPosition.dx;
    final sideSeek = widget._sideSeekOn;
    if (sideSeek && width > 0 && x < width * 0.25) {
      _seekBy(const Duration(seconds: -10));
      _flashSeek(-10);
    } else if (sideSeek && width > 0 && x > width * 0.75) {
      _seekBy(const Duration(seconds: 10));
      _flashSeek(10);
    } else {
      _playPause();
    }
  }

  /// Long-press: temporary speed boost (multiplier from Settings), restored
  /// on release.
  void _onLongPressStart(LongPressStartDetails d) {
    if (_locked || _failed) return;
    _longPressSpeedActive = true;
    _player?.setRate(widget._longPressSpeed).catchError((_) {});
    if (mounted) setState(() {});
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    if (!_longPressSpeedActive) return;
    _longPressSpeedActive = false;
    _player?.setRate(_rate).catchError((_) {});
    if (mounted) setState(() {});
  }

  /// Vertical drag: left half = screen brightness, right half = volume, each
  /// with a centre OSD (PiliPlus-style).
  void _onVerticalDragStart(DragStartDetails d) {
    if (_locked || _failed) return;
    final width = MediaQuery.sizeOf(context).width;
    _vertBrightness = d.localPosition.dx < width / 2;
    if (!_vertBrightness) unawaited(_ensureVolumeBase());
    _uiTimer?.cancel();
  }

  /// Seed [_volume] from the ACTIVE target (system stream by default, mpv
  /// volume when the user switched) so the OSD and increments start right.
  Future<void> _ensureVolumeBase() async {
    final mode = widget.prefs?.playVolumeMode ?? 'system';
    if (_volumeReady && _volumeModeInit == mode) return;
    _volumeModeInit = mode;
    if (mode == 'system') {
      try {
        final v = await _mediaCh.invokeMethod<double>('getSystemVolume');
        _volume = v == null ? 100 : (v * 100).clamp(0.0, 100.0);
      } catch (_) {
        _volume = 100;
      }
    } else {
      _volume = 100;
    }
    _volumeReady = true;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (_locked || _failed) return;
    final height = MediaQuery.sizeOf(context).height;
    final span = height > 0 ? height : 1;
    // dragging UP (negative dy) increases the level; applied incrementally
    // from the current value so a continued drag stays monotonic
    if (_vertBrightness) {
      final cur = _brightness ?? 0.5;
      final next = (cur - d.delta.dy / span).clamp(0.02, 1.0);
      _brightness = next;
      _setBrightness(next);
      _showOsd(Icons.brightness_high, next);
    } else {
      if (!_volumeReady) return;
      final next = (_volume - d.delta.dy / span * 100).clamp(0.0, 100.0);
      _volume = next;
      if ((widget.prefs?.playVolumeMode ?? 'system') == 'system') {
        _mediaCh.invokeMethod<bool>(
            'setSystemVolume', {'value': next / 100}).catchError((_) => true);
      } else {
        _player?.setVolume(next).catchError((_) {});
      }
      _showOsd(Icons.volume_up, next / 100);
    }
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_locked || _failed) return;
    _hideOsdSoon();
  }

  void _showOsd(IconData icon, double level) {
    _osdTimer?.cancel();
    setState(() {
      _osdIcon = icon;
      _osdLevel = level;
    });
    _hideOsdSoon();
  }

  void _hideOsdSoon() {
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _osdLevel = null);
    });
  }

  Future<void> _loadBrightness() async {
    try {
      final v = await _mediaCh.invokeMethod<double>('getBrightness');
      if (v != null && mounted) _brightness = v.clamp(0.02, 1.0);
    } catch (_) {/* no native channel (desktop/tests): skip */}
  }

  Future<void> _setBrightness(double v) async {
    try {
      await _mediaCh.invokeMethod<bool>('setBrightness', {'value': v});
    } catch (_) {}
  }

  /// Cycle contain → cover → fill, naming the new mode briefly.
  void _cycleFit() {
    setState(() {
      _fit = _fit == BoxFit.contain
          ? BoxFit.cover
          : _fit == BoxFit.cover
              ? BoxFit.fill
              : BoxFit.contain;
    });
    final label = _fit == BoxFit.contain
        ? L.t.fitContain
        : _fit == BoxFit.cover
            ? L.t.fitCover
            : L.t.fitFill;
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
            content: Text(label), duration: const Duration(milliseconds: 900)));
    }
  }

  void _toggleLock() {
    setState(() {
      _locked = !_locked;
      if (_locked) {
        _uiTimer?.cancel();
        _setUiVisible(false);
      } else {
        _showUi();
      }
    });
  }

  /// Subtitle picker: embedded tracks + "off" + load an external file.
  Future<void> _openSubtitleMenu() async {
    _uiTimer?.cancel();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.subtitles_off_outlined),
              title: Text(L.t.subtitleOff),
              onTap: () => Navigator.pop(ctx, 'no'),
            ),
            if (_subtitleTracks.isEmpty)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(L.t.subtitleNoTracks,
                    style: Theme.of(ctx).textTheme.bodySmall),
              ),
            for (final t in _subtitleTracks)
              ListTile(
                leading: Icon(t.id == _activeSubtitleId
                    ? Icons.check_circle
                    : Icons.subtitles_outlined),
                title: Text(t.title ?? t.language ?? '#${t.id}'),
                onTap: () => Navigator.pop(ctx, t.id),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: Text(L.t.subtitleExternal),
              onTap: () => Navigator.pop(ctx, 'external'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final p = _player;
    if (p == null) return;
    try {
      if (picked == 'no') {
        await p.setSubtitleTrack(SubtitleTrack.no());
        setState(() => _activeSubtitleId = '');
      } else if (picked == 'external') {
        final files = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['srt', 'ass', 'ssa', 'vtt', 'sub'],
        );
        final path = files.isEmpty ? null : files.first.path;
        if (path != null && mounted) {
          await p.setSubtitleTrack(SubtitleTrack.uri(path));
          setState(() => _activeSubtitleId = path);
        }
      } else {
        final track = _subtitleTracks.firstWhere((t) => t.id == picked);
        await p.setSubtitleTrack(track);
        setState(() => _activeSubtitleId = picked);
      }
    } catch (e) {
      appLog('subtitle select failed: $e');
    }
    _showUi();
  }

  Future<void> _setRate(double v) async {
    setState(() => _rate = v);
    try {
      await _player?.setRate(v);
    } catch (e) {
      appLog('video setRate($v) failed: $e');
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
    _stallLogged = 0;
    _loggedParams = null;
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
    AppLog.breadcrumb('video open tier=${tier.label} gen=$gen');

    // The last rung is software decode — the hardware decoder could not handle
    // this codec. Tell the user once (a SnackBar over the fullscreen picture)
    // rather than keeping a persistent decode readout on screen.
    if (!tier.hardware && !_notifiedSoftware) {
      _notifiedSoftware = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(L.t.videoSoftwareDecodeNotice),
          duration: const Duration(seconds: 5),
        ));
      }
    }

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
        player.stream.playing.listen((v) => _onPlaying(gen, v)),
        player.stream.completed.listen((v) {
          if (mounted && gen == _generation) {
            setState(() => _completed = v);
            if (v) _showUi();
          }
        }),
        player.stream.position.listen((v) {
          VideoPlayerPage.debugLastPosition = v;
          if (mounted && gen == _generation) setState(() => _position = v);
        }),
        player.stream.duration.listen((v) {
          if (mounted && gen == _generation) setState(() => _duration = v);
        }),
        player.stream.tracks.listen((t) {
          if (mounted && gen == _generation) {
            setState(() {
              // media_kit exposes pseudo-tracks 'auto'/'no' — hide them so the
              // picker only lists real subtitle streams (off is a menu item).
              _subtitleTracks = t.subtitle
                  .where((s) => s.id != 'auto' && s.id != 'no')
                  .toList();
              final sel = _subtitleTracks.where((s) => s.selected);
              _activeSubtitleId = sel.isEmpty ? '' : sel.first.id;
            });
          }
        }),
      ]);

      if (tierIndex == 0) {
        // one forensic line about the file on disk (cheap, and it settles
        // "player broken" vs "half a mp4" without a log export round-trip)
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
      if (_rate != 1.0) await player.setRate(_rate);
      if (seekTo != null && seekTo > Duration.zero) {
        await player.seek(seekTo);
      }
      // fallback arming in case no video-params event ever reaches us (the
      // watchdog body is a no-op once a first frame has been seen)
      _armWatchdog(gen, tier);
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

  void _onPlaying(int gen, bool v) {
    if (!mounted || gen != _generation) return;
    setState(() => _playing = v);
    if (v) {
      // re-arm focus, then take it over: this is what pauses the system's
      // other "now playing" media (and our own voice row) instead of mixing
      unawaited(MediaFocus.instance.setAcceptGain(true));
      unawaited(_acquireFocus());
      _scheduleHideUi();
    } else {
      // user/system paused: do NOT yank focus back on the next playing=true
      unawaited(MediaFocus.instance.setAcceptGain(false));
      _showUi();
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
    // the logcat snapshot is a *diagnostic* capture: only pay for it when
    // something actually went wrong
    captureOwnLogcat('video-stall');
    // NB: no "switched decoder" toast here — the decode rung is an internal
    // detail. The user is only told when we land on SOFTWARE decode (see
    // _openAt), which is the one rung worth surfacing.
    await _openAt(next, seekTo: resume);
    _switching = false;
  }

  // ------------------------------------------------------------- mpv hooks

  void _onError(int gen, String e) {
    if (e.isEmpty) return;
    VideoPlayerPage.debugLastError = e;
    appLog('mpv error: ${widget.path} -> $e');
    captureOwnLogcat('video-error');
    if (!mounted || gen != _generation) return;
    setState(() {
      _failed = true;
      _error = e;
    });
  }

  /// mpv chatter: kept in memory in full (the CI test and the downgrade
  /// detector read it), but only ERROR lines and the first two stall
  /// signatures of a generation reach the on-disk log — a healthy playback
  /// writes four short lines instead of dozens.
  void _onMpvLog(int gen, PlayerLog l) {
    final line = 'mpv[${l.prefix}/${l.level}] ${l.text}';
    VideoPlayerPage.debugMpvLogs.add(line);
    if (VideoPlayerPage.debugMpvLogs.length > 500) {
      VideoPlayerPage.debugMpvLogs
          .removeRange(0, VideoPlayerPage.debugMpvLogs.length - 500);
    }
    final stall = VideoDecodeChain.isStallLine(line);
    // PlayerLog.level is a STRING (mpv's level name), not MPVLogLevel
    if (l.level == 'error' || (stall && _stallLogged < 2)) {
      if (stall) _stallLogged++;
      appLog(line);
    }
    if (gen != _generation || _firstFrameSeen) return;
    // the on-device black-screen fingerprint: mpv's zero-copy MediaCodec
    // interop cannot pull a single frame out of its AImageReader
    if (stall) {
      _stallHits++;
      VideoPlayerPage.debugActiveTierStalls.add(line);
      if (_stallHits >= VideoDecodeChain.stallHitsToDowngrade) {
        final hits = _stallHits;
        // Deferred on purpose: we are INSIDE this player's log callback, and
        // media_kit delivers events on its native event loop — disposing the
        // player from there can deadlock. One event-loop turn is enough for
        // the callback to unwind.
        unawaited(Future<void>.delayed(Duration.zero, () async {
          if (!mounted || gen != _generation) return;
          await _downgrade('renderer stall ($hits x aimagereader)');
        }));
      }
    }
  }

  void _onVideoParams(int gen, VideoParams v) {
    final text = v.toString();
    VideoPlayerPage.debugLastVideoParams = text;
    if (gen != _generation) return;
    if (VideoDecodeChain.paramsLookHardware(text)) {
      _hwDecodeObserved = true;
    }
    // a real geometry (w/h present) means a video track is actually being
    // decoded; the all-null params mpv emits while switching tracks do not
    if (v.w != null && v.h != null && v.w != 0) {
      _videoParamsSeen = true;
      _applyOrientation(v);
      _armWatchdog(gen, _tier);
      // one compact line per generation instead of every params event
      if (_loggedParams != text) {
        _loggedParams = text;
        appLog('video params: ${v.w}x${v.h} fmt=${v.pixelformat} '
            'hw=${v.hwPixelformat} rotate=${v.rotate}');
      }
    }
  }

  /// Lock the fullscreen orientation to the picture's aspect ratio: a wide
  /// video plays landscape, a tall one portrait (PiliPlus-style). Applied once
  /// per page; [dispose] restores the system/sensor default.
  void _applyOrientation(VideoParams v) {
    if (_orientationApplied) return;
    final w = v.w ?? 0;
    final h = v.h ?? 0;
    if (w == 0 || h == 0) return;
    // mpv reports the stored frame plus a rotation to apply; 90/270 swap the
    // displayed axes. `rotate` is a nullable int (degrees).
    final rot = (v.rotate ?? 0).toDouble().abs() % 360;
    final swap = (rot - 90).abs() < 0.5 || (rot - 270).abs() < 0.5;
    final dw = swap ? h : w;
    final dh = swap ? w : h;
    _orientationApplied = true;
    final landscape = dw >= dh;
    SystemChrome.setPreferredOrientations(landscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ]);
    appLog('video orientation: ${dw}x$dh rotate=$rot -> '
        '${landscape ? "landscape" : "portrait"}');
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
    _showUi();
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
    _uiTimer?.cancel();
    _osdTimer?.cancel();
    _seekFlashTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (_orientationApplied) {
      // restore the app's default (system/sensor) orientation on the way out
      SystemChrome.setPreferredOrientations(const []);
    }
    // leaving the page ends this media session: re-arm focus for the next one
    unawaited(MediaFocus.instance.setAcceptGain(true));
    unawaited(_releaseFocus());
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

  Widget _buildOsd() {
    return Center(
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_osdIcon, color: Colors.white, size: 28),
              const SizedBox(height: 8),
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(
                  value: _osdLevel,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(height: 4),
              Text('${((_osdLevel ?? 0) * 100).round()}%',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSeekFlash() {
    final s = _seekFlash ?? 0;
    return Center(
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(s < 0 ? Icons.fast_rewind : Icons.fast_forward,
                  color: Colors.white, size: 24),
              const SizedBox(width: 6),
              Text('${s.abs()}s',
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedChip() {
    return Positioned(
      top: 16,
      left: 0,
      right: 0,
      child: Center(
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '${_fmtRate(widget._longPressSpeed)} ${L.t.speedActive}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockButton() {
    return Positioned(
      left: 8,
      top: 0,
      bottom: 0,
      child: Center(
        child: IconButton(
          tooltip: _locked ? L.t.unlockControls : L.t.lockControls,
          style: IconButton.styleFrom(backgroundColor: Colors.black38),
          icon: Icon(_locked ? Icons.lock_outline : Icons.lock_open,
              color: Colors.white),
          onPressed: _toggleLock,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vc = _videoController;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // picture. media_kit's Video embeds an InteractiveViewer (a scale
          // recognizer), and an ANCESTOR GestureDetector with the default
          // deferToChild behaviour never reliably wins the arena against it —
          // that is what made single-finger gestures dead. So the picture
          // carries no gestures; the opaque layer added right below sits
          // ABOVE it in the Stack, and RenderStack stops hit-testing at the
          // first hit child: the layer receives every pointer in the play
          // area and simultaneously shields the InteractiveViewer.
          _failed
              ? _failurePane()
              : vc == null
                  ? const Center(child: CircularProgressIndicator())
                  : Video(
                      controller: vc,
                      controls: NoVideoControls,
                      fit: _fit,
                      fill: Colors.black,
                      scaleEnabled: false,
                    ),
          // single-finger gesture layer: tap = toggle chrome, double-tap =
          // play/pause (or ±10s when enabled), horizontal drag = seek,
          // vertical drag = brightness (left) / volume (right),
          // long-press = temporary speed
          if (!_failed && vc != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _locked ? null : _toggleUi,
                onDoubleTapDown: _onDoubleTapDown,
                onLongPressStart: _onLongPressStart,
                onLongPressEnd: _onLongPressEnd,
                onHorizontalDragStart: _locked ? null : _onSeekDragStart,
                onHorizontalDragUpdate: _locked ? null : _onSeekDragUpdate,
                onHorizontalDragEnd: _locked ? null : _onSeekDragEnd,
                onVerticalDragStart: _locked ? null : _onVerticalDragStart,
                onVerticalDragUpdate: _locked ? null : _onVerticalDragUpdate,
                onVerticalDragEnd: _locked ? null : _onVerticalDragEnd,
              ),
            ),
          // drag-to-seek preview: target position + delta from where we began
          if (_dragging)
            Center(
              child: IgnorePointer(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${_fmt(_dragTargetPos)} / ${_fmt(_duration)}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 18)),
                      const SizedBox(height: 2),
                      Text(_fmtDelta(_dragTargetPos - _dragStartPos),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ),
          // vertical-drag OSD (volume / brightness)
          if (_osdLevel != null && _osdIcon != null) _buildOsd(),
          // double-tap side-seek flash
          if (_seekFlash != null) _buildSeekFlash(),
          // long-press temporary-speed indicator
          if (_longPressSpeedActive) _buildSpeedChip(),
          // lock / unlock on the left edge — the only control while locked
          if (!_failed && (_uiVisible || _locked)) _buildLockButton(),
          // top chrome — CONTROLS ONLY. No gradient Container and no AppBar:
          // a decorated / Material strip is hit-testable across its whole
          // band, which is exactly the "mask" that blocked play-area gestures
          // while the UI was visible (and the black gradient shadow nobody
          // wanted). Plain Align/Padding/Row are not hit-testable themselves,
          // so only the buttons absorb pointers; everything else falls
          // through to the gesture layer below.
          Align(
            alignment: Alignment.topCenter,
            child: AnimatedOpacity(
              opacity: _uiVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_uiVisible,
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            IconButton(
                              color: Colors.white,
                              icon: const Icon(Icons.arrow_back),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            Expanded(
                              child: Text(widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 15)),
                            ),
                            IconButton(
                              color: Colors.white,
                              tooltip: L.t.subtitle,
                              icon: const Icon(Icons.subtitles_outlined,
                                  size: 20),
                              onPressed: _openSubtitleMenu,
                            ),
                            IconButton(
                              color: Colors.white,
                              tooltip: _fit == BoxFit.contain
                                  ? L.t.fitContain
                                  : _fit == BoxFit.cover
                                      ? L.t.fitCover
                                      : L.t.fitFill,
                              icon: const Icon(Icons.aspect_ratio, size: 20),
                              onPressed: _cycleFit,
                            ),
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
                    ],
                  ),
                ),
              ),
            ),
          ),
          // bottom chrome — controls only (same reasoning as top chrome)
          Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedOpacity(
              opacity: _uiVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_uiVisible,
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            IconButton(
                              color: Colors.white,
                              icon: Icon(
                                  _playing ? Icons.pause : Icons.play_arrow),
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
                            PopupMenuButton<double>(
                              tooltip: L.t.videoSpeed,
                              color: Colors.black87,
                              onOpened: () {
                                _uiTimer?.cancel();
                              },
                              onSelected: _setRate,
                              itemBuilder: (_) => [
                                for (final r in kPlaybackRates)
                                  PopupMenuItem(
                                    value: r,
                                    child: Text(
                                      '${_fmtRate(r)}${r == _rate ? '  ✓' : ''}',
                                      style: TextStyle(
                                          color: r == _rate
                                              ? Colors.white
                                              : Colors.white70),
                                    ),
                                  ),
                              ],
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                child: Text(_fmtRate(_rate),
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 13)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `0.5× / 1.0× / 1.25× / 3.0×` — one decimal keeps the menu column tidy.
  static String _fmtRate(double r) =>
      r == r.roundToDouble() ? '${r.toInt()}.0×' : '$r×';

  Widget _failurePane() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(L.t.videoFail, style: const TextStyle(color: Colors.white70)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(L.t.openWith),
              onPressed: () => openWithExternalApp(widget.path, 'video/*'),
            ),
            const SizedBox(height: 8),
            Text(L.t.videoDecoderTip,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
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
