# Token Monitor 第四轮审查修复与内存优化计划

## 1. 执行基线

- 分支：`macos-native`
- 审查基线提交：`001717f5`
- 当前 fixture：120 checks，0 failures
- 当前 Release 构建、JavaScript syntax check、`git diff --check` 均通过
- 本轮基于现有原生 macOS + WKWebView 架构修复，不重写 UI，不恢复 Electron

开始修改前先确认工作树，并保留用户已有改动：

```bash
git status --short
git log --oneline -8
```

## 2. 本轮目标与顺序

1. 修复 Tokscale 跨日期/上下文后部分扫描失败时错误复用成功状态的问题。
2. 消除 Collector 对 `statsCache` 的跨锁数据竞争。
3. 正确处理 enabled clients 为空，并清理禁用客户端的缓存。
4. 让模型 pricing 在应用长期运行时遵守 6 小时 TTL。
5. 修正运行中 full refresh 对后续 timer cheap refresh 的覆盖规则。
6. 停止每个 tick 重写 custom pricing sidecar。
7. 删除重复保留完整 DSH 解压数据的缓存，降低主进程内存。
8. 前述优化测量通过后，为主页 WebView 增加长时间隐藏后的可选 teardown。

正确性优先于性能数字。每个阶段先增加会失败的回归测试，再修改实现。

## 3. 范围边界

- 不改变费用公式、period/history wire shape、模型/工具聚合口径。
- 不回退 raw/derived cache、cheap-first startup、窗口 visibility、dashboard teardown 和单实例唤起修复。
- 不修改 OpenCode Go 去重、模型图标、仪表盘比例条、DeepSeek/OpenCode 额度展开等已完成功能。
- 不通过延长刷新间隔或关闭数据源掩盖 CPU/内存问题。
- 不删除 vendored Tokscale、libzstd 或 DSH 支持，不引入新依赖。
- 不在未测量前大范围重写 Collector 或 renderer。
- 不把 Activity Monitor 的 RSS 直接当作独占内存；验收使用 physical footprint，并单独记录 WebKit 子进程。

## 4. Phase 0：先补回归测试

主要文件：`native-app/Tests/TokenMonitorFixtureCheck/main.swift`。允许增加轻量测试 seam，但测试不得访问用户真实会话或网络。

### T10：旧成功快照跨上下文后部分失败

1. 在 2026-08-15 完成一次 period + graph 成功扫描。
2. fake clock 推进到 2026-08-16，fingerprint 不变，让新 period 失败、graph 成功。
3. 旧 period 可以作为 last-known-good 降级显示，但对新 context 的 `periodsSuccess` 必须为 false。
4. 推进到 backoff 后再次 full，断言只重试 period 并恢复，成功 graph 不重复执行。
5. 增加对称场景：旧成功快照存在，clients/fingerprint 改变后 graph 失败，graph 必须重试，period 不重复执行。

### T11：全部客户端被禁用

1. 先生成非空 stats/history，再把 `clients` 改为空字符串并触发 settings full。
2. 断言推送一次 wire shape 合法的空 stats/history。
3. 断言旧 client 不再出现在 totals、history、clientStatus。
4. 断言对应 raw/derived snapshot 被清理或不再保留。
5. 再启用客户端后可以正常恢复。

### T12：pricing TTL

1. 第一次 full 成功解析 pricing；TTL 内再次 full 不新增 resolve lookup。
2. fake clock 推进超过 6 小时，runner 返回更新价格。
3. 断言恰好执行一次 resolve，并从 cached rows 重派生费用，raw source 不重读。
4. 过期 lookup 失败时保留上一次成功价格并有限退避，不能把费用清零。

### T13：运行中的 full 覆盖 timer cheap

1. 阻塞一个正在执行的 full，期间只注入多个 `.cheap/.timer`。
2. full 完成后断言没有多余后继 tick。
3. settings generation 更新、manual full 或 fullForced 到达时，仍保留最多一个必要后继 full。

### T14：custom pricing sidecar 调用次数

1. 多个普通 cheap/full 使用同一份 `customModelPricing`，sync 不重复执行。
2. 设置实际改变后恰好 sync 一次，并使 pricing generation 失效。

### T15：DSH 解压生命周期

1. 临时 zstd fixture 连续解析两次，第二次命中解析结果缓存，不再次解压。
2. 实现中不再长期持有完整解压 `Data`。
3. 文件 stamp 变化时只替换该文件解析结果。
4. 文件删除或 DSH 被禁用后，对应 parse cache 被清理。

所有测试必须驱动同一个 Collector/缓存实例发生状态变化，并断言 period/graph spawn、raw read、pricing lookup、tick、sidecar sync 的调用次数。TTL/backoff 使用 fake clock，不使用真实 sleep。

## 5. Phase 1：修复 Tokscale 部分失败状态机

主要文件：`native-app/Sources/TokenMonitor/Collector/CollectorCore.swift`

当前 `forced || contextChanged` 分支从旧 `TokscaleSnapshot` 开始修改。新扫描失败时，旧 `periodsSuccess/graphSuccess` 可能仍为 true，随后 fingerprint、clients、day/month 又被覆盖为新 context，失败部分因此永久不重试。

实施要求：

1. context 变化时创建属于新 context 的 validity 状态，不沿用旧 context 的成功标志。
2. 可以保留旧 periods/graph 值作为 last-known-good UI 降级数据，但失败部分必须标为待重试。
3. period 和 graph validity 独立；成功部分更新值并清除失败计数，失败部分设为 false 并更新自己的 backoff。
4. snapshot context 与 validity 一起提交，不能把旧结果标为新 context 成功。
5. `forced` 可尝试两部分，但失败后同样保留正确失败状态。
6. `lastFullCheckAt` 表示 source check 完成，不等于 period/graph 成功时间。

验收：T10 和原 T8 同时通过。

## 6. Phase 2：修复并发状态与空客户端

### 6.1 消除 `statsCache` 数据竞争

`statsCache` 的公开读取/写入由 `stateLock` 保护，但 `requestRefresh()` 在 `coordLock` 下读取它判断 cheap-first startup。

1. 在 coordination state 中增加独立状态，例如 `hasCompletedInitialStats`。
2. 该状态只在 `coordLock` 下读写；coordination 代码不得直接读 `statsCache`。
3. `statsCache/cachedHistory` 的跨线程读写统一使用 `stateLock`。
4. worker-owned cache 保持单 writer，不给整个 tick 加大锁。
5. 尽可能使用 Thread Sanitizer 验证；环境不能运行时必须说明。

### 6.2 enabled clients 为空

1. 不得直接 return 并留下旧 UI。
2. 构造与正常协议相同的空 periods、history、stats 和 clientStatus。
3. 更新 state cache 并 push 一次空结果。
4. 清理 raw/derived/merged/Tokscale 中不再需要的数据。
5. 仅禁用部分 clients 时也移除禁用 client 的缓存，不能永久保存不可达 rows。

验收：T11 和原有禁用单客户端测试通过。

## 7. Phase 3：pricing TTL 与 sidecar I/O

主要文件：`CollectorCore.swift`、`TokscaleRunner.swift`，必要时小范围修改 `SettingsStore.swift`。

### 7.1 Collector pricing TTL

`TokscaleRunner` 有 6 小时 TTL，但 Collector 的 `cachedPricing[model] != nil` 永久跳过 runner。

1. Collector pricing cache 记录 `pricing + fetchedAt` 或每个 model 的下一次校验时间。
2. cheap 只使用有效/last-known-good pricing，不启动子进程。
3. full 只对 unresolved 或 expired model 调用 `.resolve`。
4. TTL 使用可注入的 Collector `now`。
5. resolve 成功后更新 pricing signature，使受影响 derived snapshot 从 cached rows 重算。
6. expired resolve 失败时保留 last-known-good pricing并有限退避，不将费用清零。
7. 同一 tick、同一 model 最多 lookup 一次，多客户端共享。
8. custom pricing 改变仍立即失效相关缓存。

### 7.2 custom pricing sidecar

1. 只在启动和 `customModelPricing` 实际变化时 sync。
2. 使用规范化、排序后的稳定 signature，字典遍历顺序不得造成假变化。
3. 内容与目标文件一致时不写文件，避免无意义 mtime 和 SSD I/O。
4. 写入失败保留日志，但不能在每个 cheap tick 无限重试。

验收：T12、T14 通过；空闲 10 分钟 sidecar mtime 不变化。

## 8. Phase 4：完善 refresh coalescing

当前 coordination state 不知道正在执行的 refresh kind，full 运行期间到达的 timer cheap 会被排到后面。

1. coordination state 增加 `runningKind` 和必要的 running settings/context generation。
2. 正在运行的 full/fullForced 覆盖普通 timer cheap，直接丢弃。
3. 不得丢弃更新的 settings generation、manual full、fullForced 或尚未处理的 invalidation。
4. pending 最多保留一个必要后继请求，强请求覆盖弱请求。
5. 保留 cheap-first startup：startup cheap 后仍执行 startup full。
6. running 状态在 tick 完成和取下一项时原子更新，early return 也恢复 idle。
7. 不在 `coordLock` 内执行 tick、push 或 I/O。

验收：T13、原 T7、原 T9 全部通过。

## 9. Phase 5：移除 DSH 重复大内存缓存

主要文件：`native-app/Sources/TokenMonitor/Collector/Adapters.swift`

审查实测：主进程 footprint 约 129 MB；heap 中七块大型 `__DataStorage` 合计约 71 MB，与当前 DSH zstd 解压尺寸高度吻合。`parseCache` 已保存每个文件的 `DshFileResult`，继续保存完整解压 JSONL 属于重复缓存。

1. 删除 `decompressCache`；`decompressZstd()` 只返回本次解析的临时 `Data`。
2. 保留按 `(path, mtime, size)` 缓存解析后 `DshFileResult`，避免重复解压/parse。
3. 解压 `Data` 和中间 `String` 在 `parseDshFile()` 完成后可释放，不被 closure、Substring 或 JSON 对象长期引用。
4. parse/file-list cache 必须有界清理：删除不存在文件、禁用 client 的条目；stamp 改变时替换而非保留历史版本。
5. 不用另一个大容量 LRU 继续缓存完整解压文件。
6. 注意 Array copy-on-write，不为“优化”复制所有 UsageRow。
7. 不改变 DSH 去重、model attribution、时间和 token 解析语义。

测量要求：

1. 使用同一用户数据、Release app、相同启动后等待时间。
2. 完成一次 DSH collection 后测主进程 physical footprint。
3. 用 `heap <pid>` 确认不再有对应 DSH 尺寸的长期大型 `__DataStorage`。
4. 连续三次无变化 full，确认不重复解压。
5. 对比修复前约 129 MB；预计下降数十 MB，但只报告实测。

验收：T15 通过，DSH totals/history 与修改前完全一致。

## 10. Phase 6：主页 WebView 长时间隐藏回收

仅在 Phase 1–5 全部通过并复测后执行。

基线：WebContent 约 63 MB、GPU 约 19 MB、Networking 约 8 MB；`leaks` 为 0。主页 `DashboardWindowController` 永久持有的 `WKWebView` 是隐藏状态下最大的固定成本。

1. 短时间隐藏保留 WebView，保证托盘快速切换。
2. 连续隐藏 5–10 分钟后 teardown；建议默认 600 秒并集中定义。
3. teardown detach Bridge，移除 script handler/observer/navigation delegate，停止加载并释放 WebView/window/controller。
4. AppDelegate 清空 `mainWindowController`；下次 tray/hotkey/settings 请求重新创建。
5. 重建后恢复 bounds、tab/settings 状态，并主动获取最新 stats/history/limits，不依赖丢失的旧 push。
6. show 取消待执行 teardown；重复 hide/show 不创建多个 work item。
7. dashboard 已有 teardown 行为保持不变。
8. WebKit XPC 未立即退出时记录 30/60 秒 footprint，不强杀系统进程。

生命周期测试：

- delay 内 show：复用原 controller，不 teardown。
- hide 超时：只 teardown 一次并清空 AppDelegate 引用。
- 超时后 show：只创建一个新 WebView，数据和 visibility 恢复。
- 连续 20 次 hide/timeout/show：controller、Bridge pusher、observer 不累积。

如果重建延迟明显不可接受，可将本 phase 保留为可配置实验；Phase 5 仍必须交付。

## 11. 最终验证

```bash
native-app/scripts/check-fixtures.sh
TMPDIR="$PWD/native-app/.tmp" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/native-app/.cache" \
  swift build -c release --product TokenMonitor --package-path native-app --disable-sandbox
node --check src/electron/renderer/app.js
node --check src/electron/renderer/dashboard.js
node --check native-app/Resources/tokenMonitorBridge.js
git diff --check 001717f5..HEAD
```

还必须人工/运行时验证：

1. 跨日期 context failure 可以按 backoff 恢复。
2. 禁用全部 clients 后主页立即为空，再启用后恢复。
3. pricing TTL 到期不会把已有费用清零。
4. 空闲 10 分钟没有周期性 custom pricing 写入。
5. DSH 不变时不重复解压，内存不随 refresh 次数增长。
6. 主页/dashboard 的关闭、隐藏、重开正常。
7. OpenCode Go 只显示一份，模型图标正常，dashboard 比例条对齐，DeepSeek/OpenCode 额度仍可展开。

内存报告分别列出：

- 主进程 physical footprint 与 peak；
- WebContent/GPU/Networking physical footprint；
- heap 中 `__DataStorage` 总量和最大块；
- `UsageRow` array storage；
- `leaks` 结果；
- 修复前后相同场景的测量时间点。

## 12. 推荐提交顺序

1. `test(collector): cover context failures and empty clients`
2. `fix(collector): preserve partial retry validity across contexts`
3. `fix(collector): isolate coordination state and clear disabled clients`
4. `test(pricing): cover ttl and sidecar synchronization`
5. `fix(pricing): honor ttl and gate sidecar writes`
6. `fix(collector): suppress covered timer refreshes`
7. `test(dsh): cover parsed cache lifecycle`
8. `perf(dsh): release decompressed session buffers`
9. `perf(native): tear down long-hidden main webview`（独立提交，可按实测决定是否保留）
10. `docs(perf): record final checks and memory measurements`

不要把状态机、pricing、DSH 内存和 WebView 生命周期压进同一个提交。

## 13. 交付要求

DeepSeek 完成后必须提供：

- 每个 phase 对应的 commit ID。
- 新增测试名称、初始失败原因和修复后结果。
- Tokscale snapshot validity/state transition 说明。
- Collector coordination state 与请求覆盖规则说明。
- pricing TTL、失败退避和 custom pricing signature 说明。
- 删除 `decompressCache` 前后的 heap/footprint 对比。
- 是否实施主页 WebView teardown，以及重建延迟和内存收益。
- 最终验证命令、退出码和完整测试数量。

不得只报告“fixture 通过”或 Activity Monitor RSS 下降。正确性、调用次数、physical footprint 和 heap 对象证据必须同时提供。
