import AppKit

/// 主窗口视图定义与顺序/隐藏归一化（端口自原版 viewDisplayPreferences.js）。
enum AppViews {
    struct ViewDef {
        let id: String
        let label: String
        let symbol: String // SF Symbol
    }

    static let all: [ViewDef] = [
        ViewDef(id: "home", label: "首页", symbol: "house.fill"),
        ViewDef(id: "tool", label: "工具", symbol: "hammer.fill"),
        ViewDef(id: "status", label: "状态", symbol: "bolt.heart.fill"),
        ViewDef(id: "model", label: "模型", symbol: "cpu.fill"),
        ViewDef(id: "project", label: "项目", symbol: "folder.fill"),
        ViewDef(id: "session", label: "会话", symbol: "bubble.left.and.bubble.right.fill"),
        ViewDef(id: "limits", label: "限额", symbol: "gauge.with.dots.needle.67percent"),
        ViewDef(id: "trends", label: "趋势", symbol: "chart.bar.fill"),
    ]

    static let allIds = all.map { $0.id }

    static func def(_ id: String) -> ViewDef {
        return all.first { $0.id == id } ?? ViewDef(id: id, label: id.capitalized, symbol: "circle.fill")
    }

    // MARK: - 顺序/隐藏（viewDisplayPreferences.js 端口）

    static func csvItems(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        return String(describing: value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func normalizeViewDisplayOrder(_ value: Any?) -> [String] {
        let known = allIds
        var seen = Set<String>()
        var order: [String] = []
        for item in csvItems(value) {
            let id = item.lowercased()
            if !known.contains(id) || seen.contains(id) { continue }
            seen.insert(id)
            order.append(id)
        }
        for id in known where !seen.contains(id) {
            seen.insert(id)
            order.append(id)
        }
        return order
    }

    static func normalizeHiddenViews(_ value: Any?) -> [String] {
        let known = allIds
        var hidden: [String] = []
        for item in csvItems(value) {
            let id = item.lowercased()
            if !known.contains(id) || hidden.contains(id) { continue }
            hidden.append(id)
        }
        return hidden.count >= known.count ? [] : hidden
    }

    static func orderedViews(_ orderValue: Any?) -> [ViewDef] {
        return normalizeViewDisplayOrder(orderValue).map { def($0) }
    }

    static func visibleViews(orderValue: Any?, hiddenValue: Any?) -> [ViewDef] {
        let hidden = Set(normalizeHiddenViews(hiddenValue))
        let ordered = normalizeViewDisplayOrder(orderValue)
        var visible = ordered.filter { !hidden.contains($0) }.map { def($0) }
        if visible.isEmpty {
            visible = ordered.map { def($0) }
        }
        return visible
    }

    /// 把视图 id 移到 orderValue 的某个目标索引（设置面板上移/下移用）。
    static func moveView(_ value: Any?, viewId: String, direction: Int) -> String {
        var order = normalizeViewDisplayOrder(value)
        guard let from = order.firstIndex(of: viewId) else { return order.joined(separator: ",") }
        let to = from + direction
        guard to >= 0, to < order.count else { return order.joined(separator: ",") }
        order.remove(at: from)
        order.insert(viewId, at: to)
        return order.joined(separator: ",")
    }

    static func toggleHidden(_ hiddenValue: Any?, viewId: String, hide: Bool) -> String {
        var hidden = normalizeHiddenViews(hiddenValue)
        if hide {
            if !hidden.contains(viewId) { hidden.append(viewId) }
        } else {
            hidden.removeAll { $0 == viewId }
        }
        return hidden.joined(separator: ",")
    }
}
