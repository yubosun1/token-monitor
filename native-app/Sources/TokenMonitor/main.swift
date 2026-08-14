import AppKit

// Token Monitor (native macOS)
// Menu bar app: NSStatusItem tray + floating glass panel hosting the
// original HTML/CSS/JS dashboard in a WKWebView. Collection, limits and
// subscriptions are implemented natively in Swift.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
