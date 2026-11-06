import AppKit
import ImageIO

final class SiteIcons {
    static let shared = SiteIcons()
    private let images = NSCache<NSString, NSImage>()
    private var attempted = Set<String>()
    private var lastAddresses: [String] = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()
    init() { images.countLimit = 256; images.totalCostLimit = 4 * 1024 * 1024 }
    func origin(_ address: String) -> String? {
        guard let url = URL(string: address), url.scheme == "https", let host = url.host else { return nil }
        var c = URLComponents()
        c.scheme = "https"; c.host = host; c.port = url.port
        return c.string
    }
    func image(for address: String) -> NSImage? {
        guard let origin = origin(address) else { return nil }
        return images.object(forKey: origin as NSString)
    }
    func load(_ tabs: [TabInfo], changed: @escaping () -> Void) {
        let addresses = tabs.map(\.url)
        guard addresses != lastAddresses else { return }
        lastAddresses = addresses
        for tab in tabs {
            guard let origin = origin(tab.url), attempted.insert(origin).inserted,
                  let url = URL(string: origin + (URL(string: origin)?.host == "app.notion.com" ? "/images/favicon.ico" : "/favicon.ico")) else { continue }
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            session.dataTask(with: request) { [weak self] data, response, _ in
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let data, data.count <= 1024 * 1024 else { return }
                // Decode and rasterize before returning to the UI thread.
                let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 32,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                ]
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
                DispatchQueue.main.async {
                    let icon = NSImage(cgImage: bitmap, size: NSSize(width: 32, height: 32))
                    self?.images.setObject(icon, forKey: origin as NSString, cost: 16384)
                    changed()
                }
            }.resume()
        }
    }
}

final class TabPicker: NSView {
    var snapshot: TabSnapshot?
    var order: [Int] = []
    var selected = 0
    override var isFlipped: Bool { true }

    func update(snapshot: TabSnapshot, order: [Int], selected: Int) {
        self.snapshot = snapshot
        self.order = order
        self.selected = selected
        frame.size = NSSize(width: 560, height: 68 + min(7, order.count) * 64)
        needsDisplay = true
    }
    func label(_ value: String, rect: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        label("\(selected + 1) / \(order.count)", rect: NSRect(x: 480, y: 19, width: 64, height: 20), size: 12, color: .lightGray)
        guard let snapshot else { return }
        let visible = min(7, order.count)
        let start = max(0, min(selected - visible / 2, order.count - visible))
        for row in 0..<visible {
            let position = start + row
            let index = order[position]
            let tab = snapshot.tabs[index]
            let y = CGFloat(52 + row * 64)
            let chosen = position == selected
            if chosen {
                NSColor(calibratedRed: 0.23, green: 0.36, blue: 0.74, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 12, y: y - 3, width: 536, height: 61), xRadius: 10, yRadius: 10).fill()
            }
            let host = URL(string: tab.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? (tab.url.isEmpty ? "Start Page" : tab.url)
            NSColor(white: 1, alpha: chosen ? 0.2 : 0.08).setFill()
            NSBezierPath(roundedRect: NSRect(x: 24, y: y + 7, width: 36, height: 36), xRadius: 9, yRadius: 9).fill()
            if let icon = SiteIcons.shared.image(for: tab.url) {
                icon.draw(in: NSRect(x: 30, y: y + 13, width: 24, height: 24), from: .zero,
                          operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            } else {
            label(String(host.prefix(1)).uppercased(), rect: NSRect(x: 35, y: y + 13, width: 25, height: 24), size: 17, color: .white, weight: .semibold)
            }
            label(tab.title.isEmpty ? "Untitled tab" : tab.title, rect: NSRect(x: 76, y: y + 5, width: 420, height: 23), size: 15, color: .white, weight: chosen ? .semibold : .regular)
            let detail = host + (index == snapshot.selected ? "  ·  Current tab" : "")
            label(detail, rect: NSRect(x: 76, y: y + 29, width: 420, height: 19), size: 12, color: NSColor(white: chosen ? 0.88 : 0.60, alpha: 1))
            if chosen { label("›", rect: NSRect(x: 514, y: y + 10, width: 20, height: 28), size: 25, color: .white) }
        }
    }
}

func renderPicker(to path: String) {
    let picker = TabPicker(frame: .zero)
    let tabs = [
        TabInfo(url: "https://developer.apple.com/documentation", title: "Apple Developer Documentation"),
        TabInfo(url: "https://github.com", title: "Safari Recent Tabs — performance improvements"),
        TabInfo(url: "https://en.wikipedia.org/wiki/Safari", title: "Safari — Wikipedia"),
        TabInfo(url: "https://www.figma.com", title: "Tab switcher · Design exploration"),
        TabInfo(url: "https://calendar.google.com", title: "Calendar — This week")
    ]
    picker.update(snapshot: TabSnapshot(windowID: 1, selected: 0, tabs: tabs), order: Array(tabs.indices), selected: 1)
    guard let bitmap = picker.bitmapImageRepForCachingDisplay(in: picker.bounds) else { return }
    picker.cacheDisplay(in: picker.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    let start = CFAbsoluteTimeGetCurrent()
    for step in 0..<10000 { picker.update(snapshot: TabSnapshot(windowID: 1, selected: 0, tabs: tabs), order: Array(tabs.indices), selected: step % tabs.count) }
    print("10,000 cached picker updates: \((CFAbsoluteTimeGetCurrent() - start) * 1000) ms (excludes drawing)")
}
