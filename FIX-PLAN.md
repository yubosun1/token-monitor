# 修复计划：卡顿 / 设置滚动 / 全局快捷键与自动关闭 / 活动与趋势视图

（供 DeepSeek Flash 执行。每个问题都有已定位的根因和验证方法；改完请逐条跑"验收"里的命令。）

---

## 1. 卡顿、鼠标转圈（最重要）

### 根因 A：15 秒定时器把整个采集 tick 跑在主线程上
`Collector.swift` `start()` 里的 `Timer` 挂在 `RunLoop.main`，回调里**直接同步调用 `tick(full: false)`**（不是 dispatch 到 collector 队列）。每个 tick 都要：
- 重读全部 proma 文件（35 个 / 22MB）+ 全扫 hanako 目录树（950MB 目录枚举，24 个 jsonl）+ **完整流式解压全部 9 个 DSH zstd 会话文件（20MB 压缩）**；
- 每 5 分钟一次（`fullTick`）还在主线程上顺序跑 3 次 tokscale CLI 全量扫描 + 1 次 graph 扫描（大历史时单次可 10s+）；
- 最后 `core.push("stats:push", stats)` 在主线程把包含全部 sessions 的大 JSON 序列化并 `evaluateJavaScript` 进 webview。

**修复（`native-app/Sources/TokenMonitor/Collector/CollectorCore.swift`）：**
1. `start()` 的 Timer 回调改为 `queue.async { self?.tick(full: false) }`（与初始 tick 一致，全部采集工作离开主线程）。
2. `tick()` 的 `collecting` 标志目前跨线程裸读写有竞态，改为主线程切换 + 队列串行（或用 `queue.sync` 检查/置位；collector 队列本身就是串行的，Timer 只负责触发，标志竞争自然消失，但记得 `refreshNow()` 与 timer 双路径共用一个队列即可）。

### 根因 B：`core.push` 在后台队列调用 `evaluateJavaScript`（WKWebView 只允许主线程）
`Bridge.attach` 里的 pusher 闭包直接 `webView.evaluateJavaScript(...)`。采集/限额刷新都在后台队列 push → 违反 WebKit 线程约束，会造成卡死/偶发崩溃。

**修复（`Bridge.swift`）：** pusher 闭包体改为：
```swift
DispatchQueue.main.async { webView.evaluateJavaScript(...) }
```
（`session:getDetail` 的异步回包已经是这么做的，照抄模式。）

### 根因 C：每 15 秒重复解压/重读未变化的适配器文件
**修复（`Adapters.swift` / `CollectorCore.swift`）：** 给 dsh 的 `decompressZstd` 结果按 `(path, mtime, size)` 建内存缓存；proma/hanako 同样按文件 mtime+size 跳过未变化文件（读一次缓存解析结果）。只有变化的文件才重新解析。可进一步把适配器 tick 间隔从 `refreshMs`(15s) 提到 30–60s（tokscale 4 客户端本来就是 5 分钟）。
> 数据量参考（用户机器）：`.dsh/sessions` 20MB/9 文件、`.proma/agent-sessions` 22MB/35 文件、`.hanako` 目录 950MB（枚举本身就慢）。缓存 mtime 后单 tick 成本可降到接近 0。

### 根因 D：stats 帧每 15 秒全量重推 → 渲染层整页重渲染
**修复（`CollectorCore.swift`）：** `buildStats` 前与 `statsCache` 比较"内容签名"（`today/month/allTime` 的 `totalTokens/costUsd` + `clientCosts` + `clientStatus`，忽略 `updatedAt`/`collectedAt`/`receivedAt`）。签名未变就跳过 `core.push("stats:push", ...)`（`statsCache` 仍更新，`stats:get` 不受影响）。limits 刷新走 `reemitStats()` 单独推，不受此限制。

### 验收
- `TOKEN_MONITOR_DIAG=1 ./dist/Token\ Monitor.app/Contents/MacOS/TokenMonitor > native-app/.tmp/diag-fix.log 2>&1`，用 `sample TokenMonitor 5` 或系统监视器观察：无 15 秒一次的 CPU 尖峰；`[diag] collected:` 行之间 UI 不转圈；日志里无 `[renderer]` 错误。
- 手动：开着 App 用其他程序 10 分钟，鼠标不转圈；⌘E 秒开。

---

## 2. 设置面板无法滚动、展开后被遮挡

### 根因（已用最小复现实验证实，100% 确定）
这是 **WKWebView 的 max-height 过渡 bug**：`styles.css` 里
```css
.settings-panel { max-height: calc(100vh - 72px); transition: max-height 140ms ease, ...; }
.settings-panel.hidden { max-height: 0; ... }
```
从 `max-height: 0` 到 `calc(...)` 的 transition 在本机 WKWebView 中**冻结在起始值**（面板高度一直是 0，内容 1400px 被裁剪 → "看不到下面的选项、无法滚动"）。实验：同样 CSS 六组对照，唯一去掉 `transition` 的组正常（maxHeight=578px、可滚动）；连内联 `style="max-height:578px"` 都被冻在 0px。原版 Electron（Chromium）无此 bug。

**修复（最小改动，渲染层一行）：** `src/electron/renderer/styles.css` 的 `.settings-panel` transition 列表里**删掉 `max-height`**（保留 opacity/padding/transform 的动画）：
```css
transition: opacity 120ms ease, padding 140ms ease, transform 140ms ease;
```
`.hidden` 的 `max-height: 0` 规则保留（瞬时收起）。修改后 `stage-www.sh` 会把它拷进 `build/www`。
> 已用探针验证：去掉 max-height 过渡后（变体 pG/pB）面板 578px、`overflow-y:auto` 正常滚动。复现脚本留在 `native-app/.tmp/css-repro.swift`（gitignored），可复跑。

### 验收
- 打开设置 → 展开全部 6 个区块 → 面板出现滚动（trackpad 可滚，滚到底能看到"订阅"区块底部）；收起动画仍平滑（无 max-height 动画，瞬时收起可接受）。
- 可复用 `native-app/.tmp/scrollprobe3.swift`（带 mock 桥的忠实复现，gitignored）回归：`panelMaxHeight` 应为 `578px`、`clientHeight>0`。

---

## 3. 全局快捷键呼不出界面；窗口不会自动关闭

### 根因 A：只注册了"本地"事件监听
`AppDelegate.registerToggleShortcut()` 用 `NSEvent.addLocalMonitorForEvents`，**只有本 App 是前台活跃时才会收到按键**；LSUIElement 常驻后台时 ⌘E 永远不触发。原版 Electron 用的是 `globalShortcut.register(settings.windowToggleShortcut)`（全局热键），设置键名为 `windowToggleShortcut`（渲染层"窗口"区块有录制按钮，值形如 `Command+Shift+E`，格式由已保留的 `windowShortcut.js` 规范化）。

**修复（`AppDelegate.swift`，或新建 `ShortcutController.swift`）：**
1. 用 **Carbon `RegisterEventHotKey`** 注册全局热键（不需要辅助功能权限，比 `addGlobalMonitorForEvents` 干净；LSUIElement 可用）。
2. 解析 `settings.windowToggleShortcut` 字符串（`CommandOrControl|Command|Control|Alt|Shift` + 按键名 → Carbon keyCode/modifiers，反向映射照 `windowShortcut.js` 的 `MODIFIER_ALIASES`/`NAMED_KEYS` 表移植）；为空时回退注册 **⌘E**（用户已有肌肉记忆，且这正是现硬编码行为）。
3. 监听设置变化（`settings:update` 里 `windowToggleShortcut` 变化 → 注销并重注册；参考同文件 `applyStartAtLogin` 的调用点）；`applicationWillTerminate` 注销。
4. 删除现在的本地 ⌘E monitor（或保留仅当窗口 key 时用，避免与全局热键重复触发——建议直接删）。

### 根因 B：缺"失焦自动关闭"
原版 Electron：`mainWindow.on('blur')` → `if (settings.trayMode && !suppressNextBlurHide) hidePopover()`（显示后 250ms 抑制误关）。原生侧 `GlassPanel.hidesOnDeactivate = false` 且无任何失焦处理 → 点别处窗口永远挂着。

**修复（`GlassWindowController.swift`）：** 观察 `NSWindow.didResignKeyNotification`（对 mainWindow，必要时也加 `NSApplication.didResignActiveNotification`）→ 当 `trayMode` 为 true 且距上次 `showWindow` 超过 250ms → `window.orderOut(nil)`。设置面板开着时也照关（原版如此）。`window:close` 已实现 orderOut，无需动。
> 注意：`beginDrag()` 的原生拖拽事件循环也会抢占 main runloop，拖拽期间不要触发失焦关闭。

### 验收
- 焦点在任意其他 App（Safari 等）时按 ⌘E（或设置里录制的组合键）→ 窗口弹出；再按 → 关闭。
- 窗口弹出后点击任意其他 App → 窗口自动隐藏；托盘左键切换正常；设置"窗口"区块录制新快捷键后立即生效。

---

## 4. "活动"（status）视图

### 现状与根因
视图渲染代码齐全（`renderServiceStatus`），但桥接 `serviceStatus:get` 恒返回 `{providers: []}` → 视图只显示 4 个"未检测"占位行。原版 Electron 由 `src/electron/serviceStatus.js` 定时抓 statuspage.io 的 `api/v2/summary.json` 给出真实状态（ok/degraded/outage/unknown）。参考原版：`git show c9108b7b:src/electron/serviceStatus.js`（4 个 provider 及 URL、`providerTone`/`componentIssues` 映射、60s 缓存、5s 超时、10s 错误缓存都在里面）。

**修复（新建 `native-app/Sources/TokenMonitor/Status/ServiceStatus.swift`，仿 `LimitsRuntime` 模式）：**
1. 移植 4 个 provider（claude/openai/cursor/deepseek，注意 deepseek 用 `https://deepseek.statuspage.io/api/v2/summary.json`）的 URLSession GET + 原版字段映射（`id/label/pageUrl/status/indicator/description/checkedAt/updatedAt/componentIssues/incidentTitle/incidentCount/maintenanceCount`，渲染层消费的键一个都不能少）。
2. 60s 缓存；后台队列取数；取完把结果并入 `BridgeCore` 的 `serviceStatus:get` 返回（原方法签名带 `options.force/providerIds`，至少处理 `force`）。
3. 刷新后可以经 `core.push` 通知视图（或让渲染层 ticker 自己按 `refreshMs` 重拉，原版就是这么做的——`ensureServiceStatusTicker` 每秒只更新 ago 标签，按 `serviceStatusRefreshMs()` 重拉；保持 `refreshMs: 60000` 即可）。

### 验收
- 切到"活动"视图：4 行（Claude/OpenAI/Cursor/DeepSeek）显示彩色状态 pill（ok=绿）与"X 分钟前"更新时间；断网时显示 unknown 而非空白。

---

## 5. "趋势"（trends）视图

### 根因
`renderTrends()` 读 `state.stats.historyPreview`（`{daily:[{date,tokens,cost,activeTimeMs}×30], monthly:[{month,...}×12], summary:{activeDays,currentStreak,activeTimeMs,peakDayTokens}}`），而原生 `buildStats` 只放了 `stats["history"]`，没有 `historyPreview` → 视图永远走 `trends.empty` 分支。原版生成器在 `src/shared/history.js` 的 `historyPreview(history, {dailyDays:30, monthlyMonths:12})`：`daily.slice(-30)`/`monthly.slice(-12)` 挑字段 + 原样带 summary。

**修复（`CollectorCore.swift` 的 `buildStats`）：** `cachedHistory` 存在时加
```swift
stats["historyPreview"] = [
  "daily":  (history["daily"] as? [[String: Any]] ?? []).suffix(30).map { 挑出 date/tokens/cost/activeTimeMs 四个键 },
  "monthly": (history["monthly"] as? [[String: Any]] ?? []).suffix(12).map { 挑出 month/tokens/cost/activeTimeMs },
  "summary": history["summary"] ?? [:]
]
```
（`HistoryCore.swift` 的 daily 条目已含这些键：`date/tokens/cost/activeTimeMs`，summary 已有 4 个键，直接映射即可。）首页 heatmap（homeOverview）也消费同一个 `historyPreview`，会一并修好。

### 验收
- "趋势"视图出现 30 天柱状图（today 为天级、month 月级、allTime 年粒度）+ 4 个统计卡（活跃天数/连续天数/活跃时长/峰值日），数值与首页 heatmap 一致。
- 首页 heatmap 不再空白。

---

## 通用验收（全部改完后）

1. `./native-app/scripts/build-app.sh` 构建成功（0 错误）；`TOKEN_MONITOR_DIAG=1` 跑 10 分钟：日志 `[renderer]` 计数为 0，`[diag] collected:` 正常周期输出。
2. 手动过一遍：托盘点击/⌘E 弹出与自动关闭、设置面板滚动到"订阅"底部、每个设置区块展开收起、会话详情弹窗（上轮已实现，勿回归）、活动/趋势两视图有数据、限额页 deepseek/opencode 正常。
3. 性能：活动监视器观察 CPU 空闲时应接近 0；对比修复前"每 15 秒一次尖峰"。

## 不要动的部分（回归红线）

- 桥接通道名与 wire 形状（`session:getDetail` 的返回结构、`stats:push` 的 periods/sessions 键、`historyPreview` 与 `history` 形状均为渲染层既有契约，按上面写好的形状补，别改渲染层消费方）。
- `SessionDetail.swift`（已验收通过，别顺手重构）。
- 7 客户端列表约定、`stage-www.sh` 的路径改写。
- 提交沿用 conventional commits：`fix(native):` / `fix(renderer):`。
