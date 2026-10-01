import AppKit

enum NotionTabIcon {
    static func assetName(for appearance: NSAppearance) -> String {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? "NotionAgentIcon-Dark" : "NotionAgentIcon-Light"
    }

    static func image(for appearance: NSAppearance, size: CGFloat = 18) -> NSImage {
        let name = assetName(for: appearance)
        let image = Bundle.main.url(forResource: name, withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "Notionエージェント")
            ?? NSImage()
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        return image
    }
}
