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
  /// speed) come from the shared [UiPrefs] (Settings → Playback).
  final UiPrefs? prefs;

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

/// v0.5.12 rewrite, modelled on PiliPlus's player (pl_player): the picture
/// carries NO gestures and NO gesture-arena participants. A single raw
/// [Listener] layer (HitTestBehavior.opaque) sits above the picture and below
/// the chrome and classifies pointers MANUALLY (tap / double-tap / long-press /
/// horizontal scrub / vertical brightness-volume). Because it never enters the
/// gesture arena, media_kit's internal InteractiveViewer recognizers (or any
/// other descendant) can no longer starve single-finger input — the failure
/// mode of v0.5.10/v0.5.11 where every one-finger gesture died while the chrome
/// was visible. See docs/VIDEO-PLAYBACK.md §10–§11.
enum _GestureKind { none, horizontal, vertical }

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

  // --- raw-pointer gesture state (no gesture arena) ------------------------
  int _ptrCount = 0;
  Offset _downLocal = Offset.zero;
  Offset _accum = Offset.zero;
  bool _moved = false;
  _GestureKind _kind = _GestureKind.none;
  bool _longPressActive = false;
  Timer? _longPressTimer;
  Timer? _tapTimer;
  int _lastTapMs = 0;
  Offset _lastTapLocal = Offset.zero;
  static const double _slop = 12;
  static const int _doubleTapMs = 300;

  // --- scrub / osd ---------------------------------------------------------
  bool _dragging = false;
  double _dragAccum = 0;
  Duration _dragStartPos = Duration.zero;
  Duration _dragTargetPos = Duration.zero;
  int? _seekFlash;
  Timer? _seekFlashTimer;
  double? _osdLevel;
  IconData? _osdIcon;
  Timer? _osdTimer;
  bool _vertBrightness = false;
  double? _brightness;
  double _volume = 100;

  // --- lock / fit / orientation / subtitles --------------------------------
  bool _locked = false;
  BoxFit _fit = BoxFit.contain;
  bool _orientationApplied = false;
  bool _notifiedSoftware = false;
  List<SubtitleTrack> _subtitleTracks = const [];
  String _activeSubtitleId = '';

  // --- decode chain state --------------------------------------------------
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

  bool get _sideSeekOn => widget.prefs?.playDoubleTapSideSeek ?? false;
  double get _longPressSpeed => widget.prefs?.playLongPressSpeed ?? 2.0;

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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _player?.pause().catchError((_) {});
      appLog('video lifecycle: $state (paused player)');
      AppLog.breadcrumb('video lifecycle:$state');
    }
  }

  // ------------------------------------------------------------ audio focus

  Future<void> _acquireFocus() async {
    await MediaFocus.instance.acquire(this, _onFocusLost);
    await SharedVoicePlayer.stopAll();
  }

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
      if (mounted && _uiVisible && _playing && !_locked) _setUiVisible(false);
    });
  }

  void _toggleUi() {
    if (_locked) return;
    if (_uiVisible) {
      _uiTimer?.cancel();
      _setUiVisible(false);
    } else {
      _showUi();
    }
  }

  Future<void> _setRate(double v) async {
    setState(() => _rate = v);
    try {
      await _player?.setRate(v);
    } catch (e) {
      appLog('video setRate($v) failed: $e');
    }
  }

  // ------------------------------------------- raw-pointer gesture handling

  void _onPointerDown(PointerDownEvent e) {
    if (_locked || _failed) return;
    _ptrCount++;
    if (_ptrCount > 1) {
      // multi-touch: abandon any in-flight single-pointer gesture
      _longPressTimer?.cancel();
      _tapTimer?.cancel();
      _longPressActive = false;
      _kind = _GestureKind.none;
      if (_dragging) setState(() => _dragging = false);
      return;
    }
    _downLocal = e.localPosition;
    _accum = Offset.zero;
    _moved = false;
    _kind = _GestureKind.none;
    _dragAccum = 0;
    _dragStartPos = _position;
    _dragTargetPos = _position;
    _uiTimer?.cancel();
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _moved || _ptrCount != 1) return;
      _longPressActive = true;
      HapticFeedback.selectionClick();
      _player?.setRate(_longPressSpeed).catchError((_) {});
      setState(() {});
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_locked || _failed || _ptrCount != 1) return;
    _accum += e.delta;
    if (!_moved && _accum.distance > _slop) {
      _moved = true;
      _longPressTimer?.cancel();
      _tapTimer?.cancel();
      final dx = _accum.dx.abs();
      final dy = _accum.dy.abs();
      if (dx > dy) {
        _kind = _GestureKind.horizontal;
        setState(() => _dragging = true);
      } else {
        _kind = _GestureKind.vertical;
        final width = MediaQuery.sizeOf(context).width;
        _vertBrightness = _downLocal.dx < width / 2;
      }
    }
    if (!_moved) return;
    if (_kind == _GestureKind.horizontal) {
      final width = MediaQuery.sizeOf(context).width;
      final span = width > 0 ? width : 1;
      _dragAccum += e.delta.dx;
      var targetMs = _dragStartPos.inMilliseconds +
          (_dragAccum / span * _seekSecondsPerScreenWidth * 1000).round();
      final maxMs = _duration.inMilliseconds;
      if (maxMs > 0) {
        targetMs = targetMs.clamp(0, maxMs).toInt();
      } else if (targetMs < 0) {
        targetMs = 0;
      }
      setState(() => _dragTargetPos = Duration(milliseconds: targetMs));
    } else if (_kind == _GestureKind.vertical) {
      final height = MediaQuery.sizeOf(context).height;
      final span = height > 0 ? height : 1;
      if (_vertBrightness) {
        final cur = _brightness ?? 0.5;
        final next = (cur - e.delta.dy / span).clamp(0.02, 1.0);
        _brightness = next;
        _setBrightness(next);
        _showOsd(Icons.brightness_high, next);
      } else {
        final next = (_volume - e.delta.dy / span * 100).clamp(0.0, 100.0);
        _volume = next;
        _player?.setVolume(next).catchError((_) {});
        _showOsd(Icons.volume_up, next / 100);
      }
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_locked || _failed) return;
    _ptrCount = (_ptrCount - 1).clamp(0, 8);
    if (_ptrCount != 0) return;
    _longPressTimer?.cancel();
    if (_longPressActive) {
      _longPressActive = false;
      _player?.setRate(_rate).catchError((_) {});
      setState(() {});
      _scheduleHideUi();
      return;
    }
    if (_kind == _GestureKind.horizontal) {
      final target = _dragTargetPos;
      setState(() => _dragging = false);
      try {
        _player?.seek(target);
      } catch (err) {
        appLog('video drag-seek failed: $err');
      }
      setState(() => _position = target);
      _showUi();
      return;
    }
    if (_kind == _GestureKind.vertical) {
      _hideOsdSoon();
      _scheduleHideUi();
      return;
    }
    // no movement: tap / double-tap
    final now = DateTime.now().millisecondsSinceEpoch;
    final isDouble = (now - _lastTapMs) < _doubleTapMs &&
        (_downLocal - _lastTapLocal).distance < 60;
    _tapTimer?.cancel();
    if (isDouble) {
      _lastTapMs = 0;
      _onDoubleTap(_downLocal);
    } else {
      _lastTapMs = now;
      _lastTapLocal = _downLocal;
      _tapTimer = Timer(const Duration(milliseconds: _doubleTapMs), () {
        if (mounted) _toggleUi();
      });
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _ptrCount = 0;
    _longPressTimer?.cancel();
    _longPressActive = false;
    if (_dragging) setState(() => _dragging = false);
    _kind = _GestureKind.none;
  }

  /// A full screen-width of horizontal drag scrubs this many seconds.
  static const double _seekSecondsPerScreenWidth = 90;

  void _onDoubleTap(Offset local) {
    if (_locked || _failed) return;
    final width = MediaQuery.sizeOf(context).width;
    if (_sideSeekOn && width > 0 && local.dx < width * 0.25) {
      _seekBy(const Duration(seconds: -10));
      _flashSeek(-10);
    } else if (_sideSeekOn && width > 0 && local.dx > width * 0.75) {
      _seekBy(const Duration(seconds: 10));
      _flashSeek(10);
    } else {
      _playPause();
    }
  }

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
    } catch (_) {/* no native channel (desktop/tests) */}
  }

  Future<void> _setBrightness(double v) async {
    try {
      await _mediaCh.invokeMethod<bool>('setBrightness', {'value': v});
    } catch (_) {}
  }

  static const MethodChannel _mediaCh = MethodChannel('bittechat/media');

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

  // ------------------------------------------------------------------ open

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

    if (!tier.hardware && !_notifiedSoftware) {
      _notifiedSoftware = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(L.t.videoSoftwareDecodeNotice),
          duration: const Duration(seconds: 5),
        ));
      }
    }

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
            'vd-lavc-software-fallback': tier.hardware ? 'no' : 'yes',
            'video-sync': 'display-resample',
            'ao': 'opensles,aaudio,audiotrack',
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
              _subtitleTracks = t.subtitle;
              final sel = t.subtitle.where((s) => s.selected);
              _activeSubtitleId = sel.isEmpty ? '' : sel.first.id;
            });
          }
        }),
      ]);

      if (tierIndex == 0) {
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
      unawaited(MediaFocus.instance.setAcceptGain(true));
      unawaited(_acquireFocus());
      _scheduleHideUi();
    } else {
      unawaited(MediaFocus.instance.setAcceptGain(false));
      _showUi();
    }
  }

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
    captureOwnLogcat('video-stall');
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

  void _onMpvLog(int gen, PlayerLog l) {
    final line = 'mpv[${l.prefix}/${l.level}] ${l.text}';
    VideoPlayerPage.debugMpvLogs.add(line);
    if (VideoPlayerPage.debugMpvLogs.length > 500) {
      VideoPlayerPage.debugMpvLogs
          .removeRange(0, VideoPlayerPage.debugMpvLogs.length - 500);
    }
    final stall = VideoDecodeChain.isStallLine(line);
    if (l.level == 'error' || (stall && _stallLogged < 2)) {
      if (stall) _stallLogged++;
      appLog(line);
    }
    if (gen != _generation || _firstFrameSeen) return;
    if (stall) {
      _stallHits++;
      VideoPlayerPage.debugActiveTierStalls.add(line);
      if (_stallHits >= VideoDecodeChain.stallHitsToDowngrade) {
        final hits = _stallHits;
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
    if (v.w != null && v.h != null && v.w != 0) {
      _videoParamsSeen = true;
      _applyOrientation(v);
      _armWatchdog(gen, _tier);
      if (_loggedParams != text) {
        _loggedParams = text;
        appLog('video params: ${v.w}x${v.h} fmt=${v.pixelformat} '
            'hw=${v.hwPixelformat} rotate=${v.rotate}');
      }
    }
  }

  void _applyOrientation(VideoParams v) {
    if (_orientationApplied) return;
    final w = v.w ?? 0;
    final h = v.h ?? 0;
    if (w == 0 || h == 0) return;
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

  static String _fmtRate(double r) =>
      r == r.roundToDouble() ? '${r.toInt()}.0×' : '$r×';

  static String _fmtDelta(Duration d) {
    final a = d.abs();
    final sign = d.isNegative ? '-' : '+';
    final m = a.inMinutes.toString().padLeft(2, '0');
    final s = a.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$sign$m:$s';
  }

  @override
  void dispose() {
    _generation++;
    _watchdog?.cancel();
    _promoteTimer?.cancel();
    _uiTimer?.cancel();
    _osdTimer?.cancel();
    _seekFlashTimer?.cancel();
    _longPressTimer?.cancel();
    _tapTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (_orientationApplied) {
      SystemChrome.setPreferredOrientations(const []);
    }
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
      p.pause().catchError((_) {}).whenComplete(() => p.dispose());
    }
    super.dispose();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final vc = _videoController;
    final playable = !_failed && vc != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1) picture — carries NO gestures of its own
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
          // 2) raw-pointer gesture layer ABOVE the picture, BELOW the chrome.
          //    Opaque so RenderStack stops here; manual classification means
          //    we never fight media_kit's recognizers in the arena.
          if (playable)
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerCancel,
              ),
            ),
          // 3) transient overlays (never hit-testable)
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
          if (_osdLevel != null && _osdIcon != null)
            Center(
              child: IgnorePointer(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                          valueColor:
                              const AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('${((_osdLevel ?? 0) * 100).round()}%',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          if (_seekFlash != null)
            Center(
              child: IgnorePointer(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                          (_seekFlash ?? 0) < 0
                              ? Icons.fast_rewind
                              : Icons.fast_forward,
                          color: Colors.white,
                          size: 24),
                      const SizedBox(width: 6),
                      Text('${(_seekFlash ?? 0).abs()}s',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 16)),
                    ],
                  ),
                ),
              ),
            ),
          if (_longPressActive)
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: IgnorePointer(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '${_fmtRate(_longPressSpeed)} ${L.t.speedActive}',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
          // 4) lock toggle on the left edge (above the gesture layer)
          if (playable && (_uiVisible || _locked))
            Positioned(
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
            ),
          // 5) top chrome — finite strip (Align), never full-screen
          Align(
            alignment: Alignment.topCenter,
            child: AnimatedOpacity(
              opacity: _uiVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_uiVisible,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: AppBar(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    title: Text(widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15)),
                    actions: [
                      IconButton(
                        color: Colors.white,
                        tooltip: L.t.subtitle,
                        icon: const Icon(Icons.subtitles_outlined, size: 20),
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
              ),
            ),
          ),
          // 6) bottom chrome — finite strip (Align)
          Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedOpacity(
              opacity: _uiVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_uiVisible,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          IconButton(
                            color: Colors.white,
                            icon:
                                Icon(_playing ? Icons.pause : Icons.play_arrow),
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
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

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
