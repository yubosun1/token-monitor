import AppKit
import ServiceManagement

// MARK: - JSON helpers

func jsonData(_ value: Any) -> Data? {
    guard JSONSerialization.isValidJSONObject(value) else { return nil }
    return try? JSONSerialization.data(withJSONObject: value)
}

func jsonString(_ value: Any) -> String {
    guard let data = jsonData(value) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
}

func jsonObject(_ string: String) -> Any? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

// MARK: - Bridge core (data façade)

/// 原生 UI 取代 WKWebView 后，这个类型从「渲染层 IPC 中枢」退化为一个
/// 轻量数据门面：暴露共享设置、客户端源目录映射和开机登录注册，供视图
/// 控制器直接调用。所有 invoke/send/push 通道已随 WebView 一并移除——
/// 原生 UI 直接读 `Collector` / `LimitsRuntime` / `SettingsStore` /
/// `CredentialStore`，更新信号走 `DataBus` 通知。
final class BridgeCore {
    static let shared = BridgeCore()

    let settings = SettingsStore.shared

    /// 客户端 → 本地数据源根目录（设置面板「在 Finder 中显示」用）。
    func clientSourceRoots(for client: String) -> [(id: String, dir: String)] {
        let home = NSHomeDirectory()
        switch client {
        case "claude":
            return [("claude-projects", "\(home)/.claude/projects"), ("claude-transcripts", "\(home)/.claude/transcripts")]
        case "codex":
            return [("codex-sessions", "\(home)/.codex/sessions")]
        case "opencode":
            return [("opencode-data", "\(home)/.local/share/opencode")]
        case "workbuddy":
            return [("workbuddy-projects", "\(home)/.workbuddy/projects")]
        case "proma":
            return [("proma-sessions", "\(home)/.proma/agent-sessions")]
        case "hanako":
            return [("hanako-sessions", "\(home)/.hanako/agents/hanako/sessions"), ("hanako-activity", "\(home)/.hanako/agents/hanako/activity")]
        case "dsh":
            return [("dsh-sessions", "\(home)/.dsh/sessions")]
        default:
            return []
        }
    }

    func clientSources(for client: String) -> [[String: Any]] {
        let fileManager = FileManager.default
        return clientSourceRoots(for: client).map { root in
            return ["id": root.id, "dir": root.dir, "exists": fileManager.fileExists(atPath: root.dir)]
        }
    }

    /// 注册/注销登录项（设置面板「开机启动」用）。原生 UI 直接调用，不再
    /// 经由 settings:update 的 invoke 路由。
    func applyStartAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("[startup] register/unregister failed: %@", String(describing: error))
        }
    }
}
