import AppKit
import CoreImage
import UniformTypeIdentifiers
import WebKit

enum AppSupport {
    static func directory(_ name: String) -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBrowser", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// User-chosen tab icon images, copied into Application Support.
enum IconStore {
    static let directory = AppSupport.directory("Icons")

    static func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    static func importImage(from source: URL) -> String? {
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        do {
            try FileManager.default.copyItem(at: source, to: url(for: fileName))
            return fileName
        } catch {
            return nil
        }
    }
}

extension Notification.Name {
    static let faviconUpdated = Notification.Name("NotchBrowser.faviconUpdated")
}

/// Site icons keyed by host, cached in memory and on disk.
final class FaviconCache {
    static let shared = FaviconCache()
    private let directory = AppSupport.directory("Favicons")
    private var memory: [String: NSImage] = [:]

    func image(for host: String) -> NSImage? {
        if let image = memory[host] { return image }
        guard let image = NSImage(contentsOf: fileURL(for: host)), image.isValid else { return nil }
        memory[host] = image
        return image
    }

    private func fileURL(for host: String) -> URL {
        directory.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_"))
    }

    private static let iconScript = """
    (() => {
      const links = [...document.querySelectorAll("link[rel~='icon'], link[rel='apple-touch-icon']")];
      const best = links.sort((a, b) => (parseInt(b.sizes?.value) || 0) - (parseInt(a.sizes?.value) || 0))[0];
      return best ? best.href : new URL('/favicon.ico', location.href).href;
    })()
    """

    /// Reads the page's icon link and downloads it.
    func fetch(from webView: WKWebView) {
        guard let host = webView.url?.host() else { return }
        webView.evaluateJavaScript(Self.iconScript) { [weak self] result, _ in
            guard let self, let href = result as? String, let url = URL(string: href) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = NSImage(data: data), image.isValid else { return }
                DispatchQueue.main.async {
                    self.memory[host] = image
                    try? data.write(to: self.fileURL(for: host))
                    TabIconRenderer.clearGrayscaleCache()
                    NotificationCenter.default.post(name: .faviconUpdated, object: host)
                }
            }.resume()
        }
    }
}

enum TabIconRenderer {
    static let presetSymbols = [
        "envelope", "calendar", "bubble.left.and.bubble.right", "doc.text", "folder", "star",
        "bolt", "globe", "video", "music.note", "cart", "chart.bar", "person", "briefcase",
        "book", "checklist", "house", "heart", "newspaper", "gamecontroller", "terminal", "sparkles",
    ]

    /// `hosts` are tried in order when the icon is the site favicon.
    static func image(for icon: TabIcon, hosts: [String?], size: CGFloat = 16, grayscale: Bool = false) -> NSImage {
        var image: NSImage?
        var cacheKey = "\(icon)|\(size)"
        switch icon {
        case .favicon:
            if let (host, favicon) = hosts.lazy.compactMap({ $0 }).compactMap({ h in FaviconCache.shared.image(for: h).map { (h, $0) } }).first {
                image = favicon
                cacheKey += "|\(host)"
            }
        case .symbol(let name):
            image = symbol(name, size: size)
        case .emoji(let emoji):
            image = emoji.isEmpty ? nil : emojiImage(emoji, size: size)
        case .image(let fileName):
            image = fileName.isEmpty ? nil : NSImage(contentsOf: IconStore.url(for: fileName))
        }
        guard let image else { return symbol("globe", size: size) ?? NSImage() }
        if image.isTemplate { return image }
        let sized = image.copy() as! NSImage
        sized.size = NSSize(width: size, height: size)
        return grayscale ? desaturated(sized, key: cacheKey) : sized
    }

    private static let ciContext = CIContext()
    private static let grayscaleCache = NSCache<NSString, NSImage>()

    /// Called when a favicon is replaced, since cache keys don't capture image content.
    static func clearGrayscaleCache() { grayscaleCache.removeAllObjects() }

    /// Desaturated copy of a color image. Template images (SF Symbols) are already monochrome.
    private static func desaturated(_ image: NSImage, key: String) -> NSImage {
        if let cached = grayscaleCache.object(forKey: key as NSString) { return cached }
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff),
              let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let cgImage = ciContext.createCGImage(output, from: output.extent) else { return image }
        let result = NSImage(cgImage: cgImage, size: image.size)
        grayscaleCache.setObject(result, forKey: key as NSString)
        return result
    }

    static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.8, weight: .medium))
    }

    private static func emojiImage(_ emoji: String, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: size * 0.85)
            let text = emoji as NSString
            let textSize = text.size(withAttributes: [.font: font])
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: [.font: font])
            return true
        }
    }
}
