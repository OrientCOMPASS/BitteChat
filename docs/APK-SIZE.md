# 安装包体积构成分析（v0.4.5 与 v0.5.0 均为实测）

> **v0.5.8 更新**：§4 的方案 A（分 ABI 发布）**已实施**——CI 用
> `flutter build apk --release --split-per-abi` 产出 `arm64-v8a` / `x86_64`
> 两个**架构专用包**（命名 `BitteChat-<版本>-android-<abi>.apk`），Release 同时
> 挂出，真机只下自己那一半。下文 §1/§3 的 fvp（libmdk+libffmpeg）数字是
> **v0.5.0 的历史实测**：该播放后端已在 v0.5.2 整体换成 media_kit(libmpv)
> （见 §3.1），`libffmpeg.so`/`libmdk.so`/`libass.so`/`libfvp.so` 均不再随包发行
> （当前 FFmpeg 仅以 libmpv 内部依赖形式存在，不再有独立的 `libffmpeg.so`）。
>
> 实测对象：
> **v0.4.5**：GitHub Release `app-release.apk`（universal，arm64-v8a + x86_64），79,748,897 字节 ≈ **79.7 MB**（约 76 MiB，即用户看到"约 70MB"的那个包）。
> **v0.5.0**：CI artifact（commit `d789a6e`，同配置 universal），105,967,177 字节 ≈ **106.0 MB**。
> 结论先行：**大头是两套 CPU 架构的原生库**（v0.4.5 占 ~93%，v0.5.0 占 ~97%），其中
> x86_64 那一半对真实手机用户是纯负担；v0.5.0 新增的 ~26 MB 全部来自 fvp（libmdk+FFmpeg）
> 视频解码后端。**分 ABI 发布可让真机下载体积立刻减半**（v0.5.0：106 → ~52 MB），无需任何功能取舍。
> APK 内 `.so` 以未压缩形式存放（`extractNativeLibs` 语义），APK 大小 ≈ 安装占用。

## 1. v0.4.5 逐项实测（APK 内条目）

| 条目 | 大小 | 占比 | 是什么 |
|---|---:|---:|---|
| `lib/x86_64/libbitte_core.so` | 18.47 MB | 23.2% | Rust 核心 + **静态链接** libtorrent 2.1.2 + OpenSSL 3.5.5 + Boost + C++ 封装（x86_64，模拟器架构） |
| `lib/arm64-v8a/libbitte_core.so` | 17.20 MB | 21.6% | 同上（arm64，真实手机架构） |
| `lib/x86_64/libflutter.so` | 13.05 MB | 16.4% | Flutter 引擎（Dart 运行时、Skia/Impeller 渲染、文本排版） |
| `lib/arm64-v8a/libflutter.so` | 11.75 MB | 14.7% | 同上 |
| `lib/x86_64/libapp.so` | 7.21 MB | 9.0% | 应用 Dart 代码 AOT 编译产物 |
| `lib/arm64-v8a/libapp.so` | 6.95 MB | 8.7% | 同上 |
| `classes.dex` | 1.80 MB | 2.3% | Android 侧 Java/Kotlin：video_player(ExoPlayer/Media3)、audioplayers、file_picker、qr 等插件 |
| `lib/*/libc++_shared.so` ×2 | 2.71 MB | 3.4% | NDK C++ 标准库（两架构） |
| `lib/*/libdartjni.so` ×2 | 0.25 MB | 0.3% | file_picker 插件的 JNI 桥 |
| `assets/flutter_assets/*` | 0.16 MB | 0.2% | 字体清单/kernel 元数据等 |
| `res/*` + `resources.arsc` + 清单等 | ~0.4 MB | 0.5% | 图标、启动图、资源表 |

按架构切分：

- **arm64-v8a 小计 ≈ 37.4 MB**（真机需要的全部）
- **x86_64 小计 ≈ 40.2 MB**（几乎只服务于模拟器/极少数 x86 设备）
- 架构无关部分 ≈ 2.1 MB

## 2. 为什么 libbitte_core.so 有 17-18 MB

对 arm64 版本做 ELF 段分析（已 strip，无调试符号残留；v0.5.0 复测数值几乎相同）：

| 段 | 大小 | 内容 |
|---|---:|---|
| `.text` | 10.50 MB | 机器码：完整 BT 协议栈（libtorrent）+ OpenSSL（TLS/加密原语）+ Rust 核心（ed25519-dalek、rusqlite 内嵌 SQLite、regex、ureq/rustls、serde、bencode、DAG）+ boost::json |
| `.rodata` | 2.21 MB | 常量表（加密查表、SQLite 内嵌字符串等） |
| `.eh_frame(+hdr)` | 1.92 MB | 栈展开表（Rust panic=unwind + C++ 异常都需要） |
| `.rela.dyn` | 1.22 MB | 动态重定位表 |
| `.data.rel.ro` | 0.87 MB | 只读重定位数据（vtable 等） |
| 其余 | ~0.5 MB | |

构建侧已做的优化：`opt-level=2`、`lto=thin`、`strip=symbols`、C++ Release（无 -g）、
静态链接（无额外 .so 碎片）。也就是说这 17 MB 是"一个完整 BT 客户端 + 加密栈 +
嵌入式数据库"的实打实代码量，不是垃圾。

Flutter 侧的 `libflutter.so`（11.75 MB）与 `libapp.so`（6.95 MB）由 Flutter SDK
决定，属于所有 Flutter 应用的固定成本（一个空 Flutter 应用 arm64 也已 ~16 MB）。

## 3. v0.5.0 实测：fvp（libmdk）视频解码后端 +26.2 MB

为修复"视频有声无画"（平台解码器不支持 Hi10P/HEVC10/AV1 等时 ExoPlayer 丢视频轨），
v0.5 引入 `fvp`（libmdk 播放内核 + FFmpeg 软解兜底）。universal 包实测 105.97 MB，
比 v0.4.5 净增 26.22 MB，构成：

| 新增条目 | arm64-v8a | x86_64 | 是什么 |
|---|---:|---:|---|
| `libffmpeg.so` | 8.30 MB | 10.98 MB | FFmpeg 解复用/软解码（fvp 的兜底解码器，覆盖平台解码器不支持的编码） |
| `libmdk.so` | 2.30 MB | 2.08 MB | mdk-sdk 播放内核（优先走 MediaCodec 硬解，失败自动切 FFmpeg 软解） |
| `libass.so` | 1.37 MB | —（未随 x86_64 发行） | libass 内封字幕渲染 |
| `libfvp.so` | 0.07 MB | 0.07 MB | Flutter 插件胶水层 |
| **fvp 小计** | **≈12.0 MB** | **≈13.1 MB** | |
| `libbitte_core.so` 增量 | +0.09 MB | +0.10 MB | tracker 管理 / 种子群聊核心代码 |
| `libapp.so` 增量 | +0.39 MB | +0.39 MB | Dart 侧新 UI（tracker、群聊、壁纸等） |

v0.5.0 按架构切分：**arm64-v8a ≈ 49.9 MB，x86_64 ≈ 53.8 MB，架构无关 ≈ 2.2 MB**
→ 分 ABI 后真机（arm64）APK ≈ **52.2 MB**。

## 3.1 v0.5.2 实测：音视频栈切换 media_kit(libmpv)

fvp(libmdk) 因实机"有声无画"（Impeller 外部纹理合成类设备兼容问题）整体替换为
media_kit(libmpv)，音频播放亦从 audioplayers 并入 mpv。universal 包实测
**113.12 MB**（CI artifact，commit `5968d6a`），对比 v0.5.0 的 106.0 MB：

| 变化 | arm64-v8a | x86_64 |
|---|---:|---:|
| − libffmpeg/libmdk/libass/libfvp（fvp 全家） | −12.04 MB | −13.13 MB |
| + libmpv.so | +14.87 MB | +17.96 MB |
| + libmediakitandroidhelper.so / event loop | +0.39 MB | +0.37 MB |
| − classes.dex（ExoPlayer/Media3 + audioplayers Java 层移除） | ≈ −0.8 MB（架构无关） | 同左 |
| + 核心/Dart 代码增量 | +0.17 MB | +0.21 MB |

按架构切分：**arm64-v8a ≈ 53.1 MB，x86_64 ≈ 59.0 MB，架构无关 ≈ 1.0 MB**
→ 分 ABI 后真机（arm64）APK ≈ **54.1 MB**（方案 A 的收益不变，见 §4）。

## 4. 瘦身选项（A 已于 v0.5.8 实施）

| 方案 | 效果（实测口径） | 代价 |
|---|---|---|
| ✅ **A. 分 ABI 发布**（v0.5.8 已落地：`flutter build apk --release --split-per-abi`，Release 同时挂 arm64-v8a / x86_64 两个 APK） | 真机下载 **v0.5.0：106 → ~52 MB（-51%）**；v0.4.5 口径：79.7 → ~39 MB | 无功能损失；Release 页多一个文件（普通用户下 arm64 版） |
| B. 发布只保留 arm64-v8a（x86_64 仅 CI 模拟器用） | 单 APK ~52 MB | x86 设备/模拟器用户需自取 CI artifact |
| C. Rust profile 再压：`lto="fat"` + `codegen-units=1` + `opt-level="s"` | libbitte_core.so 预计 -15~30%（每架构 -3~5 MB） | CI 构建时间上升；BT 吞吐路径性能略降（本应用为 I/O 密集，影响可忽略） |
| F. 上架 Google Play 用 AAB | 商店按设备投递 ~52 MB | 与 GitHub Release APK 分发无关 |

> 旧表的 D/E（裁 fvp 的 libass、fvp 只留 arm64）随 fvp 在 v0.5.2 被 media_kit
> 取代而作废，已删除。

**结论**：A 已实施（零代价砍半）；C 可选（进一步压 Rust 核心）；B/F 视分发渠道决定。

## 5. 复测方法

```bash
# 下载任意版本 APK 后：
python3 - << 'EOF'
import zipfile, collections
z = zipfile.ZipFile('app-release.apk')
g = collections.defaultdict(int)
for i in z.infolist():
    g['lib/<abi>' if i.filename.startswith('lib/') else i.filename.split('/')[0]] += i.file_size
for k, v in sorted(g.items(), key=lambda kv: -kv[1]):
    print(f"{k:28s} {v/1e6:8.2f} MB")
EOF
```

CI 的 android job 已在 "List outputs" 步骤打印 jniLibs 各 .so 的大小，可直接对照。
本文所有数字均为对 Release 资产 / CI artifact 的实测（2026-09-28，v0.4.5 与
v0.5.0-`d789a6e`）。
