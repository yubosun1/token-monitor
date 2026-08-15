# Token Monitor 原生版性能优化执行计划

## 1. 背景与已确认结论

当前应用并不是“所有界面和逻辑均为原生实现”：窗口、菜单栏和快捷键由 AppKit 管理，但主界面与仪表盘仍运行在 `WKWebView` 中。现阶段性能问题的首要来源不是 WebKit 空闲渲染，而是后台采集；内存占用的主要来源则是被长期持有的窗口和 WebView。

已经通过运行时观察确认：

- 启动采集期间，Token Monitor 的 CPU 峰值可接近一个核心（约 92%）。
- 采集完成后，应用 CPU 可回落到 0% 左右；主线程采样显示其大部分时间处于空闲状态。
- `Collector.start()` 会在启动后立即执行一次完整采集，并按默认 5 分钟周期重复。
- 一次完整采集会对重叠的数据文件启动 4 次 Tokscale：today、month、allTime 和 graph/history。
- Proma、Hanako、DSH 本地适配器默认每 15 秒重新遍历和聚合数据。
- 应用缺少可靠的单实例保护；重复启动会产生多套采集器和定时器。
- 主窗口和仪表盘控制器被 `AppDelegate` 强引用；`orderOut` 只隐藏窗口，不会释放 `WKWebView`。
- 空闲时 WebKit Content/GPU 进程未表现出持续 CPU 消耗，但每个保留的 WebView 都会增加明显的内存开销。

因此，本轮顺序必须是：**先减少重复进程和磁盘扫描，再做调度与增量采集，最后处理 WebView 生命周期和渲染开销。** 不应先进行 SwiftUI/AppKit 全量重写。

## 2. 目标与范围边界

### 目标

1. 消除重复实例带来的成倍后台采集。
2. 将一次完整刷新中的 Tokscale 重叠扫描合并为一次。
3. 数据源未变化时不重复解析、聚合和推送 UI。
4. 让当前用量尽快可见，将昂贵的历史计算移出首屏关键路径。
5. 隐藏或关闭长期不用的仪表盘后能够回收 WebView 内存。
6. 在不改变统计口径和现有功能的前提下继续删除确认无用的代码与资源。

### 本轮禁止事项

- 不回退或覆盖当前工作区中尚未提交的功能修复和瘦身改动。
- 不删除 `native-app/Vendor/tokscale/tokscale`；原生采集器仍在使用它。
- 不改动 OpenCode Go 去重、GLM-5.2/其他模型图标、仪表盘进度条、DeepSeek/OpenCode 设置展开等已经完成的功能语义。
- 不改变额度计算、费用定价、时区边界、all-time 起始日期、active time 或 history 的对外数据结构。
- 不在本轮发起整套界面改写，也不以“原生化”为理由替换已稳定的渲染层。
- 未经引用搜索、构建和运行验证，不批量删除 Swift、JS、CSS、图片或 Tokscale 相关文件。

## 3. 执行原则

- 每个阶段应可独立测试，建议每阶段一个提交，便于回滚和二分定位。
- 先建立统计结果夹具，再改变聚合实现。
- 失败时保留最后一次成功快照，不能把主页或仪表盘清空为零。
- 所有采集工作继续在非主线程执行；共享缓存必须有明确的串行队列或锁保护。
- 性能诊断只在 `TOKEN_MONITOR_DIAG=1` 或 Debug 构建下启用，Release 默认不得产生高频日志。
- 优化必须以 physical footprint、CPU 时间、Tokscale 子进程数和实际扫描次数衡量，不能只比较 RSS。

## 4. 分阶段实施

### Phase 0：冻结行为并建立性能基线

涉及位置：

- `native-app/Sources/TokenMonitor/Collector/CollectorCore.swift`
- `native-app/Sources/TokenMonitor/Collector/TokscaleRunner.swift`
- 本地适配器与 history/aggregation 实现
- 原生构建和诊断脚本

实施内容：

1. 为以下操作增加低开销计时或 `os_signpost`：完整 collector tick、每次 Tokscale 子进程、每个本地适配器、period 聚合、history 构建和 UI push。
2. 每次完整刷新记录唯一 refresh ID，并记录触发原因：startup、timer、manual、settings-change。
3. 建立固定输入夹具，保存优化前的以下输出：today/month/allTime totals、cost、models、clients、sessions、active time、daily/monthly history 和 limits 包装结果。
4. 覆盖关键日期边界：本地午夜、月初、allTimeSince、无时间戳记录和夏令时环境。
5. 采集基线：启动到首个可用 stats 的时间、启动 CPU 峰值、稳定后 2 分钟平均/峰值 CPU、Tokscale 启动次数、打开/关闭两个窗口前后的 physical footprint、WebKit 子进程数和应用实例数。

完成标准：

- 可从一次诊断日志明确看出耗时花在哪个阶段，以及一次刷新启动了多少个 Tokscale。
- 有可自动比较的优化前统计夹具；后续阶段不得依靠肉眼判断统计是否一致。
- 未设置诊断开关时没有新增周期日志。

### Phase 1：强制单实例运行

主要涉及：`native-app/Sources/TokenMonitor/AppDelegate.swift`，必要时新增单一职责的 `SingleInstanceCoordinator.swift`。

实施内容：

1. 在创建状态栏、窗口、`Collector` 和 `LimitsRuntime` 之前取得应用级单实例所有权。
2. 推荐使用带原子所有权的命名锁或 Unix socket，并处理进程异常退出后的陈旧所有者；仅查询 `NSRunningApplication` 不足以避免两个实例同时启动的竞态。
3. 第二次启动获取所有权失败时，定位并激活现有实例，通过轻量 IPC/通知要求其显示主窗口，然后立即退出。
4. 所有权释放放在正常终止路径；异常终止后下一次启动必须能够恢复。
5. 同时验证 Finder/LaunchServices 启动、直接运行 `.app/Contents/MacOS/...` 和快速连续双击。

完成标准：

- 连续启动多次后始终只有一个 Token Monitor 应用进程和一套 collector/limits 定时器。
- 第二次启动不会创建 WebView、Tokscale 子进程或后台采集任务，并能唤起现有窗口。
- 崩溃或强制结束后能够正常再次启动，不会被永久锁住。

### Phase 2：将 Tokscale 完整扫描合并为一次（最高收益项）

主要涉及：

- `native-app/Sources/TokenMonitor/Collector/CollectorCore.swift`
- `native-app/Sources/TokenMonitor/Collector/TokscaleRunner.swift`
- Tokscale 解码模型与 Usage/History 聚合代码

实施内容：

1. 在修改前先确认当前 Tokscale JSON 是否包含足以重建 period 和 history 的逐日/逐会话时间字段，不得假设聚合后的 `client,session,model` 条目仍有完整时间信息。
2. 每个 full tick 只读取一次覆盖 `allTimeSince` 至当前时刻的原始或可按时间切分的数据。
3. 在 Swift 中从同一批已解码记录派生 today、month 和 allTime，统一使用现有本地时区边界函数。
4. 使用同一批记录构建 daily/monthly history 和 active-time 结果，消除独立 `graph` 扫描。
5. 如果现有 Tokscale 输出缺少所需字段，应扩展 runner/API 或为 vendored Tokscale 增加一个专用 combined 命令；不可保留 3+1 次扫描后仅在外层伪装成一个接口。
6. 扫描成功后原子替换快照；任一解析或子进程错误均保留上一次成功的 periods/history，并暴露可诊断错误状态。
7. 记录输入文件指纹与成功快照，为 Phase 3 的“未变化不扫描”做好接口准备。

完成标准：

- 每次计划内 full refresh 最多启动一个 Tokscale 全量数据进程。
- 不再出现 today、month、allTime、graph 对同一批文件的四次重叠扫描。
- Phase 0 的 totals、cost、models、clients、sessions、active time 和 history 夹具完全一致；任何有意差异必须先书面说明并获得确认。
- 扫描失败时 UI 继续显示最后成功数据，并允许后续刷新恢复。

### Phase 3：按数据源变化增量采集

主要涉及：Collector、本地适配器和各客户端文件发现逻辑。

实施内容：

1. 为每类客户端定义稳定的数据源指纹，至少包含相关文件集合、大小和修改时间；若目录规模允许，可使用文件事件通知作为快速触发，但仍保留低频校验。
2. 只有源指纹变化的客户端才重新读取与解析；缓存每个客户端的 rows、period contribution、history contribution 和最后成功指纹。
3. Proma、Hanako、DSH 不再每 15 秒无条件遍历、分组和计算 today/month/allTime。
4. 模型 pricing 按规范化 model ID 缓存；已命中且未过期时不重复执行定价查找。
5. Tokscale 客户端的数据文件未变化时直接复用快照，不启动子进程。
6. 加一个更长周期的安全对账，防止文件事件丢失；对账先比指纹，不盲目全量解析。
7. 手动刷新强制重新检查所有数据源，但默认仍复用未变化的历史；如确需真正重建，可另设诊断级 force-rescan，不放到常用刷新路径。

完成标准：

- 数据源完全未变化时，周期 tick 不读取历史文件、不启动 Tokscale、不重算全部聚合。
- 单一客户端变化只重算该客户端，其他客户端缓存保持有效。
- 新增、修改、删除数据文件后能在预期刷新周期内正确反映，并通过低频对账恢复遗漏事件。

### Phase 4：重构调度、合并重复请求并改善启动路径

主要涉及：`CollectorCore.swift`、`SettingsStore` 变更通知和相关 bridge 调用。

实施内容：

1. 将“便宜的当前状态刷新”和“昂贵的完整历史刷新”拆分成明确任务，不再用一个 `full: Bool` 隐含所有行为。
2. 对 startup、timer、manual 和 settings change 请求做 coalescing：正在运行时最多保留一个必要的后继刷新，并合并相同或可被更强请求覆盖的任务。
3. 保证不会因为手动刷新、定时器到点和设置更新接近发生而排队执行多次全量扫描。
4. 启动时优先发布缓存或 current-day 数据，使主页尽快可用；完整 history 可随后低优先级补齐。
5. 设置中的 `refreshMs`/`collectionIntervalMs` 变化后重建或更新 timer；当前 timer 只在启动时捕获 interval，需修正。
6. 为超时、取消和应用终止定义清晰行为，避免孤立 Tokscale 子进程。
7. 可选：在低电量模式或电池供电时降低非关键 history 对账频率，但只有产品行为确认后再启用。

完成标准：

- 任意时间只有一个 collector 工作单元实际执行，不产生冗余 full refresh 队列。
- 设置刷新周期后无需重启即可生效。
- 冷启动能先显示可用 stats，不被完整 history 扫描阻塞。
- 应用退出后没有遗留 Tokscale 子进程。

### Phase 5：管理 WKWebView 生命周期并回收内存

主要涉及：

- `native-app/Sources/TokenMonitor/AppDelegate.swift`
- `native-app/Sources/TokenMonitor/DashboardWindowController.swift`
- `native-app/Sources/TokenMonitor/Bridge.swift`
- `native-app/Resources/tokenMonitorBridge.js`

实施内容：

1. 保持主窗口和仪表盘按需创建，不在 tray-only 启动路径提前构建 WebView。
2. 明确定义 hide 与 close：短暂切换仍可 `orderOut` 快速恢复；仪表盘关闭或隐藏超过短暂空闲期后销毁 controller/WebView。
3. 释放前停止导航、移除 `WKScriptMessageHandler`、通知观察者、bridge 订阅和 JS 事件监听，再清空 `AppDelegate` 强引用。
4. 仪表盘重新打开时必须恢复状态，且不能重复注册 listener 或重复收到一次 push。
5. 主悬浮窗可采用更保守的长空闲释放策略；先测量重建延迟再决定阈值。
6. 如果确实需要同时保留两个 WebView，评估共享 `WKProcessPool` 的收益；必须以测量结果决定，不作为默认假设。

完成标准：

- 重复打开/关闭仪表盘不会持续增加 physical footprint、WebKit 子进程或事件监听数量。
- 达到释放条件后，physical footprint 有可重复的明显下降。
- 重新打开页面功能完整，没有空白页、重复数据、失效按钮或重复 bridge 消息。

### Phase 6：渲染与 GPU 清理

只在 Phase 1–5 完成并重新测量后执行。

实施内容：

1. 窗口不可见时暂停非必要动画、计时器、DOM observer、图表更新和 history 重绘。
2. `dashboard:historyChanged` 等事件仍可更新原生缓存，但隐藏的 dashboard 不应触发完整 DOM render。
3. 支持系统 Reduce Motion；可见时恢复动画必须避免一次性补跑积压帧。
4. 分别测量透明 WebView、`NSVisualEffectView` blur/vibrancy、阴影的 GPU/内存影响，再决定是否降低效果。
5. 不因主观判断直接移除现有视觉效果；只有可测收益且不破坏 UI 时才调整。

完成标准：

- 两个窗口隐藏时不存在持续动画帧或周期性整页重绘。
- 可见与隐藏状态的 CPU/GPU 差异能够由诊断数据解释。
- 所有窗口在普通、Reduce Motion 和多屏环境下显示正常。

### Phase 7：在性能稳定后继续瘦身

实施内容：

1. 以原生 Release 构建产物为准生成资源引用清单：Swift bundle lookup、HTML/CSS/JS 引用、动态 icon/model/provider 映射和 stage 脚本均要纳入。
2. 对候选代码执行全仓引用搜索，并检查字符串反射、bridge method、通知名和动态资源名，避免误删“静态搜索无引用但运行时使用”的内容。
3. 优先删除已确认不可达的 Electron 专属代码、未被原生 stage 的资源、重复兼容层和废弃诊断入口。
4. 每一小批删除后执行资源校验、JS 语法检查和原生 Release 构建；不要积累大批删除后一次排错。
5. 保留第三方许可文件和仍在分发产物中使用的版权声明。
6. 最后比较 `.app` 体积、启动时间和运行内存，避免把代码体积缩小误当成运行性能优化。

完成标准：

- Release `.app` 内没有已证明无引用的代码和资源。
- 所有动态模型/provider 图标、设置入口、主页、仪表盘和额度展开功能仍可访问。
- 删除清单能说明“为何安全删除”和“如何验证”，便于后续审查。

## 5. 总体验收指标

以下指标全部满足后，性能优化才算完成：

- 重复启动后恰好只有一个 Token Monitor 应用实例和一套采集器。
- 启动采集稳定后，正常空闲 CPU 平均低于 1%，且不再周期性出现由 4 次重叠 Tokscale 扫描造成的单核峰值。
- 每次计划内完整刷新最多运行一个 Tokscale 全量数据进程。
- 所有监控源未变化时不启动 Tokscale，也不重新解析本地历史文件。
- 启动时先提供可用 current stats，完整历史计算不会阻塞首个主页数据。
- 连续打开/关闭仪表盘至少 20 次后，内存与 listener 数量不会单调增长；释放后 physical footprint 能明显回落。
- 优化前后的 totals、cost、model/client/session breakdown、limits、active time 和 dashboard history 与基准夹具一致。
- OpenCode Go 主页只显示一次；GLM-5.2 和其他模型图标正确；模型/工具比例条对齐；DeepSeek/OpenCode 额度可展开。
- 原生 Release 构建、JS 语法检查、stage 资源引用检查和 `git diff --check` 全部通过。

## 6. 建议测试矩阵

### 自动测试

- period 边界与聚合 fixture 对比。
- Tokscale combined 输出解码、错误回退和快照原子替换。
- 文件指纹：无变化、追加、覆盖、删除、原子 rename。
- refresh coalescing 状态机与设置 interval 热更新。
- single-instance owner、第二实例、陈旧 owner 恢复。
- bridge attach/detach 后 listener 数量和消息只投递一次。

### 手工/集成测试

1. 清洁启动并记录首次 stats、完整 history 到达时间及 CPU 曲线。
2. 快速重复启动应用，确认只保留一个实例且现有窗口被唤起。
3. 保持数据源不变超过两个普通刷新周期和一个 full 周期，确认没有 Tokscale 进程和文件重扫。
4. 分别修改各客户端的一份数据，只观察对应客户端重算。
5. 扫描期间连续点击手动刷新并修改 refresh 设置，确认没有排队全量扫描。
6. 人为制造 Tokscale 超时/非零退出，确认旧数据显示不消失，恢复后可更新。
7. 打开、隐藏、关闭和重开主窗口/仪表盘，检查功能、内存、WebKit 进程和重复事件。
8. 回归主页、模型页、工具页、仪表盘、设置额度展开和全部模型图标。

## 7. 推荐提交顺序

1. `test(perf): add collector baselines and aggregation fixtures`
2. `fix(native): enforce a single running app instance`
3. `perf(collector): collapse tokscale scans into one snapshot`
4. `perf(collector): skip unchanged client sources`
5. `perf(collector): coalesce refresh scheduling`
6. `perf(native): release inactive dashboard webviews`
7. `perf(renderer): suspend hidden-window rendering`
8. `chore: remove verified unused native-port assets and code`

不要把统计语义变更、调度变更、WebView 生命周期和大批文件删除塞进同一个提交。

## 8. 交付记录要求

实现者完成每个 Phase 后，应在 PR/提交说明中记录：

- 修改前后测量环境和数字。
- Tokscale 调用次数及各阶段耗时变化。
- 统计 fixture 是否完全一致。
- 新增缓存的失效规则和错误回退行为。
- 删除的文件/代码及引用验证依据。
- 未解决风险、平台差异和后续建议。

若实现过程中发现 Tokscale 单次输出无法同时保持当前 period/history 语义，应暂停 Phase 2 的代码改动，先提交输出字段调查结果和最小 API 设计，不得以近似统计替代现有结果。
