# 安装包体积构成分析（v0.4.5 实测 + v0.5 展望）

> 实测对象：GitHub Release `v0.4.5` 的 `app-release.apk`（universal，armeabi-v7a 除外），
> 79,748,897 字节 ≈ **79.7 MB**（约 76 MiB）。
> 结论先行：**~93% 是两套 CPU 架构（arm64-v8a + x86_64）的原生库**，其中 x86_64
> 那一半对真实手机用户是纯负担。分 ABI 发布可让实际下载体积立刻减半（≈39 MB），
> 无需任何功能取舍。

## 1. 逐项实测（APK 内条目，.so 以未压缩形式存放，即安装占用）

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
| `assets/flutter_assets/*` | 0.12 MB | 0.2% | 字体清单/kernel 元数据等 |
| `res/*` + `resources.arsc` + 清单等 | ~0.4 MB | 0.5% | 图标、启动图、资源表 |

按架构切分：

- **arm64-v8a 小计 ≈ 37.4 MB**（真机需要的全部）
- **x86_64 小计 ≈ 40.2 MB**（几乎只服务于模拟器/极少数 x86 设备）
- 架构无关部分 ≈ 2.1 MB

## 2. 为什么 libbitte_core.so 有 17-18 MB

对 arm64 版本做 ELF 段分析（已 strip，无调试符号残留）：

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

## 3. v0.5.0 的增量：fvp（libmdk）视频解码后端 —— 已实测

为修复"视频有声无画"（平台解码器不支持 Hi10P/HEVC10/AV1 等时 ExoPlayer 丢视频轨），
v0.5 引入 `fvp`（libmdk + FFmpeg 软解兜底）。**v0.5.0 实测 universal APK = 106.0 MB**
（+26.3 MB），新增库（每架构）：

| 库 | arm64-v8a | x86_64 | 作用 |
|---|---:|---:|---|
| `libffmpeg.so` | 8.30 MB | 10.98 MB | FFmpeg 解封装 + 软解码器 |
| `libmdk.so` | 2.30 MB | 2.08 MB | libmdk 播放内核 |
| `libass.so` | 1.37 MB | ~1.4 MB | 内封字幕渲染（可裁） |

**分 ABI 后 arm64 包实测预期 ≈ 52 MB**（37.4 原生 + 12 fvp + 2 共享/dex）。
若不想要字幕渲染可裁掉 libass（每架构 -1.4 MB）。

## 4. 瘦身选项（待确认，暂未实施）

| 方案 | 效果 | 代价 |
|---|---|---|
| **A. 分 ABI 发布**（`flutter build apk --split-per-abi`，Release 同时挂 arm64-v8a / x86_64 两个 APK） | 真机下载 **106 → ~52 MB（-51%）**（v0.4.5 口径为 79.7 → ~39） | 无功能损失；Release 页多一个文件（普通用户下 arm64 版） |
| B. 发布只保留 arm64-v8a（x86_64 仅 CI 模拟器用） | 单 APK ~52 MB | x86 设备/模拟器用户需自取 CI artifact |
| C. Rust profile 再压：`lto="fat"` + `codegen-units=1` + `opt-level="s"` | libbitte_core.so 预计 -15~30%（每架构 -3~5 MB） | CI 构建时间上升；BT 吞吐路径性能略降（本应用为 I/O 密集，影响可忽略） |
| D. 裁掉 fvp 的 libass（内封字幕渲染） | 每架构约 -1~2 MB | 播放内封字幕的影片无字幕 |
| E. 上架 Google Play 用 AAB | 商店按设备投递 ~40 MB | 与 GitHub Release APK 分发无关 |

**建议**：A（必做，零代价砍半）+ C（可选）；D 视字幕需求决定。

## 5. 复测方法

```bash
# 下载任意版本 APK 后：
python3 - << 'EOF'
import zipfile, collections
z = zipfile.ZipFile('app-release.apk')
g = collections.defaultdict(int)
for i in z.infolist():
    g['lib/<abi>' if i.filename.startswith('lib/') else i.filename.split('/')[0]] += i.compress_size
for k, v in sorted(g.items(), key=lambda kv: -kv[1]):
    print(f"{k:28s} {v/1e6:8.2f} MB")
EOF
```

CI 的 android job 已在 "List outputs" 步骤打印 jniLibs 各 .so 的大小，可直接对照。
