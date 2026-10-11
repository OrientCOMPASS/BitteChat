# BitteChat v0.5.27 交付说明与装机测试清单

- 版本：`0.5.27+32`（自 `0.5.26+31` 步进 0.0.1）
- 提交：`562a977` → … → `37efc5d`（= 标签 `v0.5.27`）；其后 `fcbae94` 等仅 CI 修复，无应用代码变化
- Release：https://github.com/OrientCOMPASS/BitteChat/releases/tag/v0.5.27
  （arm64 / x86_64，release keystore 签名，可覆盖安装 v0.5.26）
- CI：run `38121840642` 全绿（core-test / app-analyze / android / native-smoke /
  emulator-verify），emulator 截图见 CI artifacts `emulator-shots-<sha>`
  （shot-chat-inline.png：发送方气泡内联图片；shot-jump-chip.png：历史中段 50% 半透明回底钮）
- 本轮针对真机反馈三题 + 事件通道根因 + 模拟器验证与 CI 增量化的建设

---

## 一、修复内容

### 0. 根因（本轮最重要发现）：Android 上 FFI 事件推送回调从未工作
模拟器集成测试**确定性复现**了真机现象：`chat.attachment_progress` 事件到达 Dart 的数量为 **0**
（`phases seen: []`）。即旧版通过 `NativeCallable` 注册的原生→Dart 推送回调在 Android
（真机与模拟器）上从不触发，历史上所有“即时”行为实际都靠 10–12s 轮询兜底——这同时解释了
①进度条卡住、②角标延迟、③下载完成不刷新 三个现象的“事件丢失”部分。

修复：事件通道改为**拉取式**：core 侧事件队列保留在句柄注册表，新增 `sys.drain_events`
方法一次取出全部排队事件；Dart 侧 200ms 定时器拉取并注入原有广播流（所有既有监听者不变）。
ABI 不变（bc_init 仍接收回调参数但忽略）。全平台事件延迟 ≤200ms，与回调语义无关。

### 1. 发送方「正在计算文件哈希…」长时间停留（v0.5.26 /watchdog 兜底前）
真机存在**事件流不可达/迟达**的设备表现（progress 事件丢失，消息却经轮询入库）。
v0.5.27 不再依赖事件单通道：
- 会话页 3s 轮询下限：发送任务在飞期间，每轮检查存储中是否已出现**自己的附件消息**
  （ts ≥ 发送时刻），出现即按「已发送」清除进度条并弹「已发送，做种中」（≤3s 自愈）；
- worker 增加 core 日志（spawn/phase/sent），再复发可直接导出日志定位事件链路；
- 90s 看门狗保留为最后兜底。

### 2. 接收方下载完成后预览不刷新（需退出重进）
- 新增 download-watch：点过「通过 BT 下载」的消息进入监听集合，完成（have_file 翻转）
  当轮刷新气泡为媒体预览，无需离开会话；
- `bt.updated` 事件到达时立即刷新（事件正常时 ≤3s 内甚至即时）；
- 3s 轮询下限兜底事件丢失场景。

### 3. 页签未读角标延迟（参考 PiliPlus「动态」角标重构）
PiliPlus 式三源合一：**事件 + 生命周期 + 短轮询下限**
- 主页角标轮询 12s → 3s；回前台（resume）立即刷新；message_new/group_updated 事件即时刷新（原有保留）；
- 会话列表轮询 10s → 4s（预览/角标同步受益）。

### 4. 模拟器验证（CI 新增 emulator-verify，非阻断 + 截图产物）
- android job 上传 jniLibs；新 job 在 Android 模拟器（API 34 / pixel_6 / swiftshader）上
  以**真 libtorrent + 真 FFI 事件回调**跑集成测试：
  - `attach_test.dart`：progress 事件送达断言、发送方就地解析断言、气泡内联图片断言、
    回底按钮「返回意图」语义断言（翻历史不出现/朝底部滑动出现/到底隐藏），并截图；
  - `app_test.dart`：原有 DHT/房间/UI 冒烟；
  - 结束后 adb screencap + 测试截图上传为 artifacts（`emulator-shots-<sha>`）。

---

## 二、装机测试清单（真机，v0.5.26 清单之外增量）

### A. 发送自愈
- [ ] A1 群内发图片：进度条 ≤5s 内消失（正常事件路径为秒级），气泡内联缩略图
- [ ] A2 连发 3 个文件：每个进度条都正常消失，无残留横幅
- [ ] A3 发送后立刻切到别的会话再切回：无横幅残留、消息内联

### B. 接收预览刷新
- [ ] B1 接收方点「通过 BT 下载」：下载完成后 **不退出页面**，气泡在 ≤5s 内自动变为预览（图/视频/音频）
- [ ] B2 下载完成瞬间正在滚动列表：刷新不打断阅读位置

### C. 角标即时性
- [ ] C1 停在「种子」或「订阅」页签时收到新消息：聊天页签角标 ≤3s 出现/累加
- [ ] C2 应用切后台收消息再回前台：角标立即正确（不等待轮询周期）
- [ ] C3 会话列表行内未读气泡与最后一条预览 ≤4s 刷新

### D. 回归（v0.5.26 项目抽验）
- [ ] D1 回底按钮语义：翻历史不出现；朝底部滑动出现（50% 半透明）；松手保持；到底隐藏
- [ ] D2 发送方旧消息（v0.5.25 及以前）仍内联显示
- [ ] D3 文本/引用/@/已读双勾 正常

---

## 三、验证矩阵（run 38124681388 @37efc5d，全绿）
| 层 | 内容 | 结果 |
|---|---|---|
| core-test | fmt/clippy/e2e（含发送方就地解析断言） | ✅ 0.5–0.8min |
| app-analyze | format/analyze/flutter test | ✅ ~1min |
| native-smoke | 真 libtorrent FFI 冒烟 | ✅ ~1.2min |
| android | release APK（split per ABI） | ✅ ~5.5min |
| emulator-verify | 真引擎集成测试 + 截图（非阻断） | ✅ 6.7min（缓存命中） |
| emulator 门禁 | 源码未变 push（run 38126941995） | ✅ 1.2min，真机轮跳过 |

### 模拟器截图（CI artifacts `emulator-shots-*`，测试内 RepaintBoundary 抓取，已目视确认）
- `shot-chat-inline.png`：自发附件气泡内联缩略图、无「通过 BT 下载」卡片、无哈希横幅
- `shot-jump-chip.png`：历史中段朝底部滑动后右下出现 50% 半透明回底钮
- 抓取机制：测试写 PNG 到应用私有目录；`scripts/emu-run-and-pull.sh` 在测试运行期间
  以 adb root 并发拉取（flutter test 退出即卸载应用并删除数据目录，事后拉取必空）

## 三·二、CI 增量化与缓存（本轮建设）
| 缓存 | 覆盖 | 效果 |
|---|---|---|
| rust-cache + 自建 native 缓存 | core-test / android / native-smoke | 命中，core-test 0.5min |
| flutter SDK + pub 缓存 | 全部 flutter job | 命中 |
| gradle 共享缓存（android+emulator 同 key） | android / emulator | debug 348s→111s |
| AVD + 启动快照（reactivecircus priming） | emulator | 3.4GB 快照 ~15s 恢复 |
| emulator 增量门禁 emu-ok marker | emulator | 源码未变 → 跳过真机轮（1.2min） |

配额管理教训：仓库缓存上限 10GB；曾达 10.43GB，小缓存（门禁 marker、rust core-test）
被驱逐、门禁失效。已移除性价比低的 NDK 缓存（2.74GB/省75s）并合并双 gradle 缓存，
当前稳定 ~8.4GB。另修复门禁哈希陷阱：gen-l10n 在 pub get 时重写 app/lib/l10n/*.dart，
restore（干净 checkout）与 save（gen 后）哈希不一致 → 门永不命中；现 restore 前先 pub get。

## 四、已知边界
- 3s/4s 轮询为**兜底下限**：事件正常时一切仍为事件驱动即时刷新；轮询仅轻量 SQL 查询，
  功耗影响可忽略（如需更激进可再缩短，权衡电池）
- 发送后删除/移动源文件：自己气泡回退为 BT 卡片（与就地做种决策一致）
