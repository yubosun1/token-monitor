import AppKit

/// Brand glyph marks for breakdown / limits rows.
///
/// The original renders these as CSS mask images over `currentColor` (see
/// `.row-icon-*` / `.limit-icon-*` in styles.css), so a row shows the vendor's
/// logo tinted with the vendor's brand color rather than a plain dot. This is
/// the AppKit equivalent: the bundled SVG is rasterized once per (name, size,
/// color) and cached, since rows re-render on every stats push.
enum IconCatalog {
    /// Client id → bundled SVG basename (mirrors the original's `.row-icon-*`
    /// rules). Clients with no bundled asset fall back to a dot.
    private static let clientAssets: [String: String] = [
        "claude": "claude",
        "codex": "codex",
        "opencode": "opencode",
        "workbuddy": "workbuddy",
        "proma": "proma",
        "hanako": "hanako",
        "dsh": "dsh",
        "deepseek": "deepseek",
        "cursor": "cursor",
        "gemini": "gemini",
        "kimi": "kimi",
        "mimo": "xiaomi",
        "xiaomi": "xiaomi",
        "zai": "zai",
        "zaiteam": "zai",
        "cohere": "cohere",
        "minimax": "minimax",
        "doubao": "doubao",
        "hunyuan": "hunyuan",
        "mistral": "mistral",
        "qwen": "qwen",
        "meta": "meta",
        "xai": "xai",
        "grok": "xai",
    ]

    /// Model name → asset, resolved through the same vendor detection the
    /// color palette uses, so `claude-opus-5` gets the Claude glyph.
    static func modelAsset(_ model: String) -> String? {
        guard let vendor = AppTheme.modelVendor(model) else { return nil }
        return clientAssets[vendor]
    }

    static func clientAsset(_ client: String) -> String? {
        return clientAssets[client.lowercased()]
    }

    // MARK: - Rasterization

    private struct CacheKey: Hashable {
        let asset: String
        let size: CGFloat
        let rgba: UInt32
    }

    private static var cache: [CacheKey: NSImage] = [:]
    /// Assets that failed to load once are not retried per row.
    private static var missing: Set<String> = []

    /// Search paths for the SVG assets: the app bundle's Resources (shipping
    /// layout) first, then the repo checkout so `swift run` from source works.
    private static let searchRoots: [URL] = {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL {
            roots.append(resources.appendingPathComponent("icons", isDirectory: true))
        }
        // Dev fallback: <repo>/assets/icons relative to the working directory.
        roots.append(URL(fileURLWithPath: "assets/icons", isDirectory: true))
        return roots
    }()

    /// Tinted glyph for `asset`, or nil when the asset is not bundled.
    static func image(asset: String, size: CGFloat, color: NSColor) -> NSImage? {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let rgba = (UInt32(srgb.redComponent * 255) << 24)
            | (UInt32(srgb.greenComponent * 255) << 16)
            | (UInt32(srgb.blueComponent * 255) << 8)
            | UInt32(srgb.alphaComponent * 255)
        let key = CacheKey(asset: asset, size: size, rgba: rgba)
        if let hit = cache[key] { return hit }
        guard !missing.contains(asset), let base = load(asset: asset) else {
            missing.insert(asset)
            return nil
        }
        let target = NSSize(width: size, height: size)
        let tinted = NSImage(size: target, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        cache[key] = tinted
        return tinted
    }

    private static func load(asset: String) -> NSImage? {
        for root in searchRoots {
            let url = root.appendingPathComponent("\(asset).svg")
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }
}

// MARK: - Mark view

/// Row mark: the vendor glyph when one is bundled, otherwise a colored dot
/// (the original falls back the same way for clients without an icon).
final class RowMarkView: NSView {
    private let imageView = NSImageView()
    private let dot = NSView()
    private let glyphSize: CGFloat

    init(size: CGFloat = 10) {
        self.glyphSize = size
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true
        addSubview(imageView)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        addSubview(dot)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `asset` nil → dot fallback. `showIcons` mirrors the original's
    /// `showToolIcons` setting.
    func configure(asset: String?, color: NSColor, showIcons: Bool = true) {
        if showIcons, let asset, let image = IconCatalog.image(asset: asset, size: glyphSize, color: color) {
            imageView.image = image
            imageView.isHidden = false
            dot.isHidden = true
            return
        }
        imageView.isHidden = true
        dot.isHidden = false
        dot.layer?.backgroundColor = color.cgColor
    }
}
