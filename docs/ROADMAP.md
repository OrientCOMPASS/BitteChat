# ROADMAP — 路线图

> 版本策略：仓库自 **v0.0.1** 起全新开始（此前的迭代历史已随仓库重置清除，
> 不再追溯）；每轮交付步进 **0.0.1**，tag `vX.Y.Z` 触发 Release
> （复用同 commit 分支 run 的产物）。
> 测试策略见 `docs/TESTING.md`（每轮修改必附对应模拟器集成测试）。
> 多平台（桌面 GUI + WebUI）路线与已落地的准备工作见 `docs/PLATFORMS.md`。

## 一、现状快照（v0.0.2）

- 发布平台：Android（arm64-v8a / x86_64），CI 产出签名 APK 并经模拟器
  集成测试门禁（真 libtorrent 引擎）。
- 架构：Flutter UI → C ABI（libbitte_core）→ Rust 核心（协议/DAG/同步/存储/RSS）
  → C++ libtorrent 封装。核心为纯 Rust、平台无关；引擎经 `BtEngine` trait
  抽象（生产 = libtorrent，测试/演示 = 进程内 mock）。
- 同步：swarm 扩展消息直推 + DHT 头轮询/抓取泵 + 周期 swarm solicit。
- 多平台准备（本轮落地，不含具体实现）：
  - Dart 侧平台抽象层（`HostPlatform` 探测、`CoreTransport` 传输接口、
    native 传输实现与 web 传输占位）；
  - FFI 动态库名解析扩展到 Linux/macOS/Windows；
  - `bitte-bt` 构建脚本的桌面平台链接分支骨架；
  - `platforms.yml` 准备工作流（手动触发）与 `docs/PLATFORMS.md` 路线文档。

## 二、路线图

### 短期（近 1–3 轮）

- [ ] 群聊同步 DHT 失效根因定位：依同步诊断日志（poll/fetch/backoff/心跳）
      判定 DHT get 无响应 vs 退避抑制 vs 线程异常；必要时增加 DHT 引导节点
      可配置 / swarm-only 降级开关
- [ ] 双实例模拟器测试：发送/接收两 emulator 实例互联，覆盖接收路径
      （下载→预览→已读）与 DM 握手，补足单实例无法验证的半区
- [ ] 通知与后台同步：Android 前台服务 + 轮询策略（功耗评估入 CI 报告）
- [ ] 会话内搜索与按日期跳转（纸带列表索引已具备自底向上估算基础）

### 中期 — 桌面 GUI（Linux → Windows → macOS）

依赖 `docs/PLATFORMS.md` 的准备清单，按序推进：

- [ ] Linux 桌面首平台：`flutter create --platforms=linux` 脚手架 +
      libbitte_core.so 打包（native 栈构建脚本已就绪）+ CI Linux 桌面 job
- [ ] 桌面适配层落地：文件选择/外部打开/音频焦点等 Android MethodChannel
      能力的桌面实现（`CoreTransport` 之下的平台服务接口化）
- [ ] Windows / macOS：native 栈交叉/本机编译验证（build.rs 分支已预留）、
      签名与打包流水线
- [ ] 群治理：管理员/禁言/公告（系统消息 kind 扩展，DAG 兼容）
- [ ] 消息反应（emoji）与编辑标记（协议版本化 + 旧节点兼容规则）
- [ ] 多设备同身份（身份密钥同步 + 每设备头指针合并）

### 长期 — WebUI 与协议演进

- [ ] WebUI 第一阶段（网关模式）：服务器托管 native 核心的 WebSocket-JSON
      网关（复用现有 JSON-RPC 面与 `sys.drain_events` 事件通道），Web 前端
      经 `CoreTransport` 的 web 实现接入
- [ ] WebUI 第二阶段（纯客户端）评估：bitte-core 编译 wasm32 所需的存储/
      网络后端抽象（rusqlite→OPFS/sqlite-wasm、ureq→fetch）、
      DHT 的 WebRTC/中继替代
- [ ] 协议演进：群消息前向保密评估（现群聊为签名公开账本、DM 为 E2E）、
      后量子签名算法调研
- [ ] 受限网络连通性：中继/打洞回退层（swarm 不可达时的兜底传输）
- [ ] 反垃圾与邀请经济（PoW 邀请、tracker 公信列表治理）

### 设计边界（非目标）

- 中心服务器、账号体系、云端历史（WebUI 网关模式是"自托管桥"，不是云服务）
- 群聊无条件端到端加密（群聊定位＝可哈希链验证的公开账本；私密沟通走 DM E2E）

## 三、流程约定

- 每轮：修改 → 对应模拟器测试 → CI 全绿 → 版本步进 0.0.1 → tag 发版 → 交付清单
- 历史条目只增不改；细节以 git log 为准（自 v0.0.1 起）
