# Release 产物资源引用清单（PLAN.md Phase 7）

以 `dist/Token Monitor.app`（Release 构建）为准，逐项给出引用依据与验证方式。

## Bundle 内容（20MB）

| 路径 | 大小 | 引用依据 |
| --- | --- | --- |
| Contents/MacOS/TokenMonitor | ~1.0MB（strip 后） | 主二进制 |
| Contents/Resources/tokscale | 16.7MB | TokscaleRunner 扫描器（PLAN 禁止删除） |
| Contents/Resources/tokenMonitorBridge.js | 11KB | 每个 WebView 注入（GlassWindowController） |
| Contents/Resources/tray-token-monitor.png | 0.8KB | AppDelegate 状态栏图标 |
| Contents/Resources/icon.png | 0.7MB | Info.plist CFBundleIconFile |
| Contents/Resources/www/** | ~1.5MB | index.html / dashboard.html 引用 |
| Contents/Resources/www/icons/ | — | 见下 |

## www 顶层文件核对（44 个，全部被引用）

- 脚本/CSS：index.html 与 dashboard.html 的 `<script>/<link>` 清单与 www 顶层文件一一对应
  （含 stage 进来的 windowShortcut.js、motionPreference.js 与 shared/* 8 个共享模块）。
- 验证命令：

```bash
grep -oE '(src|href)="[^"]+"' .../www/{index,dashboard}.html | sort -u   # 引用集合
ls .../www/*.js .../www/*.css                                       # 实际文件集合
```

## 图标核对

- www/icons/ 根目录 24 个 svg/png：全部出现在 renderer JS/CSS/HTML 的 `icons/<name>` 引用中。
- actions/（3）、settings/（5）、views/（8）子目录：全部被 styles.css/app.js 的 `url(...)` 引用。
- 动态模型/provider 图标走 `icons/<slug>.svg` 的 slug 映射（trayProviderIcons.js 等）；
  阶段脚本 allowlist 与引用集合一致（claude/codex/opencode/workbuddy/proma/hanako/dsh/deepseek/…）。

## 无引用、已确认安全的清理

- 基线提交（aef03dfe）已删除 Electron 专属代码/资源（.github 资产、windowsBackdropMode、
  wslStatusPresentation、diagnosticsPanel、floatingBubbleBoot、未用 icons 等，共 -3522 行）。
- 冗余清理轮（macos-native 2026-08）：项目功能残留（accordionRows 分支、project CSS/图标/i18n）、
  语言设置 i18n 族、reasonix.native.* i18n、~110 条死 CSS 规则、SettingsStore 6 个死字段、
  projectsEnabled/projectsIncomplete 残留字段、桥死通道（window:minimize/dashboard:minimize、
  appearance:preview、floatingBubble 除 setCollapsedSize、hub:getInfo/regenerateSecret、
  sessionUsageArchive:clear、cursor/claude/ollama/copilot 账号面）、setupCursorAccountUI 14 个
  死账号块（app.js -2062 行）、休眠监听（onOpenView/onFloatingBubbleState/onHubPush）、
  会话归档 UI（原生无归档后端）、重复实现（hashKey→CredentialHash、formatCompactNumber 去重）。
- 保留的行为契约：`pricing:lookup`（经 TokscaleRunner 查价，命中 6h 缓存或拉起 tokscale 子进程，
  异步执行不阻塞主线程，供「自定义模型定价」表单预填当前单价）；`floatingBubble:setCollapsedSize`
  （tray 内容合成链调用）；`codex/mimo/openrouter/thirdparty` 账号面（limits 面板仍在调用）。

## 验证结果

- Release 构建 ✓；JS 语法检查（node --check，全部文件）✓；fixture 检查 58/58 ✓；git diff --check ✓。
- 阶段脚本重建 www 后重新执行本清单的 grep 对账即可复核。

