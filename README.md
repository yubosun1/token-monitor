# Token Monitor（macOS 原生定制版）

本项目是 [token-monitor](https://github.com/Javis603/token-monitor)（MIT）的个人定制 fork：把原 Electron 实现改写成**纯原生 macOS 应用**（Swift + AppKit + WKWebView），只为单机本地使用，大幅降低资源占用，同时完整保留原版的界面观感。

- **界面**：原来的 HTML/CSS/JS 渲染层原样保留，跑在 WKWebView 里（像素级一致），外壳是原生 Swift：菜单栏图标、悬浮置顶玻璃窗、⌘E 全局快捷键、原生拖拽。
- **用量采集**：只追踪本机在用的 7 个客户端 —— Claude Code、Codex、OpenCode、WorkBuddy（经 tokscale 引擎）+ Proma、Hanako、DeepSeek Harness（原生 Swift 解析器）。
- **AI 限额**：DeepSeek 余额 + OpenCode 配额（保留原界面与订阅记录功能）。
- 已移除：多设备同步 / Cloudflare Worker、Discord、桌面小组件、自动更新、外观切换、浮动气泡、导出、WSL/Windows/Linux 支持及 18 个用不到的客户端采集。

## 构建

```bash
./native-app/scripts/build-app.sh
# 产物: dist/Token Monitor.app（ad-hoc 签名，仅供本机使用）
```

前置要求：macOS 15+（Apple Silicon）、Xcode Command Line Tools（`swift`）。无 npm 依赖；tokscale 二进制与 libzstd 静态库已 vendor 进仓库（见 `native-app/Vendor/`）。

安装：把 `dist/Token Monitor.app` 拷贝到 `/Applications/`（替换旧的 Electron 版本）即可。凭证（DeepSeek API Key、OpenCode Cookie）自动沿用旧版 `~/Library/Application Support/Token Monitor/credentials.json`；用量统计全新开始。

## 常用命令

```bash
./native-app/scripts/build-app.sh        # 构建 .app
TOKEN_MONITOR_DIAG=1 ./dist/Token\ Monitor.app/Contents/MacOS/TokenMonitor   # 带诊断日志运行
```

## 目录结构

```
native-app/
  Package.swift            SwiftPM 工程（macOS 15，Swift 5 模式）
  Sources/TokenMonitor/    AppDelegate（托盘/窗口）、Bridge（渲染层 IPC）、
                           Collector/（采集核心）、Limits/（限额/订阅/凭证）
  Resources/               tokenMonitorBridge.js（替代 Electron preload 的桥）
  Vendor/                  tokscale 二进制 + libzstd 静态库（vendor 化）
  scripts/                 stage-www.sh（打包渲染层）、build-app.sh
src/electron/renderer/     原版渲染层（唯一保留下来的 JS 界面代码）
assets/icons/              客户端图标
```

数据目录：`~/Library/Application Support/Token Monitor/`（settings.native.json、credentials.json、deepseek-balance-v2.json）。

## 已知取舍

- 界面主题固定为默认外观；项目分组视图（projects）暂未移植（默认关闭）。
- 会话详情弹窗暂只对 Proma/Hanako/DSH 有数据；tokscale 类客户端的逐消息详情待后续实现。
- 版本号沿用 0.44.0-native，不提供自动更新。
