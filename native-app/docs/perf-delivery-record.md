# 性能优化交付记录（PLAN.md 审查修复轮）

测量环境：macOS 15.7.8（Apple Silicon），Swift 6.2.4 CLT，Release 构建；
数据规模：claude 191 / codex 681 / opencode 0 消息，dsh 11 个会话（会话运行期间持续追加）。

## 本轮修复（对应审查计划 §1 的 8 项）

| # | 问题 | 修复 | 提交 |
| --- | --- | --- | --- |
| 1 | clients/allTimeSince/日期月边界未失效缓存 | Raw/Derived 两层缓存 + 合并上下文（见下） | 3d773d47 |
| 2 | 启动 cheap 未命中的 pricing 不重试 | PricingPolicy 显式策略；full tick 受控补全 + 每模型 5min 重试下限 | 3d773d47 |
| 3 | 指纹未变化不推进 full 时间 | lastFullCheckAt 在每次完成检查时推进（含复用路径） | 3d773d47 |
| 4 | 采集期间请求不能合并 | 短协调锁 + pending 队列，tick 不持锁；启动 cheap-first 保留 | 3d773d47 + 075d6e73 |
| 5 | tray/快捷键/关闭未发隐藏状态 | ManagedVisibility 状态机统一 show/hide 路径 | 40fc3c00 |
| 6 | 初始化期间唤起请求丢失 | flock 前注册接收器 + pendingActivation 缓冲 | ba3b61b3 |
| 7 | 测试未覆盖 Collector 状态变化 | T1-T9 + V1-V4 + S1-S3 状态测试（见下） | 3d773d47/40fc3c00/ba3b61b3 |
| 8 | git diff --check 失败 | 全部文件末尾空行清理，diff --check = 0 | 各提交 |

## 缓存模型与失效规则

- **Raw cache**：`fingerprint + rows + models`，仅指纹变化时重读源文件。
- **Derived cache**：`periods + history contributions`，key = fingerprint + client +
  allTimeSince + 本地 dayKey + monthKey + pricingSignature（未解析模型记为 UNRESOLVED）。
- **合并上下文**：规范化 enabled clients + allTimeSince + day/monthKey + 各客户端 derived key
  + pricingGeneration；上下文变化即重建 merge/history，禁用客户端立即从 totals/history 消失。
- **Tokscale 快照上下文**：fingerprint + clients + allTimeSince + day/monthKey + pricingGeneration；
  任一变化（含跨午夜/跨月/allTimeSince 修改/自定义定价修改）→ 完整 3+1 重扫（正确性优先，
  二进制无逐条时间字段，无法局部重扫）。
- **pricing 失效**：自定义定价变更 → purge 缓存 + generation+1 + full 刷新；
  full tick 对 unresolved 模型重试（每模型 5 分钟下限，cheap tick 永不 spawn）；
  成功补全后仅从缓存 rows 重新派生，不重读文件。

## 部分失败与退避

- period 与 graph 的成功状态独立记录；period 成功 + graph 失败保留新 periods + 旧 history。
- 重试仅发生在 full check（默认间隔 5min），指数退避 30s·2^n 封顶 600s；
- graph 重试不重跑已成功且输入未变化的 periods（反之亦然）。
- 任一失败不清空最后成功数据；`TOKEN_MONITOR_FORCE_RESCAN=1`（诊断级）绕过指纹。

## Refresh coalescing 状态转换

```
requestRefresh(kind, reason)   [任意线程，只持短锁]
  ├─ 队列空            → 入队(kind, reason)
  ├─ 首个 startup cheap 在队首且 stats 未发布 → 排在它后面（cheap-first 启动）
  ├─ 队列已有 >= 强度 → 丢弃
  └─ 否则             → 替换队中最弱请求
drainWorker  [worker 串行队列，不持锁执行 tick]
  └─ 循环：锁内取队首 + 取失效标志 → 解锁 → 应用失效 → tick → 重复；队空退出
```

- 采集期间到达的 10 cheap + 3 manual full + 1 settings full → 完成后恰一个 full（T7 实测）。
- 无并发 tick；无递归 pump；主线程不等待扫描（协调锁只保护队结构）。

## 窗口可见性路径

- 所有隐藏入口（tray 左键、快捷键、renderer 关闭按钮、失焦自动隐藏、miniaturize）都经过
  `hideManagedWindow()` → orderOut + 恰好一次 `window:visibility=false` + windowDidHide 钩子；
- 所有显示入口经 `showWindow` → 恰好一次 `true` + 取消 idle teardown；
- 页面加载完成后 `resync()` 补发当前原生状态（早于加载完成的 push 会丢失）；
- 状态机去重由 V1-V4 测试锁定；dashboard 显式关闭仍立即 teardown，60s 空闲 teardown 只安排一次。

## 单实例唤起缓冲

- 每次启动在竞争 flock 前注册跨进程唤起接收器；AppDelegate 安装 show 回调前收到的请求
  缓冲为 pendingActivation，安装时恰消费一次（S1-S3 实测）；
- 失败方发通知 + 按锁文件 PID activate 兜底后清理接收器退出，不建 UI/collector/WebView；
- 20 连发启动实测仅存活 1 个实例；kill -9 后内核释放 flock，可立即重启。

## 测量（最终工作区，见 §测量明细）

- launch → 首个 stats push（cheap-first）：**约 6s**（首次 push 为 current 数据）。
- 首个 full 完成后缺失模型费用自动补全（无需改源文件，T5 实测）。
- 启动 tokscale spawn：4（3 period + 1 graph；pricing 走磁盘缓存 0 spawn）。
- collectionIntervalMs 到点后的 full check：0 spawn（指纹未变复用快照），且不会退化为每 15s 检查（T6 实测）。
- 数据未变化 10 分钟空闲 CPU：见 §测量明细（本机 dsh 会话持续写入，残余 CPU 为真实解压/解析）。
- dashboard 开/关 ×20：footprint 稳定无增长（见 §测量明细）。

## 新增测试清单

| 测试 | 验证的回归 |
| --- | --- |
| T1 | 跨午夜后 today 从缓存 rows 重派生，无 raw 重读 |
| T2 | 跨月后 month 重派生，无 raw 重读 |
| T3 | allTimeSince 修改后 adapter allTime 重派生，无 raw 重读 |
| T4 | 禁用客户端立即从 totals/history 消失 |
| T5 | cheap 未命中定价 → full 补全 → 费用更新，无 raw 重读 |
| T6 | scheduled full 检查遵循 collectionIntervalMs；复用推进 cadence；0 spawn |
| T7 | 阻塞 tick 期间 14 个请求 → 完成后恰一个 full |
| T8 | graph 失败保留 periods；退避重试 graph 不重跑 periods；恢复后 history 更新 |
| T9 | 启动先 cheap 后 full（cheap-first 语义） |
| V1-V4 | 可见性事件去重、resync、一次一转事件序 |
| S1-S3 | 早启动唤起缓冲、合并消费、卸载幂等 |

（另有 58 项聚合 golden 夹具与指纹行为检查，共 120 项全部通过。）

## 测量明细（最终工作区实测）

| 指标 | 数值 | 运行 |
| --- | --- | --- |
| launch → 首个 stats push（cheap-first，id=1 kind=cheap） | 6.4s（review-final）/ 6.3s（review-cadence） | .perf/review-final, .perf/review-cadence |
| 首个 push 后 full tick（id=2）补齐 tokscale/history | +6.0s 内 | 同上 |
| 启动 tokscale spawn 数 | 4（3 period + 1 graph；pricing 磁盘缓存命中 0 spawn） | 同上 |
| 60s full 检查（collectionIntervalMs=60000） | 到点后恰一次 source check，日志 "reusing snapshot (no subprocess)"，0 spawn；相邻检查间隔 ≥ 完整周期，无 15s 退化 | .perf/review-cadence |
| 数据未变化稳态 tick CPU（排除持续写入的 dsh） | 每 15s tick 0.00–0.01s（<1% 空闲 CPU），前一轮为 ~1.32s | .perf/review-idle |
| 空闲 180s 窗口内 tokscale spawn | 4（仅启动一次全量） | .perf/review-idle |
| dashboard 开/关 ×20 | 20 次全部正常加载、0 renderer 错误；teardown 后 footprint 135.3→135.6MB 无增长（首循环 143.6MB 因启动期缓存） | .perf/review-lifecycle |
| 20 连发并发启动 | 恰好存活 1 个实例；kill -9 后可立即重启 | 本节运行时命令 |
| 单实例早启动唤起 | 实例 2 在实例 1 启动 200ms 内发起 → 0.01s 退出、无任何 UI/日志，实例 1 正常单实例运行 | /tmp/si3 运行 |

（本机 dsh 会话持续写入，默认配置下每 15s 的真实解压/解析约 1.4s 是数据变化成本，
非冗余重扫；见 .perf/review-final 的 source-dsh 行。）
