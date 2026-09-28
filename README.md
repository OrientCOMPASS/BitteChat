# BitteChat

**去中心化的 BitTorrent 群聊客户端** —— **任何一个现有的 BT 种子就是一个群聊**：添加种子（磁力链 / info hash / 种子文件）即进入它的聊天室，与同一 swarm 中的其他 BitTorrent 用户交流。聊天记录像 git 一样以哈希链（DAG）保存和传播，无法被任何单点篡改或删除。

Flutter (Android) 前端 + Rust 核心 + [libtorrent](https://www.libtorrent.org/) 后端。应用分三个经典页签：

| 页签 | 功能 |
|------|------|
| 💬 聊天 | **添加种子即进入它的群聊**（磁力链 / 40 位 info hash / 种子文件，QR/系统 magnet 意图唤起）、群名跟随种子名（**本地备注**，不广播）、**端到端加密私聊**（对方同意后才建立；在线状态；消息只在两台设备间直连传输、仅本地存储）、成员列表一键发起私聊、收发文字与文件（附件在后台线程哈希/复制/做种，大文件不卡界面）、长按复制/验签信息/一键屏蔽作者、被屏蔽消息折叠显示、消息哈希链同步、未读角标 |
| 🧲 种子 | 标准 BT 客户端：磁力链/info hash/种子文件下载、做种、**Tracker 管理（全局默认列表 + 单任务增删）**、文件优先级、peer 列表（标记聊天能力）、任务详情、一键进入该种子的群聊、全局限速 |
| 📰 订阅 | RSS/Atom 订阅阅读，条目中的磁力链/种子附件一键转入 BT 下载 |

- **多语言**：简体中文 / English（flutter gen-l10n，跟随系统）。
- **身份档案**：昵称绑定 Ed25519 私钥；可创建/切换/删除多个身份（改名=新身份，删除不可恢复，均有明确警告）。**头像与昵称仅存本机，不广播**。
- **全局壁纸**：任意页面透出；选图后进入**裁剪/预览页**（缩放构图 + 透明度/模糊实时预览，所见即所得）；壁纸预解码常驻内存，页面切换零延迟。
- **视频播放**：media_kit（libmpv，PiliPala/PiliPlus 同源方案），**纯硬解链**（`hwdec=mediacodec,auto-safe`，禁用 FFmpeg 软解回退）；解码失败明确报错并可一键外部播放器打开；mpv 日志/视频参数/错误全量写入可导出日志。
- **诊断**：核心滚动文件日志 + Dart 侧崩溃/错误捕获，设置页一键**导出日志到 Download 目录**。
- **消息过滤**：按内容/昵称/公钥 × 包含/等于/正则自定义屏蔽规则；被屏蔽消息**不删除**（哈希链完整性不受影响），在界面折叠为「n 条被屏蔽的消息」，可展开审查。
- **聊天附件隔离**：附件走内部种子通道，不污染种子页（可开关显示）。
- **断点/进度持久化**：所有任务定期快照 libtorrent resume data（重启不重新校验/拉元数据，大文件进度不再"归零"）。

## 核心概念

- **群 = 种子**：不需要"创建"群聊——**每个 BT 种子天然自带一个聊天室**，房间 ID 就是种子 infohash。添加任意种子（磁力链 / info hash / .torrent）即进入它的群聊；把种子分享给别人 = 邀请进群。群聊头指针的签名密钥由 infohash 确定性派生，任何持有种子的人都能独立推导，无需交换清单文件。
- **消息 = git 对象**：每条消息经作者 Ed25519 签名，引用父消息的 SHA-1，形成有向无环图（DAG）。并发发言产生多个"头"（heads），后续消息通过引用全部头完成合并——与 git 的分支/合并模型一致。
- **传播 = BEP44 DHT + BT 扩展消息**：消息本体作为 DHT 不可变条目（内容寻址）存储；每个群的头指针作为 DHT 可变条目（infohash 派生密钥签名、序号单调）发布；同一种子 swarm 内已连接的成员之间通过自定义 BEP10 扩展消息 `bc_chat` 实时直推。扩展握手携带节点身份公钥（`bc_pk`）：支持**定向投递**（私聊帧只发给对方一人）、按身份的**在线状态**；做种端之间保持连接（关闭 redundant-connection 回收），纯做种 swarm 也能聊天同步。
- **Tracker 支持**：可配置全局默认 Tracker 列表（自动附加到所有新任务与聊天附件）并对单个任务增删 tracker；DHT 引导节点可配置，纯 DHT 环境也能工作。
- **防篡改**：验签失败/哈希不符的消息直接丢弃；恶意回滚头指针会被诚实成员的 DAG 合并自动纠正；消息一旦扩散无法撤销。
- **兼容性**：对网络中的其它 BT 客户端（qBittorrent、Transmission……）而言，本应用是一个行为正常的 libtorrent 客户端；不支持 `bc_chat` 扩展的 peer 只是收不到聊天消息，互不影响。你在下载热门种子时，swarm 里其他 BitteChat 用户就是天然的群友。

协议细节见 [docs/PROTOCOL.md](docs/PROTOCOL.md)，实现架构见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 仓库结构

```
├── app/                  # Flutter 应用（Material 3，zh/en 双语 UI）
├── core/                 # Rust workspace
│   ├── bitte-core/       #   纯 Rust 核心：bencode、Ed25519/BEP44、聊天 DAG、
│   │                     #   SQLite 对象库、RSS、JSON 桥、Mock 引擎（全部可离线测试）
│   ├── bitte-bt/         #   libtorrent C++ 封装（bc_chat 扩展插件、BEP44、tracker、C ABI）
│   └── bitte-ffi/        #   libbitte_core.so：暴露给 Dart FFI 的 C ABI
├── scripts/              # Android 原生构建链（OpenSSL→libtorrent→C++→Rust）
└── .github/workflows/    # CI：核心测试 / Flutter 分析 / Android 构建 / Release
```

## 构建

所有构建都在 GitHub Actions 中进行（沙盒环境不构建）：

- **core-test**：`cargo fmt` / `clippy -D warnings` / 全量单元与端到端测试（两个 Mock 引擎实例模拟双用户全流程：做种进房、hash 直连、离线 DHT 同步、附件传输、长文分块、篡改拒绝、tracker 应用）。
- **app-analyze**：`flutter analyze` + `flutter test`。
- **emulator-smoke**（非阻断）：Android 模拟器安装真实构建，跑 `integration_test`：真 libtorrent 引擎启动 → 做种真实文件 → 以裸 infohash 进入群聊 → 默认 tracker 生效校验 → 发消息 → 等待 BEP44 DHT 确认 → UI 渲染校验。
- **android**：交叉编译 OpenSSL 3.5.5、libtorrent 2.1.2（NDK, arm64-v8a + x86_64）→ Rust `libbitte_core.so` → `flutter build apk --release`（通用 APK，abiFilters 限定 arm64-v8a/x86_64），APK 作为 artifact 上传；打 `v*` tag 自动发布 Release。

本地复现原生构建（需要 NDK + Rust android targets + cargo-ndk）：

```bash
bash scripts/build-android-native.sh
cd app && flutter build apk --release --split-per-abi
```

## 使用须知（v0.x）

- 群聊消息通过公共 DHT 与 swarm 内在线成员传播：冷门种子（无人做种/无 DHT 记录）可能暂时没有历史消息，配置默认 Tracker 可显著改善连通性。
- 应用退出后同步停止（移动端暂无前台服务）。
- 仅支持 arm64-v8a / x86_64 设备（Android 9 / API 28 及以上）；单条消息 ≤ ~600 字节文本（超长自动分块链）。
- 视频播放使用 media_kit（libmpv）后端 + 纯硬解链：此前 fvp/mdk 在部分机型上"有声无画"（外部纹理合成类设备兼容问题），v0.5.2 起整体切换到 PiliPala 同源、经大规模实机验证的 mpv 渲染路径。
- **v0.5 起群聊模型变更**（种子即群聊），与 v0.4.x 的"清单群"不兼容；私聊（DM）机制不变。
- 本项目为 Unlicense 公有领域软件，仅供学习交流；请遵守所在地法律法规。

## 路线图

- [x] v0.1 核心协议 + Rust 全逻辑 + CI（49 个 Rust 测试）
- [x] v0.2 libtorrent 2.1.2 Android 交叉编译链 + APK 产出
- [x] v0.3 Flutter 三页签 UI 完整接入（16 个 Dart 测试、analyze 0 issue）
- [x] v0.4.1 多媒体聊天（音频/视频/文本预览、外部打开）+ 聊天种子隔离 + 限速归位
- [x] v0.4.2 端到端加密私聊（X25519 + ChaCha20-Poly1305）
- [x] v0.4.3 消息过滤规则引擎（折叠显示，不破坏链完整性）
- [x] v0.4.5 国际化（zh/en）+ 身份档案管理
- [x] v0.5.0 **种子即群聊**（移除"凭空建群"，房间 ID = infohash，头密钥确定性派生）+ Tracker 设置（全局默认列表/单任务增删/DHT 引导可配置）+ info hash 直连输入 + fvp 视频软解兜底 + 全局壁纸
- [x] v0.5.2 **私聊重构**（对方同意制、定向传输、无种子/无 DHT、在线状态）+ 群名改本地备注 + 头像不广播 + 壁纸裁剪预览页（预解码零延迟）+ **视频栈切换 media_kit/libmpv 纯硬解**（修复实机"有声无画"）+ resume data 进度持久化（重启进度不归零）+ 附件后台线程化（大文件不卡 UI）+ DHT 就绪队列（冷启动不丢 BEP44 操作）+ 日志导出到 Download + 做种端保持聊天连接
- [ ] v0.5+：前台服务保活、消息搜索、armeabi-v7a、目录做种、分 ABI 发布包瘦身
