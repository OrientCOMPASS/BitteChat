# BitteChat

去中心化 BitTorrent 群聊客户端：**种子即群聊，消息哈希链防篡改，附件即 torrent**。
没有中心服务器——群聊房间是 BitTorrent swarm，消息经 DHT（BEP44）头指针发现、
以签名 DAG 节点传播与存储；文件附件就地做种、经聊天内 BT 通道传输。

## 功能

- **群聊 / 私聊**：消息 = Ed25519 签名的 DAG 节点（哈希链防篡改）；DM 端到端加密
  （X25519 + AEAD sealed 载荷）；未读徽标、[有人@我]/[有新回复] 标记、草稿
- **附件**：发送方**就地做种**（不复制文件、不占双份空间）；接收方经聊天内 BT 通道
  下载（进度/断续/完整校验）；图片缩略图与全屏、视频播放（media_kit + 解码档位回退梯）、
  音频条、文本预览
- **引用回复 / @提及**：左滑引用（QQ 式卡片，含图片缩略图）、长按菜单与文本选择
- **种子页 / RSS 订阅**：完整 BT 能力（tracker 编辑、过滤脚本、下载目录可配）
- **界面**：Material 3、全局壁纸编辑器、中/英、深色模式
- **取证**：有界日志 + 崩溃转储（Dart / Rust panic / native 信号三路），设置内一键导出

## 工作原理（简述）

```
Flutter app (app/)  ──dart:ffi JSON──  libbitte_core.so (Rust)
                                        ├─ bitte-core   消息/DAG/同步/存储/RSS
                                        ├─ bitte-ffi    C ABI + 事件队列(drain)
                                        └─ bitte-bt     C++17 → libtorrent 2.x + OpenSSL
```

- 群 = swarm（房间清单 torrent）+ DHT 可变项头指针；新消息经 swarm 扩展消息直推 +
  DHT 头轮询/抓取泵双通道同步（详见 `docs/ARCHITECTURE.md`、`docs/PROTOCOL.md`）
- 事件经 `sys.drain_events` 拉取通道送达 UI（200ms），不依赖平台回调语义
- 视频解码档位回退梯与停摆指纹检测见 `docs/ARCHITECTURE.md`「视频播放」

## 获取与安装

- GitHub Releases 提供 **split-per-ABI** 包（`arm64-v8a` / `x86_64`），CI release keystore
  签名，可直接覆盖升级；只下自己架构那一半
- 每轮交付的装机测试清单随交付提供（不入库）

## 开发构建

前置：Flutter 3.47.x、JDK 17、Rust（`aarch64-linux-android`/`x86_64-linux-android` target
+ `cargo-ndk`）；NDK 由 gradle 自动安装。

```bash
bash scripts/build-android-native.sh   # OpenSSL+libtorrent+C++ wrapper+Rust cdylib → app jniLibs
bash scripts/make-dev-keystore.sh      # 本地开发签名（仅开发用；CI 用仓库 secrets）
cd app && flutter build apk --release --split-per-abi
```

非 Android 平台运行进入 demo 模式（无 native 库）。

## 测试与 CI

**仓库策略：每轮修改必须附覆盖该修改的模拟器集成测试**（见 `docs/TESTING.md`）。

| Job | 内容 |
|---|---|
| core-test | rustfmt / clippy `-D warnings` / cargo test（mock 总线双实例 e2e） |
| app-analyze | dart format / analyze / flutter test |
| native-smoke | 宿主机真 libtorrent FFI 冒烟 |
| native-android → android | native 双 ABI 构建（产物共享）→ release APK |
| emulator-verify（阻断） | 模拟器真引擎集成测试：`attach_test`（事件送达/附件内联/回底钮+截图）、`app_test`（DHT 确认）、`video_test`（真实 H.264 实播）；源码哈希未变经门禁跳过 |
| release（仅 tag） | 复用分支 run 的 APK 发布 |

模拟器截图随每次 main run 上传（artifact `emulator-shots-<sha>`）。

## 仓库结构

```
app/        Flutter 应用 + integration_test
core/       bitte-core(Rust) / bitte-ffi(C ABI) / bitte-bt(C++ libtorrent 封装)
docs/       ARCHITECTURE / PROTOCOL / TESTING
scripts/    native 构建、开发 keystore、模拟器截图拉取
```

## License

Unlicense（public domain），见 `LICENSE`。
