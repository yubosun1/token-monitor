# Tokscale 单次扫描可行性调查报告与最小 API 设计（PLAN.md Phase 2 / §8）

> 结论：vendored tokscale 4.13.0 的 JSON 输出**不含**逐条目时间字段，无法用一次扫描同时保持
> today/month/allTime periods、逐日 history 与 session 时间语义。按 PLAN §8 暂停 Phase 2 代码改动，
> 本文记录字段调查结果并给出最小 API 设计。

## 1. 调查对象

- `native-app/Vendor/tokscale/tokscale`（Mach-O arm64，16.7MB，v4.13.0）
- npm 源 `@tokscale/cli-darwin-arm64` latest 同为 4.13.0，无更新版本可换。
- 上游仓库：<https://github.com/junhoyeo/tokscale>（公开，但本仓库只 vendored 了二进制，无 Rust 源码）。
- 本机实测（2026-08-15，数据量：claude 191 消息 / codex 681 消息 / opencode 0）：
  - `--json --group-by client,session,model --today` → 0.31s wall / 0.34s user
  - 同参数 `--month` → 0.31s / 0.33s
  - 同参数 `--since 2024-01-01`（allTime）→ 0.31s / 0.34s
  - `graph --no-spinner` → 0.61s / 0.54s
  - 即当前一次 full tick = 4 个子进程，对同一批文件重叠扫描 4 遍，合计约 1.55s 单核 CPU；
    历史数据更大的机器上按比例放大（这正是启动期 92% 单核峰值的主要来源）。

## 2. 输出字段调查结果

### 2.1 聚合 JSON（`--json`，任意 `--group-by` 策略）

`--group-by` 可选值：`model`、`client,model`、`client,provider,model`、`workspace,model`、
`session,model`、`client,session,model`。实测各策略的 entry 字段均为：

```json
{
  "client": "claude", "mergedClients": null, "sessionId": "...", "model": "...",
  "provider": "anthropic", "input": 2648, "output": 47665,
  "cacheRead": 15250739, "cacheWrite": 192154, "reasoning": 0,
  "messageCount": 132, "cost": 10.03, "performance": { ... }
}
```

**没有** `startedAt` / `lastUsedAt` 或任何时间字段（现有 `TokscaleEntry` 模型里的两个可选字段
解码结果恒为 null）。因此：

- 一次 `--since allTimeSince` 扫描得到的 per-session-model 聚合行**无法按本地时区分切成** today/month；
- 无法从聚合行重建逐日 history（无日期维度）；
- 无法重建 session 的 startedAt/lastUsedAt（会话详情与 wire 结构依赖这两个字段）。

### 2.2 `graph`（当前 history 扫描）

有逐日 `contributions`（date、totals、tokenBreakdown、clients[].tokens、activeTimeMs）和
`timeMetrics.totalActiveTimeMs`，但**没有 per-model / per-session 明细**，不能反向构建 periods。

### 2.3 `hourly --json`

有逐小时桶（`hour: "2026-08-05 12:00"`、clients[]、models[]、input/output/cacheRead/cacheWrite/
messageCount/turnCount/cost），但：

- 无 per-session 明细（sessions 字典无法重建）；
- 无 reasoning / timedTokens / performance 字段（periods 的 timed 聚合会失真）；
- clients/models 是去重后的名称数组，不是逐 client×model 的 token 拆分。

### 2.4 `time-metrics --json` / `models --json` / `monthly --json` / `report --json`

- `time-metrics` 只有 5 个汇总数值，无逐日/逐会话；
- `models` 与主命令同构（无时间字段）；`monthly` 是月汇总；
- `report` 是任务归因（task_category/task_group/…），不是 period/session 维度，且依赖 LLM 摘要。

### 2.5 结论

现有 4.13.0 二进制的任何输出组合都无法在一次进程内同时给出：
(a) today/month/allTime 的 per-session-model 聚合行；(b) 每行的本地时区时间戳；
(c) 逐日 history。因此 3 次 period 扫描 + 1 次 graph 扫描无法在不改变统计语义的前提下合并。

## 3. 最小 API 设计（供后续落地）

给 tokscale 增加一个 `combined` 导出命令（或为 `--json` 增加新的 `--group-by day,...` 策略），
一次进程输出两份数据：

```json
{
  "groupBy": "day,client,session,model",
  "entries": [
    {
      "day": "2026-08-15",
      "client": "claude", "sessionId": "...", "model": "...", "provider": "...",
      "input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 4, "reasoning": 5,
      "messageCount": 6, "cost": 0.12, "performance": { ... },
      "startedAtMs": 1772851200000, "lastUsedAtMs": 1772854800000
    }
  ],
  "timeMetrics": { "totalActiveTimeMs": 12345 },
  "totalInput": 1, "totalOutput": 2, "totalCacheRead": 3, "totalCacheWrite": 4,
  "totalMessages": 5, "totalCost": 6, "processingTimeMs": 30
}
```

字段要求：

- `entries[].day`：本地时区日期键（沿用现有 bucketTimezone 配置）；
- `entries[].startedAtMs` / `lastUsedAtMs`：该 (session, model) 桶内消息的最小/最大时间戳（ms epoch）；
- 桶必须保持与现有 `--group-by client,session,model` 相同的会话合并、去重与 pricing 语义；
- `timeMetrics.totalActiveTimeMs` 与 `graph` 输出一致，使 Swift 侧可从同一批记录派生
  today/month/allTime（按本地午夜/月初过滤）与 daily/monthly history（按 day 分组），
  并保留 active-time override；
- `--since <date>` 覆盖 `allTimeSince` 至当前时刻（含未打时间戳的记录，语义与现有 allTime 扫描的
  includeUndated 行为对齐——需要上游确认 undated 记录在 combined 输出中的归属日）。

落地方式三选一（需另行确认）：

1. 上游/自有 fork 实现 `combined`，替换 vendored 二进制并同步构建脚本；
2. 等官方 CLI 新版本提供等价能力后升级 vendored 二进制；
3. 在 Swift 侧为 4 个 tokscale 客户端重写扫描器（不推荐：会话合并/去重/pricing 语义复刻风险高）。

## 4. 对当前统计语义的影响

本阶段**未修改**任何聚合实现：today/month/allTime/graph 仍按原 4 次扫描执行；
Phase 3（指纹缓存，数据未变化时不启动子进程）落地后，4 次重叠扫描只发生在数据真正变化的
full tick 上，稳态成本由 Phase 3/4 消化。夹具（`Tests/TokenMonitorFixtureCheck`）与
诊断 dump（`stats-NNN.json`）仍完全一致。

