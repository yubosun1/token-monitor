# 第四轮审查修复与内存优化交付记录（PLAN.md round-4）

测量环境：macOS 15.7.8（Apple Silicon），Swift 6.2.4 CLT，Release 构建；
数据规模：dsh 11 个会话（其中 1 个为本次工作会话，运行期间持续追加），
claude 191 / codex 681 / opencode 0 消息。审查基线提交 `001717f5`。

## 1. 阶段与提交

| Phase | 内容 | 提交 |
| --- | --- | --- |
| 0 测试 | T10/T10b/T11/T13 + 测试 seam（内部缓存可见性、观察锁、statsPushes） | 404cafc4 |
| 1 修复 | Tokscale 部分失败 validity 状态机（PLAN §5） | d6b76b7a |
| 2 修复 | coordLock/stateLock 隔离 + 空 clients 合法空推送与缓存清理（PLAN §6） | 8619684b |
| 3 测试 | T12（pricing TTL）、T14（sidecar 同步） | 7043db32 |
| 3 修复 | Collector pricing 6h TTL + sidecar 签名门控与同内容免写（PLAN §7） | 5aa056ea |
| 4 修复 | runningKind 覆盖规则：运行中 full 丢弃 timer cheap（PLAN §8） | c6f2f05f |
| 5 测试 | T15（DSH 解析缓存生命周期）+ CZstd 直链 + 生命周期 seam | 012a00d0 |
| 5 修复 | 删除 decompressCache，解压 Data 仅解析期临时（PLAN §9） | c2795e1e |
| 6 修复 | 主页 WebView 长时间隐藏 teardown + V5-V8（PLAN §10，实测后保留） | e31e2bf3 |
| 7 文档 | 本记录 + 测量脚本（mem-probe / dsh-redecompress-probe） | 本提交 |

## 2. 新增测试与初始失败

| 测试 | 覆盖 | 初始失败（修复前基线） | 修复后 |
| --- | --- | --- | --- |
| T10 | 跨日 context 后 period 失败：新 context validity 必须为 false | 3 项（validity 沿用 true、backoff 后不重试、totals 未更新） | 绿 |
| T10b | 指纹改变后 graph 失败的对称场景 | 2 项（graph validity 沿用 true、不重试） | 绿 |
| T11 | 部分/全部禁用 clients：空 wire shape、缓存清理、恢复 | 13 项（旧 UI 残留、缓存保留、无空推送） | 绿 |
| T13/T13b | 运行中 full 覆盖 timer cheap；强请求保留一个后继 | T13 1 项（cheap 后继多余执行） | 绿 |
| T12 | pricing TTL 生命周期（TTL 内不复解析、过期重解析、失败保价、重试下限、跨客户端共享单次 lookup） | 7 项（过期永不重解析、失败清价） | 绿 |
| T14 | sidecar 只按需同步 + 设置变更经真实通知路径失效 pricing generation | 3 项（每 tick 同步） | 绿 |
| T15 | 解析缓存：二次解析不解压、Data 不长期保留、stamp 替换、删除/禁用清理 | 1 项（retention 400B ≠ 0） | 绿 |
| V5-V8 | idle teardown 调度：重复 hide 幂等、show 取消、单次触发、20 循环无累积 | 新增即绿 | — |

总检查数：120 → **215 checks，0 failures**。T12 曾因 fake clock 跨天导致
today 窗口合法归零而误报，修正为 allTime 窗口断言（测试自身问题，非实现缺陷）。

## 3. Tokscale snapshot validity 状态转换

- TokscaleSnapshot 的 values（periods/graphDays/graphActiveTime）与 validity
  （periodsSuccess/graphSuccess）分离；context = fingerprint+clients+allTimeSince+
  dayKey+monthKey+pricingGeneration。
- `forced || contextChanged` 时构建**属于新 context 的新快照**：values 从
  last-known-good 旧快照继承（UI 降级显示），但两个 validity 标志一律重置为
  false，随后逐部分翻转：扫描成功 → 存值 + 置 true + 清零该部分失败计数；
  失败 → 保持旧值 + 置 false + 仅推进该部分的指数退避（30s·2^n 封顶 600s）。
- 复用分支只对 validity==false 且越过退避线的部分重试；成功部分绝不重复执行。
- `lastFullCheckAt` 只表示 source check 完成，不等于任何部分的成功时间。
- 无 tokscale 客户端时（full 与 cheap 路径一致）快照置 nil，禁用后不会从旧
  快照复活数据。

## 4. 协调状态与请求覆盖规则

```
coordLock 保护的协调状态：
  workerRunning / runningKind（运行中 tick 的 kind，取件与闲置时原子更新）
  pendingQueue（最多一个必要后继，强覆盖弱）
  pendingInvalidations / hasCompletedInitialStats（cheap-first 启动门，
  requestRefresh 不再跨锁读 statsCache —— 修复了 coordLock/stateLock 数据竞争）

requestRefresh(kind, reason) 规则：
  ├─ 运行中 kind ∈ {full, fullForced} 且来的 kind == cheap
  │    → 覆盖于运行中的 source check，直接丢弃（purge 失效尚未被消费且无
  │      后继时保留一个 cheap 兜底）；
  ├─ 队首为 startup cheap 且尚未发布过 stats → 排在它后面（cheap-first 启动）；
  ├─ 队列已有 ≥ 强度 → 丢弃；
  └─ 否则替换队中最弱请求。
settings-generation full / manual full / fullForced 永不被丢弃；
tick、push、I/O 一律不在 coordLock 内执行。
```

## 5. pricing TTL、失败退避与 custom pricing signature

- cachedPricing 记录 (pricing, fetchedAt)，TTL 6h 使用可注入的 collector now；
  cheap tick 只读缓存永不 spawn；full tick 仅对 unresolved 或过期模型调用
  `.resolve`，且受每模型 300s 重试下限约束；同一 tick 同一模型最多 lookup 一次
  （多客户端共享）。
- 过期解析失败保留 last-known-good 价格（费用绝不清零）并设置 300s 下限；
  成功后 pricing signature 变化 → 受影响 derived 从缓存 rows 重算，raw 不重读。
- custom pricing sidecar：Collector 以 sortedKeys 规范化签名比对，仅首 tick 与
  设置实际变化时调用 sync（写入失败也记录签名，cheap tick 不无限重试）；
  CustomPricingSidecar 按 modelId 排序并逐字节比对目标文件，内容一致免写。

## 6. 删除 decompressCache 前后的 heap/footprint 对比

真实用户数据、Release 构建、相同启动等待（75s）、同一场景（脚本
native-app/scripts/mem-probe.sh，运行目录 native-app/.perf/mem-before 与
mem-after）：

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| 主进程 physical footprint | 144.5 MB | **80 MB** |
| 主进程 footprint peak | 298.2 MB | 262 MB |
| heap `__DataStorage._bytes` | 11 块共 80.4 MB（最大单块 18.4 MB） | **0** |
| All zones malloced 总量 | 101.9 MB | 21.6 MB（Δ≈80.3 MB，即重复缓存） |
| UsageRow 数组存储 | 2.23 MB（71 数组） | 2.36 MB（71 数组，数据增长所致） |
| `leaks` | — | 0 leaks / 0 bytes |

不重复解压（native-app/.perf/dsh-probe2，refreshMs=5s、collectionIntervalMs=15s、
135s、16 次全量重读）：10 个 stamp 未变的会话文件全程各解压 1 次；唯一被重复
解压的文件是运行中持续追加的工作会话（stamp 每次 tick 合法变化，16 次）。
连续 14 个 tick 的 post-tick footprint 71.2–71.5 MB 平稳，内存不随 refresh 次数
增长。

DSH totals/history 语义一致性：T15 在合成 zstd fixture 上断言解析输出（events/
rows/input/output）；fixture goldens 未变且全绿；`git diff 012a00d0 c2795e1e
-- Adapters.swift` 证明解析函数体零改动，仅缓存管道变化；真实数据 before/after
dump 的 dsh 差异与 UsageRow 存储增长（2.23→2.36MB）一致，即两次测量窗口内的
真实使用增量，无属性于本次修改的跳变。

## 7. 主页 WebView 长时间隐藏 teardown（已实施）

决策：**保留**。实测收益明确、重建延迟可接受。

- 机制：隐藏（tray/快捷键/关闭/失焦/miniaturize）启动统一的 600s idle
  teardown 时钟（集中常量 WindowLifecycleConstants）；延迟内 show 复用原
  controller（取消待执行 teardown）；超时后 teardown 一次（detach Bridge、移除
  script handler/observer/navigation、停载、释放 WebView/window/controller）并
  清空 AppDelegate 引用；下次 tray/快捷键/设置请求重建。
- 重建恢复：bounds 从 settings 恢复；页面启动自行经 invoke 拉取最新
  stats/settings/history/limits（stats:get 等），不依赖丢失的旧 push；重建期间
  发出的本地 push（如 settings:open）排队并在 didFinish 冲刷。
- 调度规则在 IdleTeardownScheduler（可注入 executor），V5-V8 覆盖：重复 hide
  幂等、delay 内 show 取消、超时恰好触发一次、20 次 hide/show 循环零累积。
- 实测（native-app/.perf/main-lifecycle，4 轮 hide→teardown→rebuild）：每轮
  controller 被正确清空重建，主进程 footprint 82.0–82.4 MB 平坦无累积（peak
  212 MB）；重建延迟 show→page complete 约 **0.22s**。
- WebKit 子进程物理内存（/usr/bin/footprint 逐进程，webkit-fp2）：alive
  WebContent 46 MB / GPU 15 MB / Networking 8.4 MB；teardown 后 WebContent
  进程消失；重建后新 WebContent 59 MB。GPU/Networking 交还系统管理，不强制
  kill 系统进程。
- dashboard 的 60s teardown 行为保持不变（6 轮 lifecycle 探针通过）。

## 8. 运行时验证（PLAN §11）

| 项 | 证据 |
| --- | --- |
| 跨日期 context 失败按 backoff 恢复 | T10/T10b（fake clock 确定性覆盖；运行时代码路径一致） |
| 禁用全部 clients 主页立即为空、再启用恢复 | diag 探针：clients 清空 6ms 后推送空 stats（totalTokens 0、clients []、tracked []、historyDays 0），恢复后 822M tokens/38 天历史恢复 |
| pricing TTL 到期不清零已有费用 | T12（fake clock） |
| 空闲 10 分钟无周期性 custom pricing 写入 | sidecar-idle 探针：两个目标文件 mtime 600s 前后完全一致 |
| DSH 不变不重复解压、内存不随 refresh 增长 | 见 §6 |
| 主页/dashboard 关闭、隐藏、重开 | main lifecycle 4 轮 + dashboard lifecycle 6 轮 |
| OpenCode 单条、模型图标、比例条、额度展开 | diag interaction 探针：clientRows 每客户端一条；deepseek/opencode expanded=true hidden=false；dashboard bars 探针正常 |

## 9. 最终验证命令与退出码

| 命令 | 结果 |
| --- | --- |
| native-app/scripts/check-fixtures.sh | exit 0，**215 checks, 0 failures** |
| swift build -c release --product TokenMonitor --package-path native-app --disable-sandbox | exit 0 |
| node --check app.js / dashboard.js / tokenMonitorBridge.js | exit 0 |
| git diff --check 001717f5..HEAD | exit 0 |
| swift build --sanitize=thread + 运行 fixture checker | 215 checks 0 failures，**0 warnings**（先前 3 条告警为测试侧 tickKinds 中途读取，已用观察锁消除） |

## 10. 内存报告汇总（PLAN §11 要求）

- 主进程 physical footprint 与 peak：80 MB / 262 MB（修复前 144.5 / 298.2 MB）。
- WebContent/GPU/Networking physical footprint：alive 46/15/8.4 MB；teardown 后
  WebContent 进程退出；重建后 WebContent 59 MB。
- heap `__DataStorage` 总量与最大块：80.4 MB / 18.4 MB → 0 / 0。
- `UsageRow` array storage：2.36 MB（71 数组；修复前 2.23 MB，随数据增长）。
- `leaks`：0 leaks，0 total leaked bytes。
- 测量时间点：mem-before（21:47–21:49，修复前构建）与 mem-after（21:51–21:53，
  修复后构建），同一场景同一等待时间，运行目录见 §6。
