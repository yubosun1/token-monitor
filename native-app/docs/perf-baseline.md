# Phase 0 性能基线（优化前）

记录日期：2026-08-15。测量方式：`scripts/perf-baseline.sh`（diag/tray 模式），
应用自身通过 `TOKEN_MONITOR_DIAG` 上报 [perf] 阶段耗时、getrusage CPU 与 task_info footprint；
实例数与 WebKit 子进程数由脚本 pgrep 采样，另取一次外部 `/usr/bin/footprint` 快照。

## 环境

- 机器：macOS 15.7.8，Apple Silicon（arm64），Swift 6.2.4（CLT）
- 数据量（影响扫描耗时）：claude 191 消息、codex 681 消息、opencode 0、dsh 11 个会话 1575 事件；
  proma/hanako 少量
- 构建：Release（`scripts/build-app.sh`），应用位于 `dist/Token Monitor.app`
- 设置：refreshMs=15000，collectionIntervalMs=300000，clients=claude,codex,opencode,workbuddy,proma,hanako,dsh

## 启动路径（diag 模式，窗口打开）

| 指标 | 数值 |
| --- | --- |
| 启动 → 首个 stats push | **12.3s** |
| 首次 full tick 总 CPU | 5.88s（约占 12.2s 墙钟的 48%） |
| tokscale 子进程数（一次 full tick） | **6**：pricing×2 + today/month/allTime×3 + graph×1 |
| 首次 tick 后 footprint | 235.8 MB（主窗口+仪表盘 WebView 已打开） |

首次 full tick 阶段拆分：

| 阶段 | 耗时 |
| --- | --- |
| adapter-proma | 982 ms |
| adapter-hanako | 206 ms |
| adapter-dsh | 2261 ms |
| tokscale pricing deepseek-v4-flash（冷，走网络） | 5341 ms |
| tokscale pricing deepseek-v4-pro（热，命中 tokscale 自身缓存） | 18 ms |
| tokscale today / month / allTime（各约 0.29s，同一批文件扫 3 遍） | 865 ms |
| aggregate-periods | 1073 ms |
| history（graph 子进程 276ms + 解析合并） | 1433 ms |
| build-stats | 1.1 ms |
| push-stats | 25 ms |

结论：首次可用数据被两件事拖慢——(1) 每个新模型一次 `tokscale pricing` 子进程冷启动约 5s；
(2) 4 个 tokscale 子进程重叠扫描同一批文件。两者都发生在首屏关键路径上。

## 稳态（数据未变化，15s 周期 tick，无 tokscale 子进程）

| 指标 | 数值 |
| --- | --- |
| 每个 15s tick 的 CPU | **1.32–1.39s**（≈ 9% 单核稳态） |
| 其中 aggregate-periods | **1.05–1.10s（占 tick 的 ~80%）** |
| adapter-proma / hanako / dsh | ~19ms / 4ms / ~220ms（文件戳缓存命中） |
| build-stats | 0.4–0.6 ms |
| push-stats | ~21 ms |
| 稳态 footprint | ~121–124 MB（窗口打开）/ 122 MB（tray 无窗口；峰值 223 MB vs 241 MB） |

结论：稳态 CPU 主要不是 WebKit 空闲渲染，而是每个 15s tick 无条件重算 today/month/allTime
聚合（大 sessions/models 字典合并）——Phase 3 的按指纹缓存正是冲这里去的。

## 进程与实例

- 应用实例数峰值：1（当前无单实例保护，取决于启动方式）
- WebKit 子进程数峰值：5（两个 WebView + 网络/GPU 进程）
- tokscale 子进程同时存在数峰值：1（顺序执行）
- 外部 footprint 快照：phys_footprint 124 MB / peak 241 MB

## 夹具

- `Tests/TokenMonitorFixtureCheck`（`scripts/check-fixtures.sh`）：固定输入 → periods/history golden 对比，
  覆盖本地午夜、月初、allTimeSince、无时间戳记录、夏令时（America/New_York 2026-03-08）边界；
  当前 47 项检查全部通过，golden 已提交。
- diag 运行会在 `TOKEN_MONITOR_DIAG_DIR` 写入 `stats-NNN.json`/`meta-NNN.json`，
  用 `scripts/compare-dumps.js` 可自动对比任意两次运行的统计结果。
- 本阶段同时修复了一个既有的非确定性问题：适配器分组行的字典迭代顺序随机，
  导致 cost 汇总在最后 1 ulp 抖动（2.9 vs 2.9000000000000004）；现在按 key 排序，
  聚合输出跨进程/跨刷新完全确定。

