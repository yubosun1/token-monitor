# AGENTS.md

本仓库是 token-monitor 的 **macOS 原生定制版**（个人 fork，不再有 Electron/Node 运行时）。渲染层保留原版 HTML/CSS/JS（`src/electron/renderer/`），跑在原生 Swift 外壳的 WKWebView 里；采集、限额、订阅全部在 Swift 侧实现。

## 构建与运行

```bash
./native-app/scripts/build-app.sh          # 完整构建 → dist/Token Monitor.app（ad-hoc 签名）
TOKEN_MONITOR_DIAG=1 ./dist/Token\ Monitor.app/Contents/MacOS/TokenMonitor 2>log   # 诊断运行
```

直接 `swift build` 需要（文件沙箱环境下）：
```bash
cd native-app && TMPDIR=$PWD/.tmp SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.cache swift build --disable-sandbox
```

没有 npm 脚本；不装 node_modules。tokscale 二进制（`native-app/Vendor/tokscale/`）与 libzstd 静态库（`native-app/Vendor/zstd/`）已 vendor 化，构建不依赖 Homebrew。

## 架构

- **外壳**（`Sources/TokenMonitor/AppDelegate.swift`、`DashboardWindowController.swift`）：NSStatusItem 托盘 + 置顶玻璃 NSPanel + WKWebView。LSUIElement 应用，⌘E 切换窗口，标题栏拖拽由注入脚本发 `window:dragStart` 驱动（WKWebView 不认 `-webkit-app-region: drag`）。
- **渲染层桥**（`Resources/tokenMonitorBridge.js` + `Sources/TokenMonitor/Bridge.swift`）：注入脚本实现 `window.tokenMonitor`（与原 Electron preload.js 同名同签名），经 `webkit.messageHandlers.bridge` 转发到 `BridgeCore.handleInvoke/handleSend`；回包走 `window.__tmResolve(id, json)`。方法名必须用原 Electron 的 IPC 通道名（如 `settings:get`、`stats:get`、`clipboard:write`）。
- **采集**（`Collector/`）：`CollectorCore` 定时 tick —— 本地适配器（proma/hanako/dsh）每 `refreshMs`（15s）重扫，tokscale 四个客户端每 `collectionIntervalMs`（5min）全量扫（今天/本月/全部三次调用）。聚合形状（period/session 的 JSON 键）必须与旧 `src/shared/usage.js` 的 wire 协议一致，渲染层按原协议消费。
- **限额**（`Limits/`）：`LimitsRuntime` 每 `limitsRefreshMs`（5min）刷新 deepseek（`DeepseekBalance`，余额历史记录在 `deepseek-balance-v2.json`）与 opencode（`OpencodeLimits`，opencode.ai Web API 移植版）。刷新后经 `Collector.reemitStats()` 把新 limits 摘要塞进 stats 帧推送。
- **凭证**（`Limits/CredentialStore.swift`）：沿用旧版 `~/Library/Application Support/Token Monitor/credentials.json`；settings.json 里不存明文（settings:get 会剔除 `deepseekApiKey`/`opencodeProfiles`/`opencodeCookie`，settings:update 会把这些键路由进凭证库）。
- **设置**（`SettingsStore.swift`）：`~/Library/Application Support/Token Monitor/settings.native.json`。startAtLogin 走 SMAppService 注册，值仍存设置里。

## 渲染层瘦身的约定

- 设置面板里被删除的区块（同步/外观/导出/更新/多余限额账户等）在 `index.html` 中直接移除；app.js 里用 `els` Proxy（`__tmMissingElement`）+ `Array.from` 空值补丁兜底，不再逐个判空。
- 客户端列表统一在 7 个：`claude,codex,opencode,workbuddy,proma,hanako,dsh`（app.js 的 `clientLabels`/`KNOWN_CLIENTS`/`clientsWithIcon` 与 Swift `CollectorCore`、`Bridge.clientSourceRoots` 要一致）。
- 新增客户端需同步：app.js 三处列表 + `assets/icons/<id>.svg` + styles.css `.row-icon-<id>` 规则 + Swift 采集器 + `clientSourceRoots`。
- `stage-www.sh` 负责把渲染层拷进 `native-app/build/www/` 并改写相对路径（`../../shared/`→`shared/`、`../../../assets/icons/`→`icons/`）；新引用路径要跟着改脚本。

## 数据与兼容

- 用量统计全新开始（不迁移旧历史）；订阅记录与凭证沿用旧文件。
- 限额 provider 白名单只有 deepseek、opencode；`LimitsRuntime` 与渲染层 `LIMIT_PROVIDERS`（app.js）须一致。
- DSH 采集：`~/.dsh/sessions/*/session-*/session.jsonl.zstd`（流式 zstd 帧，必须用 `ZSTD_decompressStream`），按 `finish` 块的 `replayState.model` 归属模型，usage 事件取 `inputTokens/outputTokens/cacheReadTokens`。

## 约定

- 渲染层（app.js 等）保持与原版语法风格一致，改动最小化；Swift 侧用 `[String: Any]` 字典承载 wire JSON。
- 提交信息沿用 conventional commits（`feat(native):`、`fix(renderer):` 等）。
- 修改桥接方法名、settings 键或 wire 形状前，先核对渲染层消费方（app.js/dashboard.js/homeOverview.js）。
