import AppKit
import WebKit
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

// MARK: - Bridge core

/// Native side of the renderer bridge. Holds the app state (settings now,
/// collectors/limits later) and answers invokes from every web view.
final class BridgeCore {
    static let shared = BridgeCore()

    let settings = SettingsStore.shared

    private let lock = NSLock()
    private var pushers: [(String, Any) -> Void] = []

    func registerPusher(_ pusher: @escaping (String, Any) -> Void) -> () -> Void {
        lock.lock(); defer { lock.unlock() }
        pushers.append(pusher)
        return { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.pushers.removeAll { $0 as AnyObject === pusher as AnyObject }
        }
    }

    func push(_ event: String, _ payload: Any) {
        lock.lock()
        let snapshot = pushers
        lock.unlock()
        for pusher in snapshot { pusher(event, payload) }
    }

    /// Settings as the renderer may see them: credentials are stripped and the
    /// UI-facing credential state is injected. `deepseekApiKeyConfigured` is
    /// what the renderer's `renderDeepseekStatus` reads; `deepseekApiKeySource`
    /// tells it where the key came from ("settings" when stored locally).
    func rendererSettingsSnapshot() -> [String: Any] {
        var snapshot = settings.snapshot()
        snapshot.removeValue(forKey: "deepseekApiKey")
        snapshot.removeValue(forKey: "opencodeProfiles")
        snapshot.removeValue(forKey: "opencodeCookie")
        let hasDeepseekKey = !CredentialStore.shared.deepseekApiKey().isEmpty
        snapshot["deepseekApiKeySource"] = hasDeepseekKey ? "settings" : ""
        snapshot["deepseekApiKeyConfigured"] = hasDeepseekKey
        return snapshot
    }

    func emptyPeriod() -> [String: Any] {
        return [
            "totalTokens": 0, "totalCost": 0, "costUsd": 0,
            "totalInput": 0, "totalOutput": 0,
            "totalCacheRead": 0, "totalCacheWrite": 0,
            "totalReasoning": 0, "totalMessages": 0,
            "sessions": [Any](), "clients": [Any](), "models": [Any](),
            "clientCosts": [Any](), "modelCosts": [Any]()
        ]
    }

    func emptyStats() -> [String: Any] {
        let now = ISO8601DateFormatter().string(from: Date())
        let period = emptyPeriod()
        return [
            "updatedAt": now,
            "periods": ["today": period, "month": period, "allTime": period],
            "devices": [Any](),
            "projectsIncomplete": false,
            "limits": ["providers": [Any](), "updatedAt": NSNull()]
        ]
    }

    /// Answer an `invoke` from the renderer. Method names are the original
    /// Electron IPC channel names (same ones preload.js used). Skeleton
    /// implementations return defaults; real collectors plug in as they land.
    func handleInvoke(_ method: String, args: [Any]) -> Any {
        switch method {
        case "settings:get":
            return rendererSettingsSnapshot()

        case "settings:update":
            guard var patch = args.first as? [String: Any] else { return settings.snapshot() }
            // Route credential-shaped settings keys into the credential store
            // (same split as CREDENTIAL_SETTING_PATHS in the Electron app).
            if let key = patch.removeValue(forKey: "deepseekApiKey") as? String {
                CredentialStore.shared.setDeepseekApiKey(key)
            }
            if let cookie = patch.removeValue(forKey: "opencodeCookie") as? String, !cookie.isEmpty {
                CredentialStore.shared.saveOpencodeProfile(name: "default", cookie: cookie)
            }
            if let profiles = patch.removeValue(forKey: "opencodeProfiles") as? [[String: Any]] {
                for profile in profiles {
                    guard let name = profile["name"] as? String else { continue }
                    let cookie = profile["cookie"] as? String ?? ""
                    let apiKey = profile["apiKey"] as? String ?? ""
                    if !cookie.isEmpty {
                        CredentialStore.shared.saveOpencodeProfile(name: name, cookie: cookie)
                    }
                    if !apiKey.isEmpty {
                        CredentialStore.shared.setOpencodeProfileApiKey(name: name, apiKey: apiKey)
                    }
                }
            }
            // Start-at-login is a native system registration; the setting
            // value itself is kept so the toggle reflects the desired state.
            if let startAtLogin = patch["startAtLogin"] as? Bool {
                applyStartAtLogin(startAtLogin)
            }
            let merged = settings.update(patch)
            // The global toggle shortcut is a Carbon hotkey registration;
            // re-register whenever the recorded combination changes.
            if patch["windowToggleShortcut"] != nil {
                ShortcutController.shared.apply(settings: merged)
            }
            push("settings:push", rendererSettingsSnapshot())
            return rendererSettingsSnapshot()

        case "stats:get":
            return Collector.shared.latestStats() ?? emptyStats()

        case "app:getInfo":
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            return [
                "name": "Token Monitor",
                "version": "0.44.0-native",
                "platform": "darwin",
                "osName": "macOS",
                "osVersion": "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
                "userDataPath": settings.fileURL.deletingLastPathComponent().path,
                "loginItemSupported": true,
                "loginItemOpenAtLogin": SMAppService.mainApp.status == .enabled
            ]

        case "stream:status", "getStreamStatus":
            return ["connected": true, "mode": "local"]

        case "serviceStatus:get", "getServiceStatus":
            let options = args.first as? [String: Any] ?? [:]
            return ServiceStatusRuntime.shared.status(
                force: options["force"] as? Bool ?? false,
                providerIds: options["providerIds"] as? [String]
            )

        case "session:getDetail", "getSessionDetail":
            let args = args.first as? [String: Any] ?? [:]
            return SessionDetailCore.read(
                client: args["client"] as? String ?? "",
                sessionId: args["sessionId"] as? String ?? "",
                period: args["period"] as? String ?? "total",
                sessionCost: UsageCore.doubleValue(args["sessionCost"])
            )

        case "pricing:lookup":
            return NSNull()

        case "dashboard:getHistory", "getDashboardHistory":
            return Collector.shared.history() ?? ["days": [Any](), "monthly": [Any](), "summary": [String: Any]()]

        case "dashboard:open":
            delegate?.bridge(self, didRequestOpenDashboard: true)
            return true

        case "usage:clientSources":
            guard let clientId = args.first as? String else { return NSNull() }
            return clientSources(for: clientId)

        case "usage:revealClientSource":
            guard let clientId = args.first as? String else { return ["ok": false] }
            if let first = clientSourceRoots(for: clientId).first {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first.dir)])
                return ["ok": true]
            }
            return ["ok": false]

        case "usage:rescanClient":
            // Full rescan: the collector re-reads everything on its next tick.
            Collector.shared.refreshNow()
            return ["ok": true]

        case "clipboard:write":
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(args.first as? String ?? "", forType: .string)
            return true

        case "app:openExternal":
            if let urlString = args.first as? String, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            return ["ok": true]

        case "app:openUserData":
            NSWorkspace.shared.activateFileViewerSelecting([settings.fileURL])
            return ["ok": true]

        case "appearance:preview":
            return [String: Any]()

        case "sessionUsageArchive:clear":
            return ["ok": true]

        case "subscriptions:save":
            let list = Subscriptions.normalizeSubscriptions(args.first)
            settings.update(["subscriptions": list, "subscriptionsCacheHub": ""])
            push("settings:push", rendererSettingsSnapshot())
            push("stats:push", Collector.shared.latestStats() ?? emptyStats())
            return rendererSettingsSnapshot()

        case "subscriptions:adoptOrphans", "subscriptions:discardOrphans":
            // Local mode has no hub: orphans are a hub-join artifact.
            settings.update(["subscriptionsOrphaned": [Any]()])
            return ["ok": true]

        case "appUpdate:getState":
            return ["status": "disabled", "available": false, "version": NSNull()]

        case "appUpdate:checkNow", "appUpdate:download", "appUpdate:install", "appUpdate:dismiss":
            return ["status": "disabled"]

        case "diagnostics:generate":
            return ["ok": false]

        case "tokscale:getStatus", "tokscale:checkNpm", "tokscale:downloadFromNpm", "tokscale:resetToBundled":
            return ["ok": false, "available": false]

        case "export:now", "export:pickAutoDir":
            return ["ok": false, "canceled": true]

        case "floatingBubble:expand", "floatingBubble:peek", "floatingBubble:collapseIfIdle",
             "floatingBubble:setCollapsedSize", "floatingBubble:move":
            return [String: Any]()

        case "tray:setIcons":
            return true

        case "hub:getInfo":
            return ["mode": "local", "hubUrl": "", "secret": "", "hostPort": 17321, "connected": false]

        case "hub:regenerateSecret":
            return ["ok": false]

        // Account/profile surfaces for tools the native app no longer manages.
        case "mimo:accounts", "mimo:addAccount", "mimo:openConsole", "mimo:removeAccount",
             "mimo:setAccountEnabled":
            return [String: Any]()
        case "cursor:loginManual", "cursor:logout", "cursor:status",
             "claude:saveCookie", "ollama:validateCookie":
            return [String: Any]()
        case "opencode:getProfiles", "openrouter:getProfiles", "thirdparty:getProfiles":
            if method == "opencode:getProfiles" {
                let profiles = CredentialStore.shared.opencodeProfiles().map {
                    ["name": $0.name, "enabled": $0.enabled]
                }
                return ["profiles": profiles]
            }
            return ["profiles": [Any]()]
        case "opencode:saveProfile":
            let name = args.first as? String ?? ""
            let cookie = args.count > 1 ? (args[1] as? String ?? "") : ""
            CredentialStore.shared.saveOpencodeProfile(name: name, cookie: cookie)
            LimitsRuntime.shared.refreshNow()
            return ["ok": true]
        case "opencode:deleteProfile":
            CredentialStore.shared.deleteOpencodeProfile(name: args.first as? String ?? "")
            LimitsRuntime.shared.refreshNow()
            return ["ok": true]
        case "opencode:renameProfile":
            CredentialStore.shared.renameOpencodeProfile(oldName: args.first as? String ?? "", newName: args.count > 1 ? (args[1] as? String ?? "") : "")
            LimitsRuntime.shared.refreshNow()
            return ["ok": true]
        case "opencode:setProfileEnabled":
            CredentialStore.shared.setOpencodeProfileEnabled(name: args.first as? String ?? "", enabled: args.count > 1 ? (args[1] as? Bool ?? true) : true)
            LimitsRuntime.shared.refreshNow()
            return ["ok": true]
        case "opencode:saveCookie":
            CredentialStore.shared.saveOpencodeProfile(name: "default", cookie: args.first as? String ?? "")
            LimitsRuntime.shared.refreshNow()
            return ["ok": true]
        case "opencode:logout":
            CredentialStore.shared.clearOpencode()
            LimitsRuntime.shared.refreshNow()
            return ["ok": true]
        case "opencode:status":
            let profiles = CredentialStore.shared.opencodeProfiles()
            let configured = profiles.contains { $0.enabled && !$0.cookie.isEmpty }
            return ["status": configured ? "configured" : "notConfigured", "profiles": profiles.map { ["name": $0.name, "enabled": $0.enabled] }]
        case "openrouter:saveProfile", "openrouter:deleteProfile", "openrouter:renameProfile",
             "openrouter:setProfileEnabled",
             "thirdparty:saveProfile", "thirdparty:deleteProfile", "thirdparty:renameProfile",
             "thirdparty:setProfileEnabled",
             "codex:accounts", "codex:addAccount", "codex:selectWorkspace", "codex:cancelLogin",
             "codex:removeAccount", "codex:setAccountEnabled", "codex:switchSystemAccount",
             "codex:refreshAccountLimits",
             "copilot:signIn", "copilot:cancelSignIn":
            return [String: Any]()

        default:
            NSLog("[bridge] unhandled invoke: %@", method)
            return NSNull()
        }
    }

    /// Handle fire-and-forget `send` calls.
    func handleSend(_ method: String, args: [Any], window: NSWindow?) {
        switch method {
        case "window:contentReady":
            push("settings:push", rendererSettingsSnapshot())
            push("stats:push", Collector.shared.latestStats() ?? emptyStats())
        case "window:viewState", "setViewState":
            if let patch = args.first as? [String: Any] {
                let current = settings.snapshot()["lastViewState"] as? [String: Any] ?? [:]
                var merged = current
                merged.merge(patch) { _, new in new }
                settings.update(["lastViewState": merged])
            }
        case "window:diagResult":
            if let payload = args.first as? String {
                NSLog("[diag] interaction: %@", payload)
            }
        case "window:error":
            let message = args.first as? String ?? "renderer error"
            let file = args.count > 1 ? (args[1] as? String ?? "") : ""
            let line = args.count > 2 ? (args[2] as? Int ?? 0) : 0
            let detail = args.count > 3 ? (args[3] as? String ?? "") : ""
            NSLog("[renderer] %@ (%@:%d) %@", message, file, line, detail)
        case "window:minimize":
            window?.miniaturize(nil)
        case "window:close":
            window?.orderOut(nil)
        case "dashboard:ready", "dashboard:minimize", "dashboard:close":
            if method == "dashboard:minimize" {
                window?.miniaturize(nil)
            } else if method == "dashboard:close" {
                window?.orderOut(nil)
            }
        default:
            break
        }
    }

    weak var delegate: BridgeDelegate?

    private func applyStartAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            NSLog("[startup] register/unregister failed: %@", String(describing: error))
        }
    }

    // MARK: - Client source roots (settings → tools view)

    private func clientSourceRoots(for client: String) -> [(id: String, dir: String)] {
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

    private func clientSources(for client: String) -> [[String: Any]] {
        let fileManager = FileManager.default
        return clientSourceRoots(for: client).map { root in
            return ["id": root.id, "dir": root.dir, "exists": fileManager.fileExists(atPath: root.dir)]
        }
    }
}

protocol BridgeDelegate: AnyObject {
    func bridge(_ bridge: BridgeCore, didRequestOpenDashboard: Bool)
}

// MARK: - Per-window bridge router

/// One instance per web view; registers the `bridge` message handler and
/// routes messages to BridgeCore, answering through its own web view.
final class Bridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var window: NSWindow?
    weak var dragController: WindowDragController?

    private let core = BridgeCore.shared
    private var unregisterPusher: (() -> Void)?

    func attach(to webView: WKWebView, window: NSWindow) {
        self.webView = webView
        self.window = window
        webView.configuration.userContentController.add(self, name: "bridge")
        unregisterPusher = core.registerPusher { [weak self] event, payload in
            guard let self, let webView = self.webView else { return }
            let json = jsonString(payload)
            // Pushers run on collector/limits background queues; WKWebView
            // only tolerates evaluateJavaScript on the main thread.
            DispatchQueue.main.async {
                webView.evaluateJavaScript("window.__tmPush(\(Self.jsQuote(event)), \(json))", completionHandler: nil)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "bridge",
              let body = message.body as? [String: Any] else { return }
        let method = String(body["method"] as? String ?? "")
        let args = body["args"] as? [Any] ?? []

        if method == "window:dragStart" {
            dragController?.beginDrag()
            return
        }

        if let id = body["id"] as? Int {
            if method == "session:getDetail" || method == "getSessionDetail"
                || method == "serviceStatus:get" || method == "getServiceStatus" {
                // Heavy or network-bound invokes run off the main thread and
                // resolve asynchronously (the old Electron app used a worker
                // for session detail and a background fetch for status).
                guard let webView = self.webView else { return }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let result = self?.core.handleInvoke(method, args: args) ?? NSNull()
                    let json = jsonString(result)
                    DispatchQueue.main.async {
                        webView.evaluateJavaScript("window.__tmResolve(\(id), \(json))", completionHandler: nil)
                    }
                }
                return
            }
            let result = core.handleInvoke(method, args: args)
            let json = jsonString(result)
            webView?.evaluateJavaScript("window.__tmResolve(\(id), \(json))", completionHandler: nil)
        } else {
            core.handleSend(method, args: args, window: window)
        }
    }

    /// Push an event into this specific web view (used by AppDelegate for
    /// settings:open / view:open, which are window-local).
    func pushLocal(_ event: String, _ payload: Any) {
        let json = jsonString(payload)
        webView?.evaluateJavaScript("window.__tmPush(\(Self.jsQuote(event)), \(json))", completionHandler: nil)
    }

    static func jsQuote(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]) else { return "\"\"" }
        let encoded = String(data: data, encoding: .utf8) ?? "\"\""
        return String(encoded.dropFirst().dropLast())
    }
}
