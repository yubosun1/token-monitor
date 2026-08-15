# 性能优化交付记录（PLAN.md §8）

测量环境：macOS 15.7.8（Apple Silicon），Swift 6.2.4 CLT，Release 构建；
数据规模：claude 191 / codex 681 / opencode 0 消息，dsh 11 个会话 1575+ 事件（会话运行期间持续追加）。

## 修改前后数字

| 指标 | 优化前（phase0-diag3） | 优化后 | 说明 |
| --- | --- | --- | --- |
| 启动 → 首个 stats push | 12.3s | **5.9s**（首帧为 current 数据，随后 2.3s 内补齐 tokscale/history） | Phase 4 cheap-first + Phase 3 pricing 磁盘缓存 |
| 一次完整刷新 tokscale 子进程 | 6（pricing×2 + 3 periods + graph） | 首次 4（3 periods + graph，pricing 命中磁盘缓存不 spawn）；数据未变化时 **0** | Phase 3 指纹复用 |
| pricing 冷启动 | 每次启动每模型约 5s 网络 spawn | 磁盘缓存（6h TTL 同 JS 语义），命中不 spawn | Phase 3 |
| 稳态 15s tick CPU（数据未变化） | 约 1.32–1.39s（aggregate-periods 占约 1.05s） | 指纹遍历 10ms 级 + build-stats 0.5ms（本机 dsh 因会话运行持续追加，实测每 tick 1.4–1.5s 为真实解压/解析工作） | Phase 3 |
| 数据变化时的重算范围 | 全部客户端 | 仅变化的客户端 | Phase 3 |
| 打开/关闭仪表盘 ×20 的 footprint | 未测（无释放机制） | 每次 teardown 后 118.5–126 MB，无增长；20 次重开全部正常 | Phase 5 |
| 稳态 footprint | 121–124 MB（窗口开）/ 122 MB（tray） | 约 127 MB（含持续变化的 dsh 行缓存） | — |
| 应用实例数 | 无保护 | 恒为 1；二次启动 0.01s 退出并唤起现有窗口；kill -9 后可正常重启 | Phase 1 |
| 退出后遗留 tokscale 子进程 | 可能遗留 | terminateAll 兜底，无孤立进程 | Phase 4 |

## Tokscale 调用次数与阶段耗时变化

- 优化前一次 full tick：6 spawn（2 pricing + 3 period + 1 graph），period 扫描墙钟 14.7s
  （大数据机器按比例放大），graph 4.9s。
- 优化后：首次 full tick 4 spawn（3 period 约 0.85s + graph 0.27s，本机数据量）；
  pricing 由磁盘缓存消化；数据未变化的后继 full tick 日志为
  fingerprint unchanged, reusing snapshot (no subprocess)，0 spawn。
- 120s 观察窗内 tokscale spawn 总数：优化前每 5min 一个 full tick 6 次；
  优化后同窗口 4 次（仅数据变化时的首个 full tick）。
- 设置热更新运行时验证：refreshMs 15000 → 8000 后 timer 重建为 8.0s，
  后续 tick 严格 8s 一次（修复了进程内 Int 写入被 as? Double 读取丢弃的问题）。

## 统计 fixture 一致性

- scripts/check-fixtures.sh：58 项检查（periods/history golden、日期边界、夏令时、指纹行为），
  全部通过，golden 未因任何阶段改动而更新——聚合口径未变。
- 顺带修复既有非确定性问题：适配器分组行按 key 排序，cost 汇总不再有 1 ulp 抖动。
- diag dump 对比：stats 内容随真实数据变化（本机 dsh 持续写入），golden 夹具是口径一致性
  的权威依据。

## 缓存失效规则与错误回退

- 指纹 = 客户端根目录下相关文件的 (path, size, mtime) SHA-256；每 15s tick 轮询即低频对账，
  不依赖文件事件。缺失根目录 → 空指纹（稳定）。
- 客户端快照缓存 rows + periods + history + pricingSignature；指纹或相关模型定价变化才重算。
- tokscale 快照仅在 period 扫描成功后记录新指纹：扫描失败保留旧指纹 → 下一 tick 重试，
  UI 持续显示最后成功数据。TOKEN_MONITOR_FORCE_RESCAN=1（诊断级）可强制真重建。
- pricing 磁盘缓存沿用 6h TTL；写入失败不影响主流程（fail open）。
- 单实例：flock 原子所有，内核在崩溃时自动释放，无陈旧锁窗口；锁目录不可用时 fail open。

## 删除清单与依据

- 基线提交：Electron 专属代码/资源 3522 行（.github 资产、windowsBackdropMode、
  wslStatusPresentation、diagnosticsPanel、floatingBubbleBoot、未用图标等），依据为原生 stage
  脚本与页面引用对账。
- 本轮：Collector.cachedAdapterRows（只写不读）。
- 资源清单与逐项引用依据见 docs/resource-manifest.md。

## 未解决风险与后续建议

- Phase 2（Tokscale 单次扫描）按 §8 暂停：vendored 4.13.0 的 JSON 无逐条目时间字段，
  调查报告与最小 API 设计见 docs/tokscale-single-scan-investigation.md。
- 本机 dsh 会话持续追加导致 dsh 客户端每 tick 真实重算（约 1.4s）；可考虑增量解压
  （按上次偏移续读 zstd）进一步压低活跃写入场景的成本，但涉及解析语义，单独评估。
- 低电量模式降频（Phase 4 可选项）未启用，需产品确认。
- 视觉效果（vibrancy/透明/阴影）未调整：无 GPU 测量工具，PLAN 要求可测收益才动。
- 主窗口采用保守的 hide-only 生命周期；如需长空闲释放，先用 diag 测量重建延迟再定阈值。
