# PLATFORMS — 多平台准备与路线（GUI + WebUI）

> 状态：**只做准备，不做实现**。本文档记录当前代码库为全平台适配已经落地的
> 准备点、每个平台的差距清单（gap list）、以及选定的实施路线。
> 除 Android 外，任何平台都**没有**可用的构建产物。

## 一、平台矩阵现状

| 平台 | UI | 核心 | native 栈 | 传输 | 状态 |
|---|---|---|---|---|---|
| Android | Flutter（生产） | Rust（生产） | C++ libtorrent（CI 双 ABI） | dart:ffi | **发布** |
| Linux 桌面 | Flutter 脚手架未生成 | 纯 Rust 可编译 | `scripts/build-linux-native.sh` 已能构建宿主机栈（CI native-smoke 每轮验证） | FFI 库名已解析 | 准备 |
| Windows 桌面 | 未生成 | 未经交叉验证（platforms.yml 预留可选 check） | 无构建脚本（依赖获取方式待定：vcpkg/预编译） | FFI 库名已解析（bitte_core.dll） | 准备 |
| macOS 桌面 | 未生成 | 未验证（需 osxcross 或本机） | 无构建脚本（brew/源码 OpenSSL+libtorrent） | FFI 库名已解析（.dylib）；build.rs 框架链接分支已预留 | 准备 |
| Web | 未生成 | **不可直接编译**（rusqlite/ureq/std::thread 与 wasm32-unknown-unknown 冲突） | 不适用 | `WebCoreTransport` 占位（网关模式） | 准备 |

架构上的关键事实（决定了准备的形态）：

1. **业务逻辑 100% 在 Rust 核心**，UI 只经一个同步 JSON-RPC 面
   （`bc_call(method, params_json)`）+ 一个事件串流（`sys.drain_events`）
   与核心交互。任何能承载这两条通道的运行时都能承载整个应用。
2. **引擎已被 trait 抽象**（`BtEngine`，生产=libtorrent、测试=mock）。
   wasm/受限平台的替代引擎（或网关代理）可以整体替换，不动业务层。
3. **平台耦合点集中在三处**：Dart 侧 `dart:ffi`/`dart:io` 与 Android
   MethodChannel（音频焦点/亮度/音量/FileProvider/intent）；Rust 侧
   `bitte-ffi` 的 android logcat 分支（已有 `#[cfg(target_os="android")]`
   守护）；`bitte-bt` 的平台链接脚本。

## 二、本轮已落地的准备点（v0.0.1 起）

### Dart 侧（app/lib/core/platform/）

- `host_platform.dart`：`HostPlatform` 枚举（android/ios/linux/macos/
  windows/web/unknown）、纯函数探测（`kIsWeb` + `defaultTargetPlatform`，
  不依赖 `dart:io`，本身即 web 兼容写法）、**native 库文件名唯一事实源**
  `nativeLibraryName()`（.so/.dylib/.dll）。
- `core_transport.dart`：`CoreTransport` 抽象（available/call/events/close）
  ——UI 与核心之间的最小契约，未来所有平台传输实现同一接口。
- `native_transport.dart`：FFI 传输实现（包装现有 `BitteBridge` 1:1，
  行为零变化；桌面平台打开对应库名即走同一代码路径；库缺失时降级为
  demo 模式，与 Android 现状一致）。
- `web_transport.dart`：`WebCoreTransport` 占位——固定了未来的配置面
  （gateway URL），当前恒不可用。
- `bridge.dart`：`_openLib` 从"仅 Android"改为按 `nativeLibraryName`
  解析（Android 行为逐字节等价）。
- `app/test/platform_test.dart`：上述契约的单测（CI `flutter test` 覆盖）。

**现有调用路径未切换**：`BitteApi` 仍直接使用 `BitteBridge`，本轮不引入
行为变化；桌面首平台落地时再把 `BitteApi` 迁移到 `CoreTransport`
（接口已按现有调用面 1:1 设计，迁移是纯替换）。

### Rust 侧

- `bitte-bt/build.rs`：C++ 运行时/框架链接按 target 家族分支化
  （android/linux 行为不变；新增 windows-msvc 与 apple 分支骨架，
  含 Security/CoreFoundation 框架链接准备）。
- `bitte-ffi`：现有 `#[cfg(target_os="android")]` logcat 分支与
  `#[cfg(unix)]` 信号处理已是可移植写法，无需改动；非 Android 平台日志
  自动落 `logs/core.log`（TeeLogger 文件支路）。

### CI

- `.github/workflows/platforms.yml`（**仅手动触发**，不影响每轮 push CI）：
  - `readiness`：验证准备工作面完好（platform 抽象层文件存在、库名映射
    覆盖桌面、`flutter test test/platform_test.dart` 绿）。
  - `cross-check-windows`（输入开关，默认关，informational）：
    `cargo check -p bitte-core --target x86_64-pc-windows-gnu`，
    探索核心对 Windows 目标的可编译性（mock 引擎、无 native 依赖）。

## 三、桌面 GUI 实施路线（Linux 首平台）

前置差距清单（按序）：

1. `cd app && flutter create --platforms=linux .`（生成脚手架；本仓库刻意
   不提交半成品平台目录）；
2. 打包 native 栈：`scripts/build-linux-native.sh` 产物
   （`libbitte_core.so` 由 `cargo build -p bitte-ffi --features native-bt`
   + `BITTE_BT_PREFIX` 链接生成）随应用分发（CMake install 进 bundle）；
3. 平台服务桌面化：Android MethodChannel 能力逐项替代——
   音频焦点（media_kit 桌面后端自理）、亮度/音量（桌面无关或删减）、
   文件外部打开（`url_launcher`/xdg-open）、FileProvider 导出（另择导出
   目录）；这些都在 UI 层，核心零改动；
4. 数据目录：`getExternalStorageDirectory` 是 Android 专属，`BitteApi.init`
   需按 `HostPlatform` 分支到 `getApplicationSupportDirectory()`（已回退
   存在，改动极小）；
5. CI：新增 linux-desktop job（native 栈缓存复用 native-smoke 的 key）。

Windows/macOS 追加项：native 栈构建脚本（vcpkg / brew + 源码 OpenSSL）、
`bitte-bt/build.rs` 已预留分支的实测修正、签名与打包（msix / dmg）。

## 四、WebUI 实施路线

**路线 A（首选，第一阶段）：自托管网关。**
服务器（用户自己的机器/NAS）运行 native 核心 + 一个把
`bc_call`/`sys.drain_events` 映射为 WebSocket JSON-RPC 的网关进程；
Web 前端实现 `WebCoreTransport` 即接入，应用层零改动。

- 优点：核心零改造；全功能（DHT/libtorrent 都在服务器侧）；
  符合"无中心服务器"边界（网关是自托管桥，不是云服务）。
- 差距清单：网关二进制（可直接复用 `bitte-ffi` 的 dispatch 面，新增
  crate 承载 WebSocket 服务）；`WebCoreTransport` 实装（连接管理、
  事件推送、断线重连）；Flutter web 脚手架与媒体栈评估
  （media_kit web 后端受限，视频可能降级为浏览器 `<video>` 直链）。

**路线 B（长期评估）：纯客户端 wasm。**
`bitte-core` 编译 wasm32-unknown-unknown 需要三处后端抽象：
存储（rusqlite → sqlite-wasm/OPFS 或 IndexedDB KV）、HTTP（ureq →
fetch/js-sys）、线程模型（std::thread/mpsc → 单线程 + async 或 worker）；
且浏览器无 raw socket，DHT/BT 需经 WebRTC 数据通道或公共中继——生态
（webtorrent 风格）尚不足以承载本项目的 BEP44 定制用法。故仅作为
研究方向保留，`BtEngine` trait 是既定的接入点。

## 五、准备工作的验收标准

本轮准备以下列方式被机器验证（而非仅文档声明）：

- `flutter test test/platform_test.dart`：平台探测/库名映射/传输契约
  （CI app-analyze 每轮执行）；
- `platforms.yml → readiness`：准备工作面完整性（手动触发）;
- `cargo check -p bitte-ffi --features native-bt` 与全量
  `cargo test -p bitte-core`：build.rs 分支化后 Android/Linux 路径
  不回归（CI core-test 每轮执行）。
