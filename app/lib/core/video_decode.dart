// 视频解码链：按机型/编码自动降级的「有声无画」根治方案。
//
// 背景（v0.5.6）：
//   关闭 Impeller（v0.5.3）+ 隐藏壁纸 + display-resample（v0.5.4）之后，实机
//   仍然出现「只有声音、画面全黑」。导出的日志给出了决定性指纹：
//
//     mpv[vo/gpu/aimagereader/warn]  Waiting for frame timed out!
//     mpv[vo/gpu/aimagereader/error] acquireLatestImage failed: -30001
//
//   `-30001` = `AMEDIA_ERROR_WOULD_BLOCK`：mpv 的 **hwdec_aimagereader**
//   （当前 libmpv 在 Android 上唯一的 MediaCodec 零拷贝 interop 驱动）把
//   MediaCodec 的输出 Surface 接到一个 `maxImages=3` 的 AImageReader 上，
//   然后 `AImageReader_acquireLatestImage` 一帧都取不到。MediaCodec 侧其实
//   已经 configure/start 成功（logcat 里能看到
//   `[OMX.qcom.video.decoder.hevc] setting surface generation ...`），
//   也就是说：**解码器在工作，但它的输出缓冲永远填不进 mpv 的 ImageReader**。
//   这是 mpv 上游 hwdec_aimagereader 在部分老式 OMX 硬解（Qualcomm
//   OMX.qcom.* 一类）上的兼容性缺陷，不是本项目渲染层的问题——渲染层拿不到
//   任何一帧，只能一直黑着，而音频链完全独立，所以「只有声音」。
//
//   mpv 对这种情况不会自动回退：`mapper_map` 里 `acquireLatestImage` 失败时
//   返回「假成功」（避免闪屏），解码器认为自己工作正常，于是永远卡死。
//
// 方案：**解码链降级**。既然 mpv 自己不会退，我们在 Dart 侧盯着它退：
//
//   tier 0  hwdec=mediacodec       零拷贝硬解（ImageReader→EGLImage→OES 纹理）
//                                  —— 绝大多数机型/编码正常，最省电
//   tier 1  hwdec=mediacodec-copy  MediaCodec 硬解 + 回读内存（NV12→GL 上传）
//                                  —— 绕开 aimagereader interop，兼容性好，
//                                     1080p 级别的拷贝开销在移动端可接受
//   tier 2  hwdec=no               纯软解（FFmpeg）—— 最后兜底，保证有画面
//
//   降级触发（两条独立通道，任一命中即降）：
//     a) mpv 日志出现 aimagereader 停摆指纹（≥3 行）——立即降级，无需等待；
//     b) 看门狗：已经确认硬解在工作（video-params 报出 mediacodec/硬解像素
//        格式）但 N 秒内一帧都没渲染出来。
//   一旦在某一档稳定播放超过 promoteAfter，就把该档写入
//   <dataDir>/video_prefs.json，下次直接从这里起步（不再每次重演黑屏→降级）。
//
//   软解兜底不受 `vd-lavc-software-fallback=no` 影响：该选项只禁止「硬解
//   初始化失败后偷偷退软解」，而我们是在 tier 2 显式请求软解。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One rung of the decode ladder.
@immutable
class VideoDecodeTier {
  const VideoDecodeTier({
    required this.index,
    required this.label,
    required this.hwdec,
    required this.hardware,
    this.firstFrameTimeout = const Duration(seconds: 8),
  });

  /// 0-based position in [VideoDecodeChain.tiers].
  final int index;

  /// Human readable name written into the log and shown in the UI.
  final String label;

  /// mpv `--hwdec` value (`VideoControllerConfiguration.hwdec`).
  final String hwdec;

  /// `VideoControllerConfiguration.enableHardwareAcceleration`.
  final bool hardware;

  /// Watchdog: how long we tolerate "hardware decode is running but the
  /// renderer never produced a frame" before dropping to the next tier.
  final Duration firstFrameTimeout;

  @override
  String toString() => 'tier$index($label,hwdec=$hwdec)';
}

/// The ladder itself + the "which rung did this device settle on" memory.
class VideoDecodeChain {
  VideoDecodeChain._();

  static final VideoDecodeChain instance = VideoDecodeChain._();

  /// Rungs, best first. The last rung must always work (software decode).
  static const List<VideoDecodeTier> tiers = [
    VideoDecodeTier(
      index: 0,
      label: 'mediacodec',
      hwdec: 'mediacodec',
      hardware: true,
    ),
    VideoDecodeTier(
      index: 1,
      label: 'mediacodec-copy',
      hwdec: 'mediacodec-copy',
      hardware: true,
      firstFrameTimeout: Duration(seconds: 10),
    ),
    VideoDecodeTier(
      index: 2,
      label: 'software',
      hwdec: 'no',
      hardware: false,
      firstFrameTimeout: Duration(seconds: 15),
    ),
  ];

  /// Clamp a rung index without relying on `num.clamp`'s refined typing.
  static int clampTier(int i) {
    final max = tiers.length - 1;
    if (i < 0) return 0;
    if (i > max) return max;
    return i;
  }

  static VideoDecodeTier tier(int i) => tiers[clampTier(i)];

  // ---------------------------------------------------------------- memory

  File? _file;
  int _remembered = 0;

  /// Rung to start from on this device (0 unless a previous session proved a
  /// lower rung is needed).
  int get rememberedTier => _remembered;

  /// Test/CI hook: force the starting rung (and disable the on-disk memory).
  @visibleForTesting
  static int? debugForceStartTier;

  int get startTier => debugForceStartTier ?? clampTier(_remembered);

  /// Where the settled rung is persisted.
  Future<void> bind(String dataDir) async {
    try {
      _file = File('$dataDir/video_prefs.json');
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString());
        if (j is Map<String, dynamic>) {
          final t = (j['decoderTier'] as num?)?.toInt() ?? 0;
          _remembered = clampTier(t);
        }
      }
    } catch (_) {
      _remembered = 0;
    }
  }

  /// Persist the rung that actually worked, so the next video starts there.
  Future<void> remember(int tierIndex) async {
    final f = _file;
    if (f == null) return;
    if (tierIndex == _remembered) return;
    _remembered = clampTier(tierIndex);
    try {
      await f.writeAsString(jsonEncode({'decoderTier': _remembered}));
    } catch (_) {}
  }

  // ------------------------------------------------------------ detection

  /// mpv log signatures proving the zero-copy MediaCodec interop is stalled
  /// (see the file header for the full story). Deliberately narrow: only the
  /// aimagereader interop produces these, so a software-decoded video can
  /// never trip them.
  static const List<String> stallSignatures = [
    'aimagereader',
    'acquireLatestImage failed',
    'Waiting for frame timed out',
  ];

  /// How many signature lines before we act. mpv logs one warn + one error per
  /// stalled frame, so 3 lines ≈ the first ~150 ms of a dead interop.
  static const int stallHitsToDowngrade = 3;

  static bool isStallLine(String mpvLogLine) {
    final l = mpvLogLine.toLowerCase();
    for (final s in stallSignatures) {
      if (l.contains(s.toLowerCase())) return true;
    }
    return false;
  }

  /// Does this `video-params` report prove a hardware decoder is feeding the
  /// renderer? Used to arm the first-frame watchdog only when it matters
  /// (software-decoded videos render through a completely different path and
  /// must never be "downgraded" because they are slow to start).
  static bool paramsLookHardware(String videoParams) {
    final p = videoParams.toLowerCase();
    if (p.contains('pixelformat: mediacodec')) return true;
    if (p.contains('pixelformat: videotoolbox')) return true;
    if (p.contains('pixelformat: vaapi')) return true;
    if (p.contains('pixelformat: d3d11')) return true;
    if (p.contains('pixelformat: cuda')) return true;
    if (p.contains('pixelformat: drmprime')) return true;
    final m = RegExp(r'hwpixelformat:\s*([a-z0-9_]+)').firstMatch(p);
    if (m != null && m.group(1) != 'null') return true;
    return false;
  }
}
