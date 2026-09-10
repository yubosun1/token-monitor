<div align="center">
  <img src="assets/icon.png" width="100" alt="Token Monitor 图标">

  # Token Monitor (macOS Native)

  **轻量、高效的 macOS 原生 AI 用量与额度监控工具**

  [![平台](https://img.shields.io/badge/平台-macOS%2015%2B%20(Apple%20Silicon)-blue)](https://www.apple.com/macos/)
  [![构建](https://img.shields.io/badge/构建-SwiftPM%20%C2%B7%20零%20npm%20依赖-orange)](#构建与安装)
  [![许可](https://img.shields.io/badge/许可-MIT-lightgrey)](LICENSE)

  <sub>本项目是 <a href="https://github.com/Javis603/token-monitor">token-monitor</a> 的原生 macOS 定制分支，基于 Swift + AppKit + WKWebView 构建。</sub>
</div>

---

## 核心特性

- **极致低占用**：告别 Electron 的资源开销，后台常驻内存约 40–60MB；窗口隐藏 30 秒后自动回收 WebContent 进程，再次唤出毫秒级呈现。
- **8 大 AI 客户端用量追踪**：
  - **Tokscale 驱动**：Claude Code、Codex、WorkBuddy
  - **Swift 原生解析**：Kimi、Proma、Hanako、Antigravity、DeepSeek Harness（v2/v3 会话日志，zstd 流式解压）
- **AI 限额与订阅**：支持 DeepSeek 账户余额与 Kimi 会员额度实时监控，支持多厂商订阅计划登记。
- **macOS 原生体验**：
  - 纯菜单栏常驻（LSUIElement，不占 Dock）
  - 支持在设置中随时隐藏菜单栏图标，仅通过全局快捷键唤出
  - 玻璃拟态暗色悬浮窗，支持窗口置顶与快捷吸附拖拽
- **本地精准统计**：按本地时区自然日/月划分，依事件自身时间戳精确归日（跨午夜会话自动拆分）。
- **多币种与自定义定价**：费用支持 USD / TWD / HKD / CNY 显示，汇率可手动填写、即时生效（自动模式使用内置汇率并显示当前值）；支持按模型覆盖单价（USD / 1M tokens）。

---

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `⌘E` | 全局呼出 / 隐藏窗口（可在设置中自定义） |
| `⌘W` | 关闭窗口（主窗隐藏、仪表盘回收） |
| `⌘Q` | 退出程序 |

---

## 构建与安装

### 环境要求
- macOS 15+ (Apple Silicon)
- Xcode Command Line Tools (`swift`)
- *无需 Node.js 或 npm 依赖（Tokscale 与 libzstd 已内置 Vendor）*

### 构建与运行
```bash
./native-app/scripts/build-app.sh
```
构建产物位于 `dist/Token Monitor.app`，直接拖入 `/Applications/` 即可。

---

## 常用开发命令

```bash
./native-app/scripts/build-app.sh        # 构建并打包应用
./native-app/scripts/check-fixtures.sh   # 运行数据采集与聚合逻辑校验测试 (680+ checks)
```

---

## 数据存储

本地配置与历史记录存放于 `~/Library/Application Support/Token Monitor/`：
- `settings.native.json`：原生版配置（窗口位置、设置项等）
- `credentials.json`：DeepSeek API Key 与 Kimi 凭证
- `ledger.db`：SQLite 本地用量台账（防删除持久化）

---

## 许可

MIT License. 上游项目：[Javis603/token-monitor](https://github.com/Javis603/token-monitor)。
