# BitteChat App (Flutter)

本目录是 BitteChat 的 Flutter 前端（Android）。项目总览、协议与架构见仓库根目录的
[README.md](../README.md)、[docs/PROTOCOL.md](../docs/PROTOCOL.md)、
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)。

## 本地开发

```bash
flutter pub get
flutter analyze && flutter test     # 无需原生库（演示模式）
```

真机/模拟器完整功能需先构建原生核心（或直接从 GitHub Releases 下载 CI 产出的 APK）：

```bash
bash ../scripts/build-android-native.sh   # 需要 NDK + Rust android targets + cargo-ndk
flutter run
```

## 与 Rust 核心的边界

- `lib/core/bridge.dart`：dart:ffi 绑定 `libbitte_core.so`（bc_init/bc_call/bc_free/bc_shutdown + 事件回调）
- `lib/core/api.dart`：类型化 API 包装与事件流
- 所有命令/事件均为 JSON；二进制用 hex/base64
