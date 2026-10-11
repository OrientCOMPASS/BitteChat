# 测试策略与 CI 矩阵（v0.5.28 起生效）

## 仓库策略（强制）
**每一轮功能/修复修改，必须附带覆盖该修改的模拟器集成测试**
（`app/integration_test/` 下新增或扩展用例），否则不予合入/发版：
- UI/交互修改 → 在 `attach_test.dart`（或新文件）中加 widget 级断言 + 关键状态截图；
- 核心/FFI/事件链路修改 → 加 headless API 断言（参考 attach_test 的事件送达断言）；
- 播放/媒体修改 → 扩展 `video_test.dart`；
- 纯 CI/文档修改 → 复用既有套件，但 `.github/workflows/ci.yml` 已纳入门禁哈希，
  harness 变更会自动触发一轮真机验证。

## CI 矩阵（main push）
| Job | 阻断 | 内容 | 增量/缓存 |
|---|---|---|---|
| detect | ✅ | 结构探测 | — |
| core-test | ✅ | rustfmt/clippy/-D warnings、cargo test（mock 总线 e2e） | rust-cache |
| app-analyze | ✅ | dart format/analyze/flutter test | flutter+pub 缓存 |
| native-smoke | ✅ | 宿主机真 libtorrent FFI 冒烟 | native 缓存 |
| native-android | ✅ | OpenSSL+libtorrent+C++ wrapper+Rust cdylib（双 ABI）→ jniLibs 产物 | native+rust 缓存 |
| android | ✅ | release APK（split-per-ABI）+ 签名 | gradle 共享缓存 |
| emulator-verify | ✅ | 模拟器集成测试（attach/app/video/ux）+ 截图上传 | AVD 快照+gradle+pub 缓存 + **emu-ok 门禁**（源码哈希未变跳过真机轮） |
| release | 仅 tag | 复用分支 run 的 APK 发布 | — |

tag run 仅跑 release（验证 job 在同 commit 的 main push 已绿，避免重复燃烧）。

## 模拟器测试基建
- 截图：测试内 `RepaintBoundary.toImage()` 写 PNG 到应用私有目录；
  `scripts/emu-run-and-pull.sh` 在测试运行期间以 adb root 并发拉取
  （flutter test 退出即卸载应用删数据，事后拉取必空）；产物 `emulator-shots-<sha>`。
- 门禁：`emu-ok-<hashFiles(app/lib, integration_test, core rust, pubspec.lock,
  gradle kts, versions.env, emu-run-and-pull.sh, ci.yml)>` marker 缓存；
  命中即跳过真机轮（~1.2min），未命中跑全套并在成功后 save。
- 缓存预算：仓库上限 10GB；当前 ~8.4GB（AVD 3.4 + gradle 1.9 + flutter 1.7 + 其余）。
  新增缓存前必须核算预算（v0.5.27 曾超配额导致小缓存被驱逐、门禁失效）。

## 历史
- v0.5.13–v0.5.27：模拟器集成测试下线（emulator-smoke 停止），仅宿主机测试门禁；
  期间真机专属故障（Android FFI 事件回调不送达）无法在 CI 发现 —— 本策略的直接教训。
- v0.5.28：emulator-verify 重建（缓存+门禁+截图），并升级为阻断门禁。
- 交付清单（DELIVERY-*.md）不入库，随每轮交付单独提供；docs/ 仅保留
  ARCHITECTURE / PROTOCOL / TESTING。
