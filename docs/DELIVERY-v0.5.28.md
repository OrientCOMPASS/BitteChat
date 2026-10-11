# BitteChat v0.5.28 交付说明与装机测试清单

- 版本：`0.5.28+33`（自 `0.5.27+32` 步进 0.0.1）
- 标签：`v0.5.28` @ `f9a65b0`；Release：
  https://github.com/OrientCOMPASS/BitteChat/releases/tag/v0.5.28 （arm64 / x86_64，可覆盖安装）
- CI：main run `38135174247` 全绿；tag run `38135550771` release 成功（验证 job 按设计在 tag 跳过）

---

## 一、群聊消息同步时机（代码事实，答复真机疑问）

| # | 通道 | 触发 | 依赖 |
|---|---|---|---|
| 1 | swarm 直推 live | 对端发言时向群 swarm 广播 `ExtPayload::Msg` → `on_ext_message` 立即 ingest | 群 swarm 内有已连接 peer |
| 2 | swarm heads 互宣 | heads 变化时 `ext_announce_heads`；收到 `Heads` 比对缺口，回 `Want`/直推 `Blobs` | 群 swarm 连接 |
| 3 | DHT 头轮询 | scheduler 每 5s tick；会话打开 15s / 否则 90s 间隔发 BEP44 mutable get → 发现新头 → fetch 泵（5s tick，逐目标指数退避 15s→5min）→ immutable get → ingest | DHT get 可用 |
| 4 | 手动刷新 | 会话列表下拉 → `chat.sync` → `kick_group_sync`（poll + pump） | 同 3 |
| 5 | 发送路径 | 发言后 publish_heads + ext_announce_heads + pump | DHT 写 / swarm |

私聊不走 DHT：发送=定向 ext 帧（直发+outbox 重试），接收=同 `on_ext_message` 的 DmMsg 分支。

### 真机现象与通道的对应
- 私聊正常 → ext 接收线程活着；
- 群聊不主动更新 → 通道 1/3 均无产出；
- 下拉刷新无效 → 通道 4 与 3 同路径，且可被 fetch 退避抑制；
- 发言一次拉回全量 → 通道 5 的 ext 宣告让**领先的对端经通道 2 直推 Blobs**（不依赖 DHT）——
  证明 swarm ext 通路活、DHT get 路径（或退避抑制）死。

## 二、v0.5.28 修复
1. **DHT 无关的主动同步**：group_tick 周期性（打开 60s / 关闭 360s）向 swarm 通告 heads，
   领先对端直推缺失 blob——把「发言才触发」的通道变成常态化通道；
2. **手动刷新不再被退避抑制**：`kick_group_sync` 重置 fetch 退避与 in-flight 立即重排队，
   并同时向 swarm 宣告（双路径）；
3. **panic 隔离**：scheduler 每个 tick、engine 事件循环每个事件包 catch_unwind +
   scheduler 60s 心跳日志——单点 panic 不再永久杀死全部主动同步（与本次真机签名一致的静默故障模式）；
4. **info 级同步诊断**：poll_heads、fetch 失败退避、immutable get、ext recv、kick 全落 core.log
   （core.log 上限 info，此前 debug 级在真机等于没记）。

## 三、装机测试清单
- [ ] G1 升级后静置：对端发群消息，本机 ≤90s（会话打开 ≤15s）内主动收到（通道 3/1）；
- [ ] G2 杀掉应用重启后静置：新群消息仍能主动到达（恢复路径）；
- [ ] G3 会话列表下拉：缺口消息立即拉回（不再空转）；
- [ ] G4 断网 10 分钟恢复：缺口在恢复后数分钟内补齐（退避重置+周期 solicit）；
- [ ] G5 回归：私聊收发、群内发言、回底钮、附件发送（v0.5.26/27 项目抽验）；
- [ ] G6 若 G1–G4 任一复发：**设置→导出日志**发回（core.log 现含 poll/fetch/backoff/ext/kick/心跳，
      crash_rust.log 含 panic 取证），可一次定位到死段。

## 四、CI 状态
- 全轮 warm 6.5min（detect∥core-test∥app-analyze∥native-smoke∥native-android → android∥emulator）；
- emulator 增量门禁：源码未变跳过真机轮（1.2min）；
- tag run 仅 release（验证 job 跳过；release needs 改为 detect，修复 all-skipped needs 连带跳过）。
