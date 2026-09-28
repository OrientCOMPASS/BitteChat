# BitteChat 架构

## 分层

```
┌─────────────────────────────── Flutter (Dart) ───────────────────────────────┐
│  聊天页 │ 种子页 │ 订阅页        core/bridge.dart (dart:ffi)                  │
│  Material 3, 状态 = ValueNotifier/Stream, 无第三方状态管理框架                │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ C ABI (JSON)
                    bc_init / bc_call / 事件回调(NativeCallable.listener)
┌──────────────────────────────────┴───────────────────────────────────────────┐
│ libbitte_core.so (Rust)                                                      │
│  bitte-ffi        C ABI 封装、句柄注册表、事件转发线程、panic 安全             │
│  bitte-core/api   JSON 桥: dispatch(method, params) + 事件循环 + 调度器        │
│  bitte-core/chat  消息编解码/签名验证、DAG、房间/DM 清单、同步状态机 (sync.rs)  │
│  bitte-core/store SQLite: kv/groups/messages/heads/outbox/torrents/feeds      │
│  bitte-core/rss   ureq+quick-xml: RSS2.0/Atom 解析、磁力/附件提取              │
│  bitte-core/engine  BtEngine trait ──┬── mock.rs  (测试: 共享总线多实例)       │
│                                      └── lt.rs    (生产: → bitte-bt)          │
│  bitte-core/crypto  Ed25519 (dalek)、BEP44 签名/验证、SHA-1                    │
│  bitte-core/bencode 规范 bencode 编解码 (与 libtorrent 字节一致)               │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ C ABI (JSON + base64)
┌──────────────────────────────────┴───────────────────────────────────────────┐
│ libbitte_core.so 内静态链接: bitte_bt_cpp (C++17) + libtorrent 2.1.2 + OpenSSL │
│  bc_create/bc_call/bc_destroy；alert 线程 → 事件 JSON 回调                     │
│  chat_session_plugin / chat_torrent_plugin / chat_peer_plugin:                │
│    - add_handshake 通告 m.bc_chat=42                                          │
│    - on_extension_handshake 学习对端 ID → chat_peer 事件                       │
│    - on_extended 收包(等 packet_finished) → ext_msg 事件                       │
│    - 发送: 任意线程 queue → post_torrent_updates() 唤醒 →                      │
│      session 线程 on_alert/tick 中 flush → send_buffer                        │
│  BEP44: dht_get/put_item(不可变+可变, Rust 预签名)                             │
└──────────────────────────────────────────────────────────────────────────────┘
```

## 关键设计决策

### 1. 单一状态锁 (api/mod.rs)
`CoreState { store, groups, by_ih, pending_joins }` 一把互斥锁。规则：**先取 state 锁，
identity/profile 等叶子 RwLock 只在未持 state 锁时读**（读出后克隆）。引擎调用全部
异步非阻塞，可以在锁内进行。避免了 store/groups 分锁的嵌套死锁风险。

### 2. BtEngine trait + MockEngine
核心逻辑（聊天 DAG、同步、RSS、JSON 桥）与 libtorrent 完全解耦：
- Linux CI 用 MockEngine（共享 MockBus：DHT 字典 + swarm 表 + ext 收件箱），
  两个 Api 实例 = 两个用户，端到端测试全部协议路径（含离线重连、篡改拒绝）。
- Android 用 lt.rs → bitte-bt FFI → C++ → libtorrent。
新增功能先在 mock 下写 e2e 测试，再保证 lt 实现同一语义。

### 3. 规范 bencode 是正确性根基
DHT 不可变条目 target = SHA1(值字节)，C++ 侧 entry 会经历 bdecode→bencode 往返。
Rust 编码器输出必须与 libtorrent 逐字节一致（键排序/最短整数/无空白），否则 target
漂移、消息永远取不回来。bencode.rs 用严格解码器（拒绝非规范输入）+ 往返测试保障；
`dht_put_immutable` 带 expected_target 校验，C++ 回传 matches_expected。

### 4. BEP44 签名全部在 Rust 完成
可变条目签名 = ed25519(bencode({"seq","v"}) + salt)。Rust 用 ed25519-dalek 复现
libtorrent `sign_mutable_item` 的字节布局（键序 seq<v，orlp/ed25519 与 RFC8032 兼容），
好处：加密栈完全可离线单测；C++ dht_put_item 回调只做填充。收到条目后用同样
字节序列验证。

### 5. 扩展消息发送的线程模型
libtorrent `peer_connection_handle::send_buffer` 直接操作连接对象，**非线程安全**。
Rust 线程的 ext_send 只把 payload 塞进 per-peer 插件的互斥队列，然后
`post_torrent_updates()` 制造一个 alert；session 插件（alert_feature|tick_feature）
在 alert/每秒 tick 时于 session 线程冲刷队列组帧发送。延迟 ≈ 一次 io_context 往返。

### 6. JSON 桥
Dart↔Rust 只走两条通道：`bc_call(method, json) -> json`（同步，命令）与事件回调
（异步，UI 流）。二进制统一 hex/base64。好处：无需 ffigen/结构体同步，接口演进
只改 JSON schema；代价是可忽略的序列化开销（聊天流量级别）。

### 7. 数据目录布局 (app 私有外部存储)
```
<data>/bitte.db                     SQLite (WAL)
<data>/groups/<manifest_ih>/bitte-group.benc   仅遗留清单频道（v0.5.2 起 DM 无种子）
<data>/downloads/<ih>/<文件名>       BT 下载与聊天附件（种子群聊即普通任务）
<data>/resume/<ih>.fastresume        libtorrent 断点快照（120s/完成/退出时刷新，添加任务时自动回挂——重启不重新校验、进度不清零）
<data>/logs/core.log(.1/.2)          核心滚动日志（2MB×3，逐行落盘）；Dart 侧 logs/app.log；设置页可导出到 Download
<data>/tmp/                          RSS 导入暂存
```
**种子即群聊**：普通群聊没有专属目录——房间就是 downloads/<infohash> 下的普通 BT
任务（gid = infohash，头签名密钥 SHA-256 派生，见 PROTOCOL §1.2）。重启后
restore_state 从 SQLite（groups + torrents 表）直接重建运行时并重新 add_magnet，
群名在元数据事件到达时自动跟随种子名（用户改名优先）。

## 线程一览 (Rust 侧)

| 线程 | 职责 |
|------|------|
| FFI 调用线程 (Dart isolate) | bc_call → dispatch（持 state 锁，短临界区） |
| bitte-events | 引擎事件 → 协议状态机（DHT 条目验证入库、ext 消息处理、头发布） |
| bitte-sched | 每 1s tick：3s 批量 bt 状态推送 / 5s 群轮询+发布重试（DM 群跳过 DHT）/ 10s outbox（DM 条目走定向 ext 投递）/ 60s RSS 到期刷新 / 120s resume data 快照 |
| bitte-attach | 附件工作线程：哈希→复制→做种→发消息（chat.send_file 立即返回 job_id，进度经 chat.attachment_progress 事件） |
| bitte-events-out | 事件 JSON → Dart 回调 |
| rss/dl worker | 阻塞式 HTTP（ureq），不持任何锁 |

## 构建链 (scripts/build-android-native.sh)

```
boost(源码树+自写 BoostConfig shim) ─┐
OpenSSL 3.5.5 (android-arm64/x86_64, no-shared) ─┤→ libtorrent 2.1.2 (CMake, 静态,
                                                  │   v1_only 由调用侧指定)
                                                  └→ bitte_bt_cpp (静态)
cargo ndk → libbitte_core.so + libc++_shared.so → app/android/.../jniLibs/<abi>/
CI 缓存 build/android-deps/{downloads,src,deps,build}（key=versions.env+脚本哈希）
```

## 测试策略

1. **Rust 单测**（bencode 规范向量、Ed25519/BEP44 字节布局、头密钥派生、消息验证、
   DAG 拓扑/合并/去重、magnet/infohash 规范化、tracker 磁力合并、RSS 解析、store）
   ——`cargo test -p bitte-core`，本地与 CI 秒级。
2. **e2e mock 测试**（tests/e2e_mock.rs）：双节点全流程（做种进房、裸 hash 加入、
   默认 tracker 应用、退群保留任务）、离线 DHT 恢复、附件、分块、篡改拒绝、BT 页生命周期。
3. **CI android job**：真实交叉编译链验证 C++/链接正确性（沙盒内不构建）。
4. **Flutter**：`flutter analyze` + widget 测试（纯 Dart 逻辑：models、桥接解析）。
