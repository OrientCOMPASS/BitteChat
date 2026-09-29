# BitteChat

**去中心化的 BitTorrent 群聊客户端** —— **任何一个现有的 BT 种子就是一个群聊**：添加种子（磁力链 / info hash / 种子文件）即进入它的聊天室，与同一 swarm 中的其他 BitTorrent 用户交流。聊天记录像 git 一样以哈希链（DAG）保存和传播，无法被任何单点篡改或删除。

Flutter (Android) 前端 + Rust 核心 + [libtorrent](https://www.libtorrent.org/) 后端。应用分三个经典页签：

| 页签 | 功能 |
|------|------|
| 💬 聊天 | **添加种子即进入它的群聊**（磁力链 / 40 位 info hash / 种子文件，QR/系统 magnet 意图唤起）、群名跟随种子名（**本地备注**，不广播）、**端到端加密私聊**（对方同意后才建立；在线状态；消息只在两台设备间直连传输、仅本地存储）、成员列表一键发起私聊、收发文字与文件（附件在后台线程哈希/复制/做种，大文件不卡界面）、长按复制/验签信息/一键屏蔽作者、被屏蔽消息折叠显示、消息哈希链同步、未读角标、图片全屏查看（contain 不裁剪 + 双指缩放/双击放大）、**退群可选清空本地历史**（进错哈希链后重置） |
| 🧲 种子 | 标准 BT 客户端：磁力链/info hash/种子文件下载、做种、**Tracker 管理（全局默认列表 + 单任务增删）**、文件优先级、peer 列表（标记聊天能力）、任务详情、一键进入该种子的群聊、全局限速 |
| 📰 订阅 | RSS/Atom 订阅阅读，条目中的磁力链/种子附件一键转入 BT 下载 |

- **多语言**：简体中文 / English（flutter gen-l10n，跟随系统）。
- **身份档案**：昵称绑定 Ed25519 私钥；可创建/切换/删除多个身份（改名=新身份，删除不可恢复，均有明确警告）。**头像与昵称仅存本机，不广播**。
- **全局壁纸**：任意页面透出；选图后进入**取景页**（单指拖动、双指缩放/旋转、双击复位；画布比屏幕宽一圈，四周留白可填 透明/纯黑/**纯白(默认)**；虚线框标出屏幕最终可见范围；重新打开编辑器永远是**原图**而非上一轮成品；留白与图片拼接处做 straight-alpha 混合 + 边缘愈合，浅色填充不再出现灰线）。壁纸解码结果由 app 级缓存持有、不透明度在绘制时按 alpha 调制（无 Opacity 全屏 saveLayer），页面/路由切换零延迟、无重载闪烁。
- **视频播放**：media_kit（libmpv，PiliPala/PiliPlus 同源方案）+ **解码降级链**：零拷贝硬解（`hwdec=mediacodec`）→ 硬解回读（`mediacodec-copy`）→ 软解（`no`）。mpv 在部分机型的零拷贝 interop 上会「解码器在跑但一帧都渲染不出来」且**自身不回退**（实机指纹：`vo/gpu/aimagereader … Waiting for frame timed out! / acquireLatestImage failed: -30001`，表现即有声无画），本应用按日志指纹 + 首帧看门狗自动降级到下一档并续播，最终可用的档位会记住（下次直接起步）。播放体验：控制条 3 秒无操作自动隐藏（点按唤回、隐藏时沉浸全屏）、**倍速 0.5×–3×**、出声即申请 Android 音频焦点并停掉应用内语音条（不与其他媒体叠播）。诊断日志已瘦身：mpv 逐行日志只进内存供降级判定，落盘仅 error + 档位/首帧/降级事件，logcat 快照只在降级或报错时采集。
- **诊断**：核心与 Dart 侧各一份**定长日志**（单个文件超过 64 KiB 即删掉前一半行数继续积累，不做多代滚动）+ 崩溃/错误捕获，设置页一键**导出日志到 Download 目录**：导出包里永远是最新的上下文，且不会随时间无限增长。
- **消息过滤**：按内容/昵称/公钥 × 包含/等于/正则自定义屏蔽规则，支持**过滤脚本**（规则集 JSON 直接编辑/导入/导出，便于批量配置与分享）；被屏蔽消息**不删除**（哈希链完整性不受影响），在界面折叠为「n 条被屏蔽的消息」，可展开审查。
- **聊天附件隔离**：附件走内部种子通道，不污染种子页（可开关显示）。**发送文件原地做种**（不再复制进下载目录，大文件秒发）；**下载目录可自定义**（新任务与接收的附件生效）。
- **断点/进度持久化**：所有任务定期快照 libtorrent resume data（重启不重新校验/拉元数据，大文件进度不再"归零"）。

## 核心概念

- **群 = 种子**：不需要"创建"群聊——**每个 BT 种子天然自带一个聊天室**，房间 ID 就是种子 infohash。添加任意种子（磁力链 / info hash / .torrent）即进入它的群聊；把种子分享给别人 = 邀请进群。群聊头指针的签名密钥由 infohash 确定性派生，任何持有种子的人都能独立推导，无需交换清单文件。
- **消息 = git 对象**：每条消息经作者 Ed25519 签名，引用父消息的 SHA-1，形成有向无环图（DAG）。并发发言产生多个"头"（heads），后续消息通过引用全部头完成合并——与 git 的分支/合并模型一致。
- **传播 = BEP44 DHT + BT 扩展消息**：消息本体作为 DHT 不可变条目（内容寻址）存储；每个群的头指针作为 DHT 可变条目（infohash 派生密钥签名、序号单调）发布；同一种子 swarm 内已连接的成员之间通过自定义 BEP10 扩展消息 `bc_chat` 实时直推。扩展握手携带节点身份公钥（`bc_pk`）：支持**定向投递**（私聊帧只发给对方一人）、按身份的**在线状态**；做种端之间保持连接（关闭 redundant-connection 回收），纯做种 swarm 也能聊天同步。
- **Tracker 支持**：可配置全局默认 Tracker 列表（自动附加到所有新任务与聊天附件）并对单个任务增删 tracker；DHT 引导节点可配置，纯 DHT 环境也能工作。
- **防篡改**：验签失败/哈希不符的消息直接丢弃；恶意回滚头指针会被诚实成员的 DAG 合并自动纠正；消息一旦扩散无法撤销。
- **兼容性**：对网络中的其它 BT 客户端（qBittorrent、Transmission……）而言，本应用是一个行为正常的 libtorrent 客户端；不支持 `bc_chat` 扩展的 peer 只是收不到聊天消息，互不影响。你在下载热门种子时，swarm 里其他 BitteChat 用户就是天然的群友。

协议细节见 [docs/PROTOCOL.md](docs/PROTOCOL.md)，实现架构见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，视频播放链路（含「有声无画」根因与解码降级链）见 [docs/VIDEO-PLAYBACK.md](docs/VIDEO-PLAYBACK.md)。

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
- 视频播放使用 media_kit（libmpv）后端：v0.5.2 起从 fvp/mdk 切换到 PiliPala 系同源、经大规模实机验证的 mpv 渲染路径；v0.5.6 起加入**解码降级链**（零拷贝硬解 → 硬解回读 → 软解），部分机型的 mpv 零拷贝 interop 取不到帧时会自动降级续播而不是黑屏，播放页底部显示当前解码档位。
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
- [x] v0.5.2 **私聊重构**（对方同意制、定向传输、无种子/无 DHT、在线状态）+ 群名改本地备注 + 头像不广播 + 壁纸裁剪预览页（预解码零延迟）+ **音视频栈切换 media_kit/libmpv**（视频纯硬解，修复实机"有声无画"；语音条共享单实例）+ resume data 进度持久化（重启进度不归零）+ 附件后台线程化（大文件不卡 UI）+ DHT 就绪队列（冷启动不丢 BEP44 操作）+ 日志导出到 Download + 做种端保持聊天连接
- [x] v0.5.4 视频黑屏第二根因修复（mpv `video-sync=display-resample` + ao 三级回退，音频 underrun 不再拖死视频时钟）+ 私聊邀请改为**聊天列表内联 接受/拒绝/屏蔽**（持久化收件箱，不再弹窗轰炸；屏蔽名单静默丢弃后续请求）+ DM 附件下载/会话预览解密封修复 + **固定发布签名密钥（可覆盖安装升级）**
- [x] v0.5.3 实机视频黑屏根治：**关闭 Impeller**（Skia/GL 渲染——Impeller 外部纹理在部分 Adreno 机型卡死 mpv 的 SurfaceTexture 生产者：aimagereader 帧堆积 -30001、音频 underrun；PiliPala 系同款规避）+ 附件"已下载"判定改为**引擎校验完成态**（修复稀疏预分配文件被当成完整文件打开：接收端"Failed to recognize file format"）+ 播放页文件取证日志（ftyp/moov/零填充）+ 播放器销毁竞态加固
- [x] v0.5.5 **CI 真视频播放测试**（ffmpeg 生成 H.264 样片 → 模拟器实播，断言解码参数/时钟推进/无渲染停摆特征日志）+ 播放期隐藏壁纸与 logcat 自采集（渲染后端/驱动取证）+ 壁纸编辑重做（完整原图取景/旋转/透明 padding/模糊强度滑杆）+ 过滤脚本编辑/导入/导出 + 自定义下载目录 + 发送文件原地做种（kind 4 独立 scope）+ Tracker 设置移入种子页 + DM 附件下载与预览解密封修复 + 生命周期/意图转发加固
- [x] v0.5.6 实机问题修复：**视频「有声无画」根治**（mpv `hwdec_aimagereader` 零拷贝 interop 在部分机型取不到帧且自身不回退 → 加入 `mediacodec → mediacodec-copy → 软解` 三档降级链，按日志指纹/首帧看门狗自动降级续播并记住本机可用档位）+ 壁纸取景重做（画布外扩 25% 留白、手势旋转缩放取代四方向按钮、留白填充色 透明/纯黑/纯白/边缘延展、去掉与设置页重复的透明度/模糊滑杆）+ 壁纸解码缓存与不透明度烘进 alpha（切页不再重载/闪烁）+ 聊天图片全屏查看改为 contain 不裁剪 + 退群可清空本地历史（重置错误哈希链）+ 日志改为单文件定长（超 64 KiB 删前一半行数）+ Release 资产带名称与版本号 + 恢复壁纸在播放期的原有行为
- [x] v0.5.7 实机回归收尾：确认零拷贝硬解在该机型恢复正常（tier 0 settled）后**瘦身播放诊断日志** + 播放器 UX（控制条自动隐藏/沉浸、倍速 0.5–3×、音频焦点阻断其他媒体）+ 壁纸取景修正（默认居中、单指拖动跟手、straight-alpha 消灭拼接灰线、去掉边缘扩展且默认纯白、重编辑回到原图）+ 图片查看支持整体缩小松手回弹
- [ ] 路线图：**LLM 内容过滤** —— 用 LLM 直接判断一条消息是否应被屏蔽（语义级判定，取代当前 包含/等于/正则 的文本匹配；不是"用 LLM 生成过滤脚本"）
- [ ] 路线图：接入 **PBH（Peer Black Hole / IBD peer 黑名单）** 屏蔽恶意与吸血 peer
- [ ] 路线图：**桌面端适配** —— Windows / Linux / macOS 三平台（核心是纯 Rust + libtorrent，已有 `build-linux-native.sh` 主机构建链；主要工作在桌面窗口工程、托盘与文件关联）
- [ ] v0.5+：前台服务保活、消息搜索、armeabi-v7a、目录做种、分 ABI 发布包瘦身

## 许可与第三方组件

**签名**：Release APK 使用仓库内固定的公开签名密钥
（`app/android/keystore/release.jks`，口令 `bittechat`）——公共领域项目经
GitHub Releases 分发，固定透明密钥保证**可覆盖安装升级**。注意：v0.5.4 起
更换签名，从旧版本升级需**最后一次**卸载重装，此后均可直接覆盖安装。

本仓库代码为 **Unlicense**（公共领域）。分发的 APK 动态链接以下第三方运行时组件，
各按其原许可证授权（LGPL 组件以动态库形式链接，用户可替换）：

| 组件 | 许可证 | 用途 |
|------|--------|------|
| Flutter / Dart | BSD-3-Clause | UI 框架 |
| libtorrent | BSD-3-Clause | BT/DHT 引擎（静态链入 libbitte_core.so） |
| OpenSSL | Apache-2.0 | TLS/加密（静态链入 libbitte_core.so） |
| Boost | BSL-1.0 | C++ JSON/工具（静态链入 libbitte_core.so） |
| media_kit / media_kit_video | MIT | 播放器 Dart 层 |
| mpv / libmpv、FFmpeg | LGPL-2.1+ | 音视频解码渲染（libmpv.so 动态链接；源码见上游 mpv-player/mpv、FFmpeg/FFmpeg） |
| Rust crates（ed25519-dalek、rusqlite 等） | MIT / Apache-2.0 | 核心加密与存储 |

视频栈架构参考了开源社区在同类硬件上的成熟实践（PiliPala 系应用，其自身为
GPL-3.0，本项目未复制其代码，仅使用同为 MIT 的 media_kit 上游/fork 包与
公开的功能性配置）。
