# BitteChat

**去中心化的 BitTorrent 群聊客户端** —— 一个种子就是一个群，聊天记录像 git 一样以哈希链（DAG）保存和传播，无法被任何单点篡改或删除。

Flutter (Android) 前端 + Rust 核心 + [libtorrent](https://www.libtorrent.org/) 后端。应用分三个经典页签：

| 页签 | 功能 |
|------|------|
| 💬 聊天 | 创建/加入群聊（磁力链即邀请）、收发文字与文件、消息哈希链同步 |
| 🧲 种子 | 标准 BT 客户端：磁力链/种子文件下载、做种、文件优先级、 peer 列表、限速 |
| 📰 订阅 | RSS/Atom 订阅阅读，条目中的磁力链/种子附件一键转入 BT 下载 |

## 核心概念

- **群 = 种子**：每个群聊有一个"清单种子"（manifest torrent），磁力链接就是入群邀请。成员持续做种该种子，群组即在 BT 网络中存活。
- **消息 = git 对象**：每条消息经作者 Ed25519 签名，引用父消息的 SHA-1，形成有向无环图（DAG）。并发发言产生多个"头"（heads），后续消息通过引用全部头完成合并——与 git 的分支/合并模型一致。
- **传播 = BEP44 DHT + BT 扩展消息**：消息本体作为 DHT 不可变条目（内容寻址）存储；每个群的头指针作为 DHT 可变条目（群共享密钥签名、序号单调）发布；已连接的群成员之间通过自定义 BEP10 扩展消息 `bc_chat` 实时直推。
- **防篡改**：验签失败/哈希不符的消息直接丢弃；恶意回滚头指针会被诚实成员的 DAG 合并自动纠正；消息一旦扩散无法撤销。
- **兼容性**：对网络中的其它 BT 客户端（qBittorrent、Transmission……）而言，本应用是一个行为正常的 libtorrent 客户端；不支持 `bc_chat` 扩展的 peer 只是收不到聊天消息，互不影响。

协议细节见 [docs/PROTOCOL.md](docs/PROTOCOL.md)，实现架构见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 仓库结构

```
├── app/                  # Flutter 应用（Material 3，中文 UI）
├── core/                 # Rust workspace
│   ├── bitte-core/       #   纯 Rust 核心：bencode、Ed25519/BEP44、聊天 DAG、
│   │                     #   SQLite 对象库、RSS、JSON 桥、Mock 引擎（全部可离线测试）
│   ├── bitte-bt/         #   libtorrent C++ 封装（bc_chat 扩展插件、BEP44、C ABI）
│   └── bitte-ffi/        #   libbitte_core.so：暴露给 Dart FFI 的 C ABI
├── scripts/              # Android 原生构建链（OpenSSL→libtorrent→C++→Rust）
└── .github/workflows/    # CI：核心测试 / Flutter 分析 / Android 构建 / Release
```

## 构建

所有构建都在 GitHub Actions 中进行（沙盒环境不构建）：

- **core-test**：`cargo fmt` / `clippy -D warnings` / 49 个单元与端到端测试（两个 Mock 引擎实例模拟双用户全流程：建群、入群、离线 DHT 同步、附件传输、长文分块、篡改拒绝）。
- **app-analyze**：`flutter analyze` + `flutter test`。
- **android**：交叉编译 OpenSSL 3.5.5、libtorrent 2.1.2（NDK, arm64-v8a + x86_64）→ Rust `libbitte_core.so` → `flutter build apk --release --split-per-abi`，APK 作为 artifact 上传；打 `v*` tag 自动发布 Release。

本地复现原生构建（需要 NDK + Rust android targets + cargo-ndk）：

```bash
bash scripts/build-android-native.sh
cd app && flutter build apk --release --split-per-abi
```

## 使用须知（v0.x）

- 首次加入群聊需要群内有成员在线做种清单种子（与普通 BT 内容一致）。
- 消息传播依赖公共 DHT；应用退出后同步停止（移动端暂无前台服务）。
- 仅支持 arm64-v8a / x86_64 设备；单条消息 ≤ ~600 字节文本（超长自动分块链）。
- 本项目为 Unlicense 公有领域软件，仅供学习交流；请遵守所在地法律法规。

## 路线图

- [x] v0.1 核心协议 + Rust 全逻辑 + CI
- [x] v0.2 libtorrent Android 构建链 + APK 产出
- [ ] v0.3 Flutter 三页签 UI 完整接入
- [ ] v0.4 打磨：图标/通知/设置/多语言、armeabi-v7a、目录做种
