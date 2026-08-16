import AppKit

/// 原生 UI 主题：端口原版 styles.css 的深色设计令牌。
///
/// 主窗口为等宽字体（原版 body 用 ui-monospace）、薄荷绿 accent（#b7ead4）、
/// 平板分区 + 发丝线（无卡片阴影）；独立 Dashboard 为无衬线字体（原版
/// dashboard.css body 用 -apple-system）。
enum AppTheme {
    // 背景/线条（原版 :root）
    static let overlayColor = NSColor(white: 0.05, alpha: 0.55)          // 玻璃上的深色叠加
    static let glassColor = NSColor(calibratedRed: 48/255, green: 52/255, blue: 56/255, alpha: 0.68)
    static let lineRGB = (232, 238, 244)
    static let hairlineColor = NSColor(calibratedRed: 232/255, green: 238/255, blue: 244/255, alpha: 0.12)
    static let lineColor = NSColor(calibratedRed: 232/255, green: 238/255, blue: 244/255, alpha: 0.138)
    static let lineStrongColor = NSColor(calibratedRed: 232/255, green: 238/255, blue: 244/255, alpha: 0.238)
    static let sunkenColor = NSColor(calibratedRed: 4/255, green: 8/255, blue: 13/255, alpha: 1)
    static let panelColor = NSColor(calibratedWhite: 1, alpha: 0.03)     // 工具条/统计卡等浅面板
    static let controlColor = NSColor(calibratedWhite: 1, alpha: 0.049)  // 控件底（control-alpha）
    static let hoverColor = NSColor(calibratedWhite: 1, alpha: 0.07)
    static let cardColor = NSColor(calibratedWhite: 1, alpha: 0.03)
    static let cardBorderColor = NSColor(calibratedRed: 232/255, green: 238/255, blue: 244/255, alpha: 0.22)

    // 文字（原版 --text / --muted / --number）
    static let textPrimary = NSColor(calibratedRed: 0xEE/255.0, green: 0xF5/255.0, blue: 0xFB/255.0, alpha: 1)
    static let textSecondary = NSColor(calibratedRed: 0xA3/255.0, green: 0xAD/255.0, blue: 0xBB/255.0, alpha: 1) // muted
    static let textTertiary = NSColor(calibratedRed: 0xA3/255.0, green: 0xAD/255.0, blue: 0xBB/255.0, alpha: 0.68)
    static let numberColor = NSColor(calibratedRed: 0xF3/255.0, green: 0xFB/255.0, blue: 0xF7/255.0, alpha: 1)

    // 语义色（原版 --accent / --blue / --orange / --purple / --yellow / --red）
    static let accent = NSColor(calibratedRed: 0xB7/255.0, green: 0xEA/255.0, blue: 0xD4/255.0, alpha: 1) // 薄荷绿
    static let blue = NSColor(calibratedRed: 0x73/255.0, green: 0xBD/255.0, blue: 0xF5/255.0, alpha: 1)
    static let orange = NSColor(calibratedRed: 0xF4/255.0, green: 0xA0/255.0, blue: 0x73/255.0, alpha: 1)
    static let purple = NSColor(calibratedRed: 0xB3/255.0, green: 0x94/255.0, blue: 0xF4/255.0, alpha: 1)
    static let yellow = NSColor(calibratedRed: 0xF1/255.0, green: 0xD9/255.0, blue: 0x73/255.0, alpha: 1)
    static let red = NSColor(calibratedRed: 0xF4/255.0, green: 0x77/255.0, blue: 0x88/255.0, alpha: 1)

    static let positive = NSColor(calibratedRed: 0xB7/255.0, green: 0xEA/255.0, blue: 0xD4/255.0, alpha: 1) // success
    static let warning = NSColor(calibratedRed: 0xF1/255.0, green: 0xD9/255.0, blue: 0x73/255.0, alpha: 1)
    static let danger = NSColor(calibratedRed: 0xF4/255.0, green: 0x77/255.0, blue: 0x88/255.0, alpha: 1)
    static let candleUp = NSColor(calibratedRed: 0x4E/255.0, green: 0xC7/255.0, blue: 0x7F/255.0, alpha: 1)
    static let candleDown = NSColor(calibratedRed: 0xF0/255.0, green: 0x6A/255.0, blue: 0x7B/255.0, alpha: 1)

    // 字体（主窗口对齐原版 ui-monospace；数字用等宽数字）
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static let titleFont = mono(13, .semibold)
    static let bodyFont = mono(12, .regular)
    static let monoFont = mono(12, .regular)
    static let bigNumberFont = mono(30, .medium)           // total 大数字（原版 clamp 30–46px）
    static let numberFont = mono(30, .medium)
    static let smallFont = mono(11, .regular)
    static let microFont = mono(10, .regular)
    static let tabFont = mono(9, .semibold)
    static let buttonFont = mono(12, .regular)
    static let separatorColor = hairlineColor

    // 客户端配色（对齐原版 usageCharts.clientColors 的品牌色；深色品牌色
    // 经 displayColor 抬亮，避免在深底上不可见）。
    static func clientColor(_ id: String) -> NSColor {
        return color(hex: clientHex(id))
    }

    /// 品牌色 hex（原版 clientColors 表）。
    static func clientHex(_ id: String) -> String {
        switch id {
        case "claude":    return "#cc7c5e"
        case "codex":     return "#49a3b0"
        case "deepseek":  return "#4d6bfe"
        case "workbuddy": return "#0DC8A5"
        case "proma":     return "#000000"
        case "hanako":    return "#E8A33D"
        default:          return "#73bdf5"
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
        case "deepseek":  return "DeepSeek"
        default:          return id.capitalized
        }
    }

    /// 把过暗的 hex 抬到可见灰（原版 displayColor）。
    static func displayColor(_ hex: String) -> String {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return hex }
        let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if lum >= 42 { return hex }
        let lift = { (c: Double) -> Int in Int((c + (205 - c) * 0.62).rounded()) }
        return String(format: "#%02X%02X%02X", lift(r), lift(g), lift(b))
    }

    static func color(hex: String) -> NSColor {
        let lifted = displayColor(hex)
        let h = lifted.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return NSColor(calibratedWhite: 0.72, alpha: 1) }
        return NSColor(
            calibratedRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    /// 模型 → 厂商品牌色（原版 modelVendorFor 正则 + 哈希回退调色板）。
    static func modelColor(_ model: String) -> NSColor {
        let name = model.lowercased()
        var vendor: String?
        if name.range(of: #"^(cursor-)?auto$"#, options: .regularExpression) != nil { vendor = "cursor" }
        else if name.range(of: #"claude|anthropic|sonnet|opus|haiku"#, options: .regularExpression) != nil { vendor = "claude" }
        else if name.range(of: #"gpt|openai|codex|^o[134](?:-|$)|o[134]-(mini|pro|preview)|chatgpt"#, options: .regularExpression) != nil { vendor = "codex" }
        else if name.range(of: #"gemini|gemma|google"#, options: .regularExpression) != nil { vendor = "gemini" }
        else if name.range(of: #"grok|xai"#, options: .regularExpression) != nil { vendor = "xai" }
        else if name.range(of: #"deepseek"#, options: .regularExpression) != nil { vendor = "deepseek" }
        else if name.range(of: #"llama|meta"#, options: .regularExpression) != nil { vendor = "meta" }
        else if name.range(of: #"mistral|mixtral|codestral"#, options: .regularExpression) != nil { vendor = "mistral" }
        else if name.range(of: #"qwen|qwq|qvq"#, options: .regularExpression) != nil { vendor = "qwen" }
        else if name.range(of: #"kimi|moonshot"#, options: .regularExpression) != nil { vendor = "kimi" }
        else if name.range(of: #"chatglm|\bglm-|\bzai\b|z\.ai|zhipu"#, options: .regularExpression) != nil { vendor = "zai" }
        else if name.range(of: #"cohere|command-r"#, options: .regularExpression) != nil { vendor = "cohere" }
        else if name.range(of: #"mimo|xiaomi"#, options: .regularExpression) != nil { vendor = "xiaomi" }
        else if name.range(of: #"minimax|\babab"#, options: .regularExpression) != nil { vendor = "minimax" }
        else if name.range(of: #"doubao|\bseed(?:-|$)"#, options: .regularExpression) != nil { vendor = "doubao" }
        else if name.range(of: #"hy3|hunyuan"#, options: .regularExpression) != nil { vendor = "hunyuan" }
        else if name.range(of: #"^big-pickle$"#, options: .regularExpression) != nil { vendor = "opencode" }
        else if name.range(of: #"hermes"#, options: .regularExpression) != nil { vendor = "hermes" }
        else if name.range(of: #"cursor"#, options: .regularExpression) != nil { vendor = "cursor" }

        let vendorHex: [String: String] = [
            "claude": "#cc7c5e", "codex": "#49a3b0", "hermes": "#d4af37", "gemini": "#4285f4",
            "deepseek": "#4d6bfe", "cursor": "#73bdf5", "opencode": "#73bdf5", "xai": "#73bdf5",
            "meta": "#1d65c1", "mistral": "#fa520f", "qwen": "#615ced", "kimi": "#73bdf5",
            "zai": "#73bdf5", "cohere": "#39594d", "xiaomi": "#ff6700", "minimax": "#f23f5d",
            "doubao": "#1E37FC", "hunyuan": "#0053E0",
        ]
        if let vendor, let hex = vendorHex[vendor] { return color(hex: hex) }

        // 哈希回退调色板（原版 fallbackModelColors）。
        let palette = ["#73bdf5", "#cc7c5e", "#a57df0", "#49a3b0", "#f1d973", "#f06a7b"]
        var hash = 0
        for scalar in name.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7FFFFFFF
        }
        return color(hex: palette[abs(hash) % palette.count])
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
