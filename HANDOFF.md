# HANDOFF.md — 换模型继续开发的交接提示词

> 本文件写给接手此仓库的任何 AI 模型。仓库当前在 `macos-native` 分支，最新提交 `1c71948`（已完成 macOS 原生化主体工作）。先通读 AGENTS.md，再按本文件继续。

## 一、项目现状（已完成并验证）

把 Electron 版 token-monitor 改造成了 **纯原生 macOS 应用**，构建产物 `dist/Token Monitor.app`（ad-hoc 签名，LSUIElement 菜单栏应用）：

- **外壳**：Swift/AppKit —— NSStatusItem 托盘 + 置顶悬浮玻璃 NSPanel（HUD vibrancy）+ WKWebView；⌘E 全局切换；原生标题栏拖拽（注入脚本发 `window:dragStart`）。见 `native-app/Sources/TokenMonitor/AppDelegate.swift`、`DashboardWindowController.swift`。
- **渲染层**：原版 HTML/CSS/JS 原样保留（`src/electron/renderer/`），经 `stage-www.sh` 打进 app。`Resources/tokenMonitorBridge.js` 替代 Electron preload（`window.tokenMonitor` 同名同签名，走 `webkit.messageHandlers.bridge`）。
- **采集**（已验证与 JS 参考实现逐位一致）：tokscale 四客户端（claude/codex/opencode/workbuddy）+ 原生 Swift 解析器 proma/hanako/dsh（DSH 用 vendor 的静态 libzstd 流式解压 `~/.dsh/sessions/*/session-*/session.jsonl.zstd`）。`Collector/CollectorCore.swift`、`Adapters.swift`、`UsageCore.swift`、`HistoryCore.swift`。
- **限额**（已验证真实 API 返回）：DeepSeek 余额（含每日消耗历史 `deepseek-balance-v2.json`）、OpenCode Web API 移植（`Limits/OpencodeLimits.swift`）、订阅、凭证（沿用旧 `credentials.json`）。`Limits/LimitsRuntime.swift`、`DeepseekBalance.swift`、`Subscriptions.swift`、`CredentialStore.swift`。
- **瘦身**：渲染层删了同步/外观切换/导出/更新/Discord/WSL/多余限额账户等设置区块；客户端列表裁到 7 个并新增 dsh；限额只留 deepseek+opencode；仓库删光 Electron/Node 代码（hub/agent/worker/site/docs/tests/node_modules 等）。
- 最后状态：`./native-app/scripts/build-app.sh` 构建通过，TOKEN_MONITOR_DIAG=1 运行 0 个渲染层报错。

## 二、构建/运行命令（照抄）

```bash
./native-app/scripts/build-app.sh          # 构建 → dist/Token Monitor.app
TOKEN_MONITOR_DIAG=1 ./dist/Token\ Monitor.app/Contents/MacOS/TokenMonitor > native-app/.tmp/app.log 2>&1 &
# 日志关键字: [diag]（页面状态/采集/交互探测）、[renderer]（JS 报错，应为 0）
```

直接 swift build 时带环境变量（文件沙箱下必需）：`cd native-app && TMPDIR=$PWD/.tmp SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.cache swift build --disable-sandbox`。

## 三、剩余工作（按优先级）

### 1. 安装替换旧 Electron 应用
- 退出旧版 `/Applications/Token Monitor.app`（Electron），把 `dist/Token Monitor.app` 拷进 `/Applications/`。
- 验证：托盘图标出现；点击打开悬浮窗；⌘E 切换；"设置→通用→开机启动" 开关实际写入了系统设置（SMAppService 注册，见"系统设置→通用→登录项"）。
- 注意：沙箱内测试时 settings.json 写不进去（`[settings] persist failed` 属沙箱假象，用户正常环境无此问题）。

### 2. 会话详情（session:getDetail）—— 目前是空 stub
- 现状：`Bridge.swift` 的 `session:getDetail` 返回空 rows，弹窗没内容。渲染层 `src/electron/renderer/sessionDetail.js` 期望 `{rows:[{startTime,value,...}]}` 一类结构（先读它确定形状）。
- 实现建议：先给 proma/hanako/dsh 用适配器已有的消息行（`Adapters` 的 UsageRow 带时间戳）拼出详情；tokscale 四客户端需要逐客户端解析会话文件（原实现已删，可用 `git show 43f7fe5:src/shared/sessionDetail.js` 找回参考，约 365 行：claude/codex 转写解析 + opencode 会话读取），按需移植。
- 若暂不做：把弹窗入口对无数据情况做优雅降级（显示"暂无详情"）。

### 3. 项目分组视图（projectsEnabled）—— 目前默认关闭
- 原版从会话文件的 cwd 派生项目归属；tokscale 条目本身不含路径。要启用需移植项目归属逻辑（参考 `git show 43f7fe5:src/shared/collector.js` 的 applySessionTimestamps/metadata 与 `git show 43f7fe5:src/shared/projectKey.js`）。用户主要用主视图，此项可选。

### 4. 性能验证与对比
- 用活动监视器对比旧 Electron（旧进程约 400–600MB）与新原生 app（预期 80–160MB、常驻 CPU≈0）。
- 确认首次 tick（tokscale 三次全量扫描）约 30–40s 内完成、之后每 15s 轻扫 / 5min 全扫不产生明显唤醒。
- 如嫌 tokscale 首次慢：可考虑只跑 `--today` + 缓存月/全部周期结果（与旧版锚点增量思路相同）。

### 5. 深测与细节打磨
- 窗口拖拽/缩放、最小化/关闭按钮、设置修改保存（语言、货币、刷新间隔等）——沙箱内测不了持久化，需正常环境。
- 交互探测已内置（TOKEN_MONITOR_DIAG=1 启动后 22s 自动打开设置/限额视图并输出 `[diag] interaction:` JSON），沿用即可。
- 可选清理：styles.css / i18n.js / app.js 里删除区块的死代码（不影响运行，低优先级）。
- 可选：替换应用图标 `assets/icon.png`；应用名保持 "Token Monitor"。

### 6. 发布
- `git remote -v` 确认用户 fork，把 `macos-native` 分支推上去；如需发布，给用户写安装说明（README 已有）。

## 四、给接手模型的关键规则

1. **wire 协议不可改**：period/session/stats/limits 的 JSON 键必须与渲染层消费方一致（渲染层在 `src/electron/renderer/app.js`、`homeOverview.js`、`dashboard.js`）。改键前先在渲染层找消费点。
2. **桥方法名 = 原 Electron IPC 通道名**（`settings:get`、`stats:get`、`clipboard:write`、`dashboard:getHistory`…），桥两端（`tokenMonitorBridge.js` 与 `Bridge.swift`）要同步。
3. **客户端清单一致性**：`claude,codex,opencode,workbuddy,proma,hanako,dsh` 要同时出现在 app.js 的 `clientLabels`/`KNOWN_CLIENTS`/`clientsWithIcon`、Swift `CollectorCore`、`Bridge.clientSourceRoots`、`assets/icons/<id>.svg`、styles.css `.row-icon-<id>`。新增客户端照 AGENTS.md 清单改。
4. **vendor 目录别动**：`native-app/Vendor/tokscale/`（16.7MB 二进制，MIT，有 NOTICE）与 `native-app/Vendor/zstd/`（BSD 静态库）——升级需同时更新 NOTICE。
5. **渲染层改动最小化**：app.js 已有 `els` Proxy（缺失 DOM 返回哑元素）与 `Array.from` 空值补丁，删区块后不用逐个判空；新报错看 `[renderer]` 日志。
6. 提交规范：conventional commits，别加 AI 署名尾注。
7. 调试技巧：DSH 会话是"边写边读"的流式 zstd，解压失败会自动跳过该文件，别当 bug；`[dsh]` 日志行会报告 files/usageEvents/rows 计数。

## 五、已知限制（对用户如实说明）

- 外观固定默认主题；无自动更新；用量历史全新开始（凭证与订阅沿用旧文件）。
- 项目分组视图未移植（关闭中）；会话详情暂空。
- 应用为本地 ad-hoc 签名，只在用户本机使用。
