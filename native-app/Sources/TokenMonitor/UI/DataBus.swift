import Foundation

/// 原生 UI 数据总线。
///
/// 旧的渲染层通过 `BridgeCore.push(event, payload) → WKWebView.evaluateJavaScript`
/// 把采集/限额更新推给网页。改用原生 AppKit 后没有 WebView 可推，于是把
/// `CollectorEnvironment.push` 改成发 NotificationCenter 通知；原生视图在主队列
/// 监听这些通知，收到后自行拉取 `Collector.shared.latestStats()` 等纯 Swift API
/// 刷新——完全绕开 WebKit 与 IPC 桥。
///
/// 通知本身不带 payload：数据始终从单写者（collector worker / limits queue）写
/// 入的缓存里读，避免通知携带的快照与缓存错版。
enum DataBus {
    /// 用量统计已更新（Collector 完成一次 tick 并写入 statsCache）。
    /// 主窗口 Total/Breakdown/Session/Limits 收到后重新拉取 latestStats()。
    static let statsUpdated = Notification.Name("TokenMonitor.statsUpdated")

    /// 历史趋势数据已重建（Collector 完成 full tick 重建 history）。
    /// Dashboard 趋势图监听，收到后拉取 Collector.shared.history()。
    static let historyUpdated = Notification.Name("TokenMonitor.historyUpdated")
}
