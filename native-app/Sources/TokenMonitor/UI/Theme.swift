import AppKit

/// 原生 UI 主题：固定深色玻璃风格。
///
/// 窗口外壳仍是 `NSVisualEffectView(.hudWindow)` 玻璃面板；在其上叠一层半透明
/// 深色 overlay，使内容在 light/dark 系统外观下都保持一致的深底浅字观感
/// （对齐原版固定 dark 主题，避免跟随系统在浅色下白字不可读）。
enum AppTheme {
    static let overlayColor = NSColor(white: 0.06, alpha: 0.60)
    static let cardColor = NSColor(white: 1, alpha: 0.05)
    static let cardBorderColor = NSColor(white: 1, alpha: 0.10)
    static let separatorColor = NSColor(white: 1, alpha: 0.07)
    static let hoverColor = NSColor(white: 1, alpha: 0.08)

    static let textPrimary = NSColor.white
    static let textSecondary = NSColor(calibratedWhite: 0.80, alpha: 1)
    static let textTertiary = NSColor(calibratedWhite: 0.56, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.00, alpha: 1)
    static let positive = NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.50, alpha: 1)
    static let warning = NSColor(calibratedRed: 0.96, green: 0.70, blue: 0.33, alpha: 1)
    static let danger = NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.45, alpha: 1)

    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let bigNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 27, weight: .medium)
    static let smallFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
    static let microFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)
    static let tabFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let buttonFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    /// 客户端配色（breakdown 进度条/圆点）。
    static func clientColor(_ id: String) -> NSColor {
        switch id {
        case "claude":    return NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.44, alpha: 1)
        case "codex":     return NSColor(calibratedRed: 0.40, green: 0.78, blue: 0.66, alpha: 1)
        case "opencode":  return NSColor(calibratedRed: 0.55, green: 0.70, blue: 1.00, alpha: 1)
        case "workbuddy": return NSColor(calibratedRed: 0.80, green: 0.60, blue: 0.95, alpha: 1)
        case "proma":     return NSColor(calibratedRed: 0.96, green: 0.76, blue: 0.45, alpha: 1)
        case "hanako":    return NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.68, alpha: 1)
        case "dsh":       return NSColor(calibratedRed: 0.50, green: 0.82, blue: 0.88, alpha: 1)
        default:          return NSColor(calibratedWhite: 0.72, alpha: 1)
        }
    }

    static func clientLabel(_ id: String) -> String {
        switch id {
        case "claude":    return "Claude Code"
        case "codex":     return "Codex"
        case "opencode":  return "OpenCode"
        case "workbuddy": return "WorkBuddy"
        case "proma":     return "Proma"
        case "hanako":    return "Hanako"
        case "dsh":       return "DeepSeek Harness"
        default:          return id.capitalized
        }
    }
}

/// 数值/货币紧凑格式化（端口自 src/shared/compactTokens.js · compactMoney.js）。
enum Fmt {
    static func tokens(_ n: Int) -> String {
        let v = max(0, n)
        if v < 1000 { return "\(v)" }
        if v < 1_000_000 { return String(format: "%.1fK", Double(v) / 1000) }
        if v < 1_000_000_000 { return String(format: "%.2fM", Double(v) / 1_000_000) }
        return String(format: "%.2fB", Double(v) / 1_000_000_000)
    }

    static func tokensExact(_ n: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: max(0, n))) ?? "\(n)"
    }

    static func currencySymbol(_ c: String) -> String {
        switch c {
        case "CNY": return "¥"
        case "HKD": return "HK$"
        case "TWD": return "NT$"
        case "USD": return "$"
        default:    return ""
        }
    }

    /// 把 USD 成本按设置里的目标货币与汇率换算后显示；缺汇率则回落 USD。
    static func money(_ usd: Double, settings: [String: Any]) -> String {
        let currency = (settings["currency"] as? String ?? "USD").uppercased()
        if currency == "USD" { return String(format: "$%.2f", usd) }
        let symbol = currencySymbol(currency)
        let rates = settings["currencyRates"] as? [String: Any] ?? [:]
        for key in ["USD->\(currency)", "USD→\(currency)", "USD\(currency)"] {
            if let r = rates[key] as? Double, r > 0 {
                return String(format: "%@%.2f", symbol, usd * r)
            }
        }
        return String(format: "$%.2f", usd)
    }

    static func percent(_ fraction: Double) -> String {
        let v = max(0, min(1, fraction))
        return String(format: "%.0f%%", v * 100)
    }
}
