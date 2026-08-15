# Token Monitor（macOS 原生定制版）

本项目是 [token-monitor](https://github.com/Javis603/token-monitor)（MIT）的个人定制 fork：把原 Electron 实现改写成**纯原生 macOS 应用**（Swift + AppKit + WKWebView），仅供单机本地使用。渲染层沿用原版 HTML/CSS/JS（像素级一致），外壳全部换成本地代码，资源占用远低于 Electron 版。

## 特性

- **界面**：原版渲染层跑在 WKWebView 中，外观与 Electron 版一致；外壳为原生 Swift —— 菜单栏图标、悬浮置顶玻璃窗、⌘E 全局快捷键、原生窗口拖拽、空闲自动回收隐藏窗口的 WebView（省内存）。
- **用量采集**：只追踪本机 7 个客户端 —— Claude Code、Codex、OpenCode、WorkBuddy（经 tokscale 引擎）+ Proma、Hanako、DeepSeek Harness（原生 Swift 解析器）。
- **AI 限额**：DeepSeek 余额 + OpenCode 配额（保留原版界面与订阅记录功能）。
- **统计口径**：今日/本月/全部按**本地时区自然日/自然月**划分，用量按**消息/事件自身时间戳**归日（跨午夜的会话会正确拆到两天），与 tokscale 的 `bucketTimezone` 配置保持一致。
- **已移除**：多设备同步 / Cloudflare Worker、Discord、桌面小组件、自动更新、外观切换、浮动气泡、导出、WSL/Windows/Linux 支持及 18 个用不到的客户端采集。

## 环境要求

- macOS 15+（Apple Silicon）
- Xcode Command Line Tools（`swift`，构建时使用）
- 无 npm 依赖；tokscale 二进制与 libzstd 静态库已 vendor 进仓库（`native-app/Vendor/`）

## 构建与安装

```bash
./native-app/scripts/build-app.sh
# 产物: dist/Token Monitor.app（ad-hoc 签名，仅供本机使用）
```

安装：把 `dist/Token Monitor.app` 拷贝到 `/Applications/`（替换旧版本）即可。凭证（DeepSeek API Key、OpenCode Cookie）自动沿用 `~/Library/Application Support/Token Monitor/credentials.json`；用量统计从首次运行起全新开始。

## 常用命令

```bash
./native-app/scripts/build-app.sh                      # 构建 .app
TOKEN_MONITOR_DIAG=1 ./dist/Token\ Monitor.app/Contents/MacOS/TokenMonitor   # 带诊断日志运行
```

## 数据源与采集器

| 客户端 | 数据目录 | 采集方式 |
|---|---|---|
| Claude Code | `~/.claude/projects`、`~/.claude/transcripts` | tokscale 引擎 |
| Codex | `~/.codex/sessions` | tokscale 引擎 |
| OpenCode | `~/.local/share/opencode/storage/message` | tokscale 引擎 |
| WorkBuddy | `~/.workbuddy/projects`、`~/.workbuddy/sessions` | tokscale 引擎 |
| Proma | `~/.proma/agent-sessions` | 原生 Swift 解析器（按消息时间戳归日） |
| Hanako | `~/.hanako/agents/hanako/sessions`、`.../activity` | 原生 Swift 解析器（按消息时间戳归日，跨文件消息去重） |
| DeepSeek Harness | `~/.dsh/sessions/**/session.jsonl.zstd` | 原生 Swift 解析器（vendored libzstd 流式解压，按 usage 事件时间戳归日） |

- tokscale 为 vendor 的 `@tokscale/cli-darwin-arm64 4.13.0`（Rust），其日/月分桶遵循 `~/.config/tokscale/settings.json` 中的 `scanner.bucketTimezone`（建议设为你的本地时区，如 `Asia/Shanghai`）。
- 所有本地解析带 (path, mtime, size) 指纹缓存：文件未变不重复解压/解析；会话文件被追加写入时增量重读。
- 无时间戳的行只计入「全部」统计，不计入今日/本月。

## 数据目录

`~/Library/Application Support/Token Monitor/`：

- `settings.native.json` —— 原生版设置（独立于旧 Electron 版的 `settings.json`，互不干扰）
- `credentials.json` —— DeepSeek API Key / OpenCode Cookie（沿用旧版）
- `deepseek-balance-v2.json` —— DeepSeek 余额缓存
- `pricing-cache.json` —— 模型单价缓存（6 小时 TTL）
- `diag/` —— 诊断模式（`TOKEN_MONITOR_DIAG=1`）下的统计快照转储

## 目录结构

```
native-app/
  Package.swift            SwiftPM 工程（macOS 15，Swift 5 模式）
  Sources/TokenMonitor/    AppDelegate（托盘/窗口）、Bridge（渲染层 IPC）、
                           Collector/（采集核心：Adapters / UsageCore / HistoryCore /
                           CollectorCore / SourceScanner / TokscaleRunner）、
                           Limits/（限额/订阅/凭证）、SessionDetail、Status
  Resources/               tokenMonitorBridge.js（替代 Electron preload 的桥）
  Vendor/                  tokscale 二进制 + libzstd 静态库（vendor 化）
  scripts/                 build-app.sh（打包渲染层 + 构建）、stage-www.sh 等
  docs/                    性能与调优记录
src/electron/renderer/     原版渲染层（唯一保留的 JS 界面代码）
assets/icons/              客户端图标
```

## 诊断

设置环境变量 `TOKEN_MONITOR_DIAG=1` 启动可输出：

- `[perf]` 采集 tick 各阶段耗时、CPU/内存足迹；
- `[dsh]` 每次 zstd 解压与解析结果（文件数 / usage 事件数 / 行数）；
- `[diag]` 页面状态探针与交互探针；
- 每次 stats 推送的完整 JSON 快照（`TOKEN_MONITOR_DIAG_DIR` 可指定输出目录）。

## 已知取舍

- 界面主题固定为默认外观；项目分组视图（projects）暂未移植（默认关闭）。
- 会话详情弹窗对 Proma/Hanako/DSH 及 tokscale 类客户端有数据；逐消息详情覆盖范围以代码为准。
- 版本号沿用 0.44.0-native，不提供自动更新。

## 常见问题

**为什么仪表盘/悬浮窗的「今天」数据为 0？**
检查系统时区是否为本地时区（统计按本地自然日划分）；tokscale 类客户端还需确认 `~/.config/tokscale/settings.json` 中 `scanner.bucketTimezone` 与本地时区一致。若为跨午夜的会话，确认用量按事件时间归日（本版已修复）。

**DeepSeek Harness 的用量没有显示？**
确认 `~/.dsh/sessions` 下存在 `session.jsonl.zstd` 文件，且应用「客户端」设置里已启用 dsh。

## 许可

MIT，见 [LICENSE](LICENSE)。上游项目：[Javis603/token-monitor](https://github.com/Javis603/token-monitor)。
