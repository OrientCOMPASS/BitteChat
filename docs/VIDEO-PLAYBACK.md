# 视频播放：「有声无画」的诊断与解码降级链

本文记录 v0.5.2 → v0.5.6 期间围绕「视频只有声音、画面全黑」的完整排查过程与最终方案。
这一类问题在实机上难以复现（沙盒与 CI 模拟器都跑不出来），所以文档里保留了**判定依据**，
方便后续机型/编码回归时快速定位，而不是重新猜一遍。

## 1. 渲染链路

```
文件 → mpv(lavc/MediaCodec 解码) → hwdec interop → vo/gpu (EGL, OpenGL ES)
     → android.view.Surface(SurfaceTexture) → Flutter ExternalTexture → 屏幕
```

- Dart 侧：`media_kit` / `media_kit_video`（Android 走 `AndroidVideoController`，
  `--vo=gpu --gpu-context=android --opengl-es=yes`，`--wid` 指向 Java 层
  `new Surface(surfaceTextureEntry.surfaceTexture())` 的全局引用）。
- 音频链**完全独立**（`--ao=opensles,aaudio,audiotrack`），所以「画面全黑 + 声音正常」
  等价于「解码或渲染链断了，音频没事」，不要把两者混在一起排查。

## 2. 已经排除的嫌疑（历史修复，均已保留）

| 版本 | 措施 | 结论 |
|------|------|------|
| v0.5.2 | fvp/mdk → media_kit/libmpv | 换掉了一类外部纹理合成问题，但没根治 |
| v0.5.3 | 关闭 Impeller（`EnableImpeller=false`，Skia/GL） | 必要但不充分 |
| v0.5.4 | `video-sync=display-resample` + ao 三级回退 | 音频 underrun 不再拖死视频时钟 |
| v0.5.5 | 播放期隐藏壁纸、logcat 自采集 | **诊断手段**；实机复测证明与壁纸无关，v0.5.6 已恢复壁纸原有行为 |
| — | 文件完整性取证（ftyp/moov/零填充） | 实机日志显示文件完好（`moov(tail256k)=true`），排除「半截文件」 |

## 3. v0.5.6 定位到的根因

实机导出日志里的决定性指纹：

```
mpv[vo/gpu/aimagereader/warn]  Waiting for frame timed out!
mpv[vo/gpu/aimagereader/error] acquireLatestImage failed: -30001
```

同时 logcat 显示解码器**确实起来了**：

```
I/MediaCodec: [OMX.qcom.video.decoder.hevc] setting surface generation to 10457089
D/SurfaceUtils: set up nativeWindow 0x... for 1280x736, color 0x7fa30c06, usage 0x20402900
I/media_kit: ...VideoOutputManager.setSurfaceTextureSize: -547... 1280 720
```

对照 mpv 源码 `video/out/hwdec/hwdec_aimagereader.c`：

- `aimagereader` 是当前 libmpv 在 Android 上**唯一**的 MediaCodec 零拷贝 interop 驱动
  （`video/out/hwdec/` 下 Android 相关只有它；`ra_hwdec_drivers[]` 里由
  `HAVE_ANDROID_MEDIA_NDK` 引入）。
- 它用 `AImageReader_newWithUsage(16, 16, AIMAGE_FORMAT_PRIVATE,
  AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, max_images = 3, ...)` 建一个
  ImageReader，把它的 Surface 交给 FFmpeg 的 mediacodec hwaccel（`hwctx->surface`），
  然后每帧 `av_mediacodec_release_buffer(buffer, 1)` 渲染 → 等 listener 回调 →
  `AImageReader_acquireLatestImage` → `AImage_getHardwareBuffer` →
  `eglCreateImageKHR(EGL_NATIVE_BUFFER_ANDROID)` → `GL_TEXTURE_EXTERNAL_OES`。
- `-30001` 是 `AMEDIA_ERROR_WOULD_BLOCK`：`acquireLatestImage` **一帧都取不到**。
- 关键：`mapper_map` 在这种情况下返回 0（源码注释写明是「避免闪屏的 HACK」），
  解码器认为自己工作正常，**mpv 因此永远不会自动回退**。渲染器手上没有新帧，
  画面就一直黑着；音频不受影响 → 「只有声音」。

即：**MediaCodec 在跑，但它的输出缓冲永远填不进 mpv 的 ImageReader**。
这是 mpv 上游 `hwdec_aimagereader` 与部分老式 OMX 硬解（本机为
`OMX.qcom.video.decoder.hevc`）之间的兼容性缺陷，应用层改渲染参数无法绕过。

## 4. 方案：解码降级链（`app/lib/core/video_decode.dart`）

mpv 自己不退，就由 Dart 侧盯着它退：

| 档 | `--hwdec` | 路径 | 说明 |
|----|-----------|------|------|
| 0 | `mediacodec` | MediaCodec → aimagereader → EGLImage → OES 纹理（零拷贝） | 绝大多数机型正常，最省电。**与 v0.5.5 的行为等价**（`mediacodec,auto-safe` 里第一项就命中它，`auto-safe` 因为 `mediacodec` 不在 mpv 的 WHITELIST 里反而轮不到） |
| 1 | `mediacodec-copy` | MediaCodec → `av_hwframe_transfer_data` 回读内存(NV12) → vo/gpu 上传普通纹理 | 仍然硬解，但**绕开 aimagereader interop**；1080p 级别的拷贝开销移动端可接受 |
| 2 | `no` | FFmpeg 软解 | 最后兜底，保证「有画面」；此时 `vd-lavc-software-fallback=yes` |

降级触发（两条独立通道，任一命中即降）：

1. **日志指纹**：`aimagereader` / `acquireLatestImage failed` /
   `Waiting for frame timed out` 命中 ≥ 3 行（mpv 每个停摆帧打 1 warn + 1 error，
   3 行 ≈ 停摆后约 150 ms）→ 立即降级，不必等超时。指纹故意收得很窄：只有
   aimagereader interop 会产生这些字样，软解视频永远不会误触发。
2. **首帧看门狗**：收到带真实几何（`w`/`h` 非空）的 `video-params` 后启动计时
   （0 档 8 s / 1 档 10 s / 2 档 15 s），到点仍未收到
   `VideoController.waitUntilFirstFrameRendered` → 降级。用于兜住「没有指纹、
   但同样一帧都出不来」的其它 interop 故障。

实现要点：

- 降级 = **重建 Player + VideoController**，不是原地改 `--hwdec`。interop 是在
  解码器/vo 装配时选定的，停摆后那套上下文不值得复用；重建约 300 ms，一次性代价。
- 重建时**恢复播放位置**，用户感知是「短暂停顿后继续播」，不是从头开始。
- 拆除旧 player 的动作**延后一个事件循环**（`Future.delayed(Duration.zero)`）：
  降级判定发生在 mpv 日志回调里，而 media_kit 的事件由其原生事件循环投递，
  在回调内部 dispose 同一个 player 有死锁风险。
- 用 `_generation` 序号给所有异步回调打标签，跨代回调一律丢弃（避免旧的
  参数/日志事件把新一代的状态改乱）。
- 在某一档稳定播放 10 s 后，把该档写入 `<dataDir>/video_prefs.json`；
  下次直接从这里起步，不再每次重演「黑屏 → 降级」。
- 最后一档仍失败才走原有兜底：明确报错 + 「用其他应用打开」+ 导出日志提示。
- 播放页底部显示当前档位（`视频解码: mediacodec-copy · 软解渲染` 一类），
  用户反馈时不需要导日志也能知道跑在哪一档。

## 5. 怎么读日志

`设置 → 导出日志` 得到的 `app.log` 里，一次正常播放应该是：

```
video file: len=80114940 magic=ftyp-ok moov(head)=false moov(tail256k)=true zeroHead=false
video decode tier -> mediacodec (hwdec=mediacodec, gen=1, resume=0ms)
video open: /storage/.../xxx.mp4 (media_kit/mpv tier=mediacodec)
mpv video params: ... -> VideoParams(pixelformat: mediacodec, ... w: 1280, h: 720 ...)
video first frame rendered (tier=mediacodec)
video decode tier 0 settled (remembered for this device)
```

出问题并被自动救回时：

```
video decode tier -> mediacodec (hwdec=mediacodec, gen=1, resume=0ms)
mpv[vo/gpu/aimagereader/warn] Waiting for frame timed out!
mpv[vo/gpu/aimagereader/error] acquireLatestImage failed: -30001
...
video downgrade mediacodec -> mediacodec-copy: renderer stall (3 x aimagereader) (position=1840ms)
video decode tier -> mediacodec-copy (hwdec=mediacodec-copy, gen=2, resume=1840ms)
video first frame rendered (tier=mediacodec-copy)
```

排查建议：先看 `video decode tier ->` 判断最终落在哪一档，再看有没有
`Waiting for frame timed out` / `-30001`（interop 停摆）或 `video watchdog:`
（无指纹的停摆），最后才怀疑文件本身（`video file:` 行的 ftyp/moov/zeroHead）。

## 6. CI 覆盖

`.github/workflows/ci.yml` 的 `emulator-smoke`（非阻断）里
`integration_test/video_test.dart` 用 ffmpeg 生成真实 H.264+AAC 样片实播，断言：

1. 收到真实几何的 `video-params`（640×360，排除 960×540 的占位参数）；
2. 播放时钟推进（帧确实在被消费）；
3. **当前档位**没有停摆指纹（已经放弃的档位允许有 —— 那正是降级链在干活，
   降级次数会在失败信息里打出来）；
4. 没有 error 事件。

模拟器是 x86_64 + swiftshader，与真机 Adreno/OMX 路径不同，所以它证明的是
「链路可用 + 断言有效」，不能证明「真机不黑屏」；真机结论只能靠导出日志。

## 7. 如果将来还要换 libmpv

`app/pubspec.yaml` 的 `dependency_overrides` 指向
`My-Responsitories/media-kit`（fork），其 `media_kit_libs_android_video` 又下载
`My-Responsitories/libmpv-android-video-build` 的预编译 `libmpv.so`。
换 libmpv 版本时请重新确认两件事：

- `video/out/hwdec/` 下 Android 的 interop 驱动是否仍只有 `aimagereader`
  （若上游修好了停摆问题，降级链依然无害，只是不会触发）；
- `--hwdec` 的候选名是否仍是 `mediacodec` / `mediacodec-copy`
  （见 mpv `video/decode/vd_lavc.c` 的 `hwdec_autoprobe_info`：
  `mediacodec` 无 WHITELIST 标记，`mediacodec-copy` 有）。
