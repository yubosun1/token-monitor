# Token Monitor 性能优化审查修复计划

## 1. 本轮目标

本计划只修复上一轮性能优化审查中确认的问题，不继续扩大瘦身范围，也不重写 UI。

上一轮已经完成且应保留的内容：

- 原生 Release 构建和 aggregation fixture 基线。
- `flock` 单实例所有权机制。
- 按数据源指纹复用解析结果的总体方向。
- Tokscale pricing 磁盘缓存。
- dashboard WebView 关闭释放机制。
- 隐藏窗口暂停 renderer 的桥接能力。
- 设置刷新间隔热更新。
- Tokscale 单次扫描可行性调查。

本轮必须修复：

1. `clients`、`allTimeSince`、日期/月边界没有正确失效缓存。
2. 启动 cheap tick 中未解析的 pricing 不会在 full tick 重试。
3. Tokscale 指纹未变化时没有推进 full refresh 时间，导致之后每 15 秒执行 full 检查。
4. 当前 refresh coalescing 不能合并采集期间到达的请求。
5. tray、快捷键和主窗口关闭路径没有发送隐藏状态。
6. 第二实例在首实例初始化期间发出的唤起请求可能丢失。
7. 当前新增测试没有覆盖上述 Collector 运行时状态变化。
8. `git diff --check` 因文件末尾多余空行失败。

## 2. 范围边界

- 不回退 `aef03dfe..HEAD` 中已经验证有效的功能和性能改动。
- 不修改 OpenCode Go 去重、模型图标、仪表盘比例条或 DeepSeek/OpenCode 额度展开逻辑。
- 不修改额度语义、费用公式、history wire shape、session/model/client 聚合口径。
- 不删除 vendored Tokscale 二进制。
- 不在本轮实现 Tokscale combined 命令；现有二进制缺少逐条时间字段，继续保留 3 period + 1 graph 扫描。
- 不把指纹扫描等同于 period 缓存有效。文件内容、查询上下文、定价和日历边界是不同的失效维度。
- 不用延长刷新间隔掩盖错误调度。
- 不继续批量删除代码或资源，直到本计划全部验收通过。

## 3. 核心设计要求

### 3.1 分离原始数据缓存和派生结果缓存

当前 `ClientSnapshot` 把文件指纹、原始 rows、pricing、periods 和 history 绑在一起，导致文件未变化时无法响应日期、设置和定价变化。

应拆成两层：

1. **Raw cache**：`fingerprint + rows`。仅在源文件指纹变化时重新读取文件。
2. **Derived cache**：`periods + history contributions`。其 cache key 至少包含：
   - raw fingerprint；
   - client ID；
   - `allTimeSince`；
   - 当前本地 day key；
   - 当前本地 month key；
   - 相关模型的 pricing generation/signature。

文件未变化但日期、月份、allTimeSince 或 pricing 改变时，应复用 rows 重新派生 periods/history，不能重新读取原始文件，也不能继续返回旧结果。

### 3.2 配置必须进入合并上下文

最终 merged periods/history 不能只根据 `adapterChanged || tokscaleChanged` 决定是否重建。合并上下文至少包含：

- 规范化并排序后的 enabled clients；
- `allTimeSince`；
- 当前 day/month key；
- adapter derived snapshot generations；
- Tokscale snapshot generation。

上下文变化即重新合并。禁用客户端后必须立即从 periods、history、client status 和缓存合并输入中移除，不能等待该客户端源文件变化。

### 3.3 时钟需要可测试

为 Collector 的日期判断增加可注入的 `nowProvider` 或等价轻量测试入口。生产环境默认 `Date()`，测试中可以跨越午夜、月初和 DST 边界。

不要在测试中修改系统时间，也不要只测试 `localDayStart()`；必须测试同一个 Collector/缓存实例在时间推进后的输出变化。

## 4. 实施阶段

### Phase 0：先补会失败的回归测试

在改实现前增加测试，至少覆盖：

1. 文件指纹不变，时间从 23:59 推进到次日 00:01，today 自动重新派生。
2. 文件指纹不变，时间跨月后 month 自动重新派生。
3. 文件指纹不变，`allTimeSince` 改变后 adapter allTime 从缓存 rows 重算。
4. `clients` 从 `proma,hanako` 改为 `hanako` 后，Proma 立即从 merged totals/history 中消失。
5. startup cheap tick pricing miss，随后 full tick pricing success，费用由 0/unknown 更新为正确值。
6. scheduled full check 指纹未变化后，下一个 cheap tick 不再立即升级为 full。
7. 长时间 tick 执行期间到达多个 timer/manual/settings 请求，完成后最多执行一个必要的后继刷新。
8. Tokscale period 成功但 graph 失败时，下一次按策略重试 graph，不能永久绑定到成功的 period 指纹。
9. 主窗口所有 hide 路径恰好发送一次 `window:visibility=false`，show 路径发送 `true`。
10. 首实例尚未完成 AppDelegate 初始化时收到第二实例请求，初始化完成后仍会显示窗口。

测试要求：

- 不能只往现有 fixture checker 加纯函数断言；需要能够驱动 Collector/scheduler/cache 状态变化的测试 harness。
- 文件扫描、Tokscale runner、pricing lookup 和时钟应使用 fake/stub，禁止测试启动真实网络 pricing 或读取用户实际会话目录。
- 测试应断言调用次数，例如 raw read 次数、period derive 次数、Tokscale spawn 次数和实际 tick 次数。

### Phase 1：修复设置和日历边界失效

主要文件：

- `native-app/Sources/TokenMonitor/Collector/CollectorCore.swift`
- `native-app/Sources/TokenMonitor/Collector/Adapters.swift`
- 必要的测试支持文件

实施内容：

1. 按第 3 节拆分 raw cache 与 derived cache。
2. 每个 tick 计算稳定的 `dayKey` 和 `monthKey`，同一次 tick 内统一使用同一个 `now`，避免午夜期间前后不一致。
3. day key 变化时重新派生 adapter today；month key 变化时重新派生 adapter month；无需重新读取 rows。
4. `allTimeSince` 变化时重新派生 adapter allTime。
5. enabled clients 变化时清理或忽略禁用客户端的 snapshot，并无条件重建最终 merge/history。
6. 对 Tokscale：
   - 因当前 period JSON 没有时间字段，跨日必须重新扫描 today；
   - 跨月必须重新扫描 month；
   - `allTimeSince` 变化必须重新扫描 allTime；
   - Tokscale client 集合变化必须重新扫描受影响的 periods/graph；
   - 如果 runner 目前只能一次调用三个 period，可先保持完整 3+1 扫描，正确性优先。
7. 不要简单地对 `clients`/`allTimeSince` 调用 `clientSnapshots.removeAll()`：adapter rows 能安全复用时应保留 raw cache，只失效 derived cache。

验收：

- Phase 0 的日期、allTimeSince 和 clients 回归测试通过。
- 跨边界或改设置后统计立即正确。
- adapter 源文件未变化时没有重新读取原始文件。

### Phase 2：修复 pricing 补全和失效

主要文件：

- `CollectorCore.swift`
- `TokscaleRunner.swift`
- `Adapters.swift`

实施内容：

1. Raw snapshot 必须记录相关的规范化 model IDs，以及当前未解析 pricing 的 model IDs。
2. cheap startup 可以只读内存/磁盘 pricing cache，但不能把未命中视为永久有效结果。
3. 紧随其后的 full tick 必须对 unresolved/expired model pricing 进行一次受控补全，即使文件指纹没有变化。
4. pricing 成功补全后，只从缓存 rows 重新派生对应客户端的 periods/history，不重新读取源文件。
5. 防止同一 model 在同一 refresh 中重复 lookup；多个客户端使用同一 model 时共享结果。
6. `allowSubprocessLookup` 这种全局可变开关应改为显式 lookup policy 参数或其他线程安全机制，避免未来并发调用互相影响。
7. 明确定义失败重试：本次失败保留 unresolved 状态，下一次 scheduled full 或带退避的 retry 再试；cheap tick 不应每 15 秒触发网络查询。
8. 自定义 pricing 变化时使相关 pricing generation 增加，并重新派生受影响客户端。

验收：

- 冷缓存首次 cheap stats 可快速出现。
- full tick 完成后缺失模型费用自动更新，不需要修改源文件。
- pricing 失败不会清空已有费用或产生高频重试。
- pricing 命中磁盘缓存时不启动子进程。

### Phase 3：修复 full cadence 和失败状态

主要文件：`CollectorCore.swift`、`TokscaleRunner.swift`。

实施内容：

1. 区分以下时间：
   - `lastFullCheckAt`：最近一次按计划完成源指纹检查的时间；
   - `lastSuccessfulPeriodScanAt`；
   - `lastSuccessfulGraphScanAt`。
2. scheduled full 到期后，即使 Tokscale 指纹未变化并复用快照，也要推进 `lastFullCheckAt`，下一次 full 检查应等待完整 `collectionIntervalMs`。
3. 手动刷新可以立即执行一次 full source check，但文件未变化时仍不强制 3+1 扫描。
4. `TOKEN_MONITOR_FORCE_RESCAN` 才允许绕过指纹。
5. period 和 graph 的成功状态分开记录：
   - period 成功、graph 失败时保留新的 periods 和旧 history；
   - 不得把 graph 标记为已成功；
   - graph 按有限退避重试，不能因 period 指纹已记录而永久跳过；
   - graph retry 不应重新跑已经成功且输入未变化的三个 period。
6. 连续失败使用有上限的退避，避免每个 cheap tick 重启失败子进程。

验收：

- 指纹不变时，每个 `collectionIntervalMs` 最多进行一次 Tokscale source check，且 0 个 Tokscale 子进程。
- 5 分钟 full check 后不会退化为每 15 秒 full check。
- 部分失败能够恢复，UI 始终保留各部分最后一次成功快照。

### Phase 4：真正实现 refresh coalescing

当前问题：`enqueue()` 与同步耗时的 `tick()` 在同一个串行队列。tick 运行时，新请求只能排在队列后面，无法更新 `pendingRefresh`，所以不能真正合并。

推荐结构：

1. 使用一个短时持有的 coordination lock（或独立 actor/state queue）管理：
   - `workerRunning`；
   - 当前 refresh kind/context generation；
   - 最多一个 pending refresh。
2. 真正耗时的 tick 在 worker queue 上运行，不持有 coordination lock。
3. `requestRefresh()` 从 main/timer/settings 任意线程进入时，立即在 coordination state 中合并请求，不等待正在运行的 tick。
4. worker 完成后原子取走一个 pending request；没有 pending 才退出 worker。
5. 合并规则：
   - pending `full` 覆盖 `cheap`；
   - 多个相同请求只保留一次；
   - 正在运行的 full 通常覆盖期间到达的 timer cheap；
   - 如果请求携带更新后的 settings generation，必须保留一个后继刷新；
   - manual full 默认强制 source check，但不等于 force rescan；
   - diagnostic `fullForced` 强度最高。
6. Collector 的缓存数据仍只由 worker 单写；coordination lock 不用于保护整个 tick。
7. 避免递归 pump 或在锁内执行 tick/push。

验收：

- fake tick 阻塞期间注入 10 个 cheap、3 个 manual full 和 1 个 settings change，当前 tick 结束后最多再执行一个满足最新 generation 的 full。
- 没有丢失 settings change。
- 没有并发执行两个 Collector tick。
- 没有死锁，主线程不会等待扫描完成。

### Phase 5：统一窗口可见性路径

主要文件：

- `native-app/Sources/TokenMonitor/AppDelegate.swift`
- `native-app/Sources/TokenMonitor/DashboardWindowController.swift`
- `native-app/Sources/TokenMonitor/Bridge.swift`
- renderer visibility listener

实施内容：

1. 在 `GlassWindowController` 提供统一的 `showManagedWindow()` / `hideManagedWindow()`（名称可按项目风格调整）。
2. 所有隐藏入口必须经过统一方法：
   - tray 左键；
   - 全局快捷键；
   - renderer 主窗口关闭按钮；
   - 自动失焦隐藏；
   - 如果 miniaturize 也应暂停，则监听 miniaturize/deminiaturize。
3. hide 方法执行 `orderOut`、发送 `window:visibility=false` 并调用 `windowDidHide()`；重复 hide 不重复发事件或重复安排 teardown。
4. show 方法显示窗口、取消 idle teardown，并发送 `true`。
5. 页面尚未加载完成时 visibility push 可能丢失；在 `didFinish` 后同步一次当前原生可见状态，或让 renderer 主动查询初始状态。
6. dashboard explicit close 仍立即 detach/tearDown；main widget 仍保持 hide-only，不扩大内存策略。

验收：

- 每条 hide/show 路径的事件顺序和次数有自动测试或 bridge spy 验证。
- 主窗口通过 tray/快捷键隐藏后，renderer ticker 停止。
- dashboard 隐藏 60 秒后只 teardown 一次，重新打开无重复 listener。

### Phase 6：关闭单实例唤起竞态

主要文件：

- `SingleInstanceCoordinator.swift`
- `AppMain.swift`
- `AppDelegate.swift`

推荐方案：

1. Coordinator 在竞争 `flock` **之前**注册跨进程唤起通知接收器。
2. 通知到达时如果 AppDelegate/show callback 尚未就绪，记录 `pendingActivation = true`。
3. AppDelegate 初始化后向 Coordinator 安装 show callback，并立即消费 pending activation。
4. 第二实例失去锁后发送通知，随后清理自己的 observer 并退出，不创建 AppKit UI、collector 或 WebView。
5. 可使用锁文件中的 owner PID，通过 `NSRunningApplication(processIdentifier:)` activate 作为额外 fallback，但 PID 不是锁所有权依据。
6. 若继续使用单向 distributed notification，应增加有界重试或确认机制，验证快速并发启动不会丢请求；不要用无限 sleep。
7. 正常退出和异常退出仍依赖 kernel 释放 `flock`，保留当前优点。

验收：

- 在首实例取得锁但 AppDelegate 尚未完成初始化的测试窗口内启动第二实例，首实例最终显示窗口。
- 快速并发启动 20 次仍只有一个 collector/app 实例。
- 第二实例不创建状态栏、WebView 或 Tokscale 子进程。
- `kill -9` 后能够重新启动。

### Phase 7：验证、文档校正和格式清理

1. 清除本轮新增文件末尾的多余空行，使 `git diff --check` 返回 0。
2. 更新 `native-app/docs/perf-delivery-record.md`，不得继续声称尚未通过测试证明的 coalescing/cadence 行为。
3. 重新测量：
   - launch → first stats；
   - launch → pricing-complete stats；
   - 启动 Tokscale 子进程数；
   - 5 分钟边界后的 full check 次数；
   - 无变化 10 分钟内的 CPU；
   - dashboard 20 次生命周期；
   - 快速重复启动行为。
4. Release 构建和 staged resources 检查必须使用最终工作区重新执行，不能引用旧提交的结果。

## 5. 最终验收标准

- 修改 `allTimeSince` 后，无需修改数据文件即可得到新的 allTime 统计。
- 禁用任一客户端后，该客户端立即从 totals/history 中消失。
- 应用跨午夜和月初持续运行时，today/month 自动切换且统计正确。
- startup cheap tick 未命中的定价会在 full tick 补全，费用不永久保持 0。
- 数据未变化时，scheduled full check 不启动 Tokscale；之后等待完整 `collectionIntervalMs` 才再次检查。
- period 或 graph 单独失败后可以单独恢复，不清空最后成功数据。
- 扫描运行期间的重复请求被合并，最多保留一个必要的后继刷新。
- 所有主窗口隐藏路径都会暂停 renderer；重新显示只执行一次 catch-up render。
- 首实例初始化期间的第二次启动请求不会丢失。
- fixture、Collector 状态测试、scheduler 并发测试、JS syntax、资源引用检查、Release build 和 `git diff --check` 全部通过。
- OpenCode Go 去重、全部模型图标、比例条对齐以及 DeepSeek/OpenCode 展开功能保持正常。

## 6. 推荐提交顺序

1. `test(collector): cover cache invalidation and refresh scheduling`
2. `fix(collector): invalidate derived snapshots by context`
3. `fix(collector): retry unresolved model pricing`
4. `fix(collector): preserve full refresh cadence and partial retries`
5. `fix(collector): coalesce refreshes outside the worker queue`
6. `fix(native): unify managed window visibility events`
7. `fix(native): buffer early single-instance activation requests`
8. `docs(perf): update measurements and pass final checks`

不要将缓存模型、调度器、窗口生命周期和单实例修复压进同一个提交。

## 7. 交付要求

DeepSeek 完成后应提供：

- 每个 Phase 对应的提交 ID。
- 新增测试名称及其验证的具体回归。
- 缓存 key、generation 和失败退避规则说明。
- refresh coalescing 的状态转换说明，以及压力测试的实际 tick 次数。
- 修复前后 5 分钟边界和 10 分钟空闲测量数据。
- 所有最终验证命令及退出码。

不得只报告“fixture 通过”作为 Collector 缓存和调度正确性的证明。
