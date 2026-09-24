import AppKit
import AIUsageCore

enum ProviderIcon {
    static func image(for id: ProviderID) -> NSImage {
        if let image = loadPaired(urls: bundledURLs(for: id)) {
            return prepared(image)
        }
        let fallback = NSImage(systemSymbolName: symbolName(for: id), accessibilityDescription: id.displayName)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        fallback.size = NSSize(width: 16, height: 16)
        fallback.isTemplate = true
        return fallback
    }

    private static func prepared(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private static func loadPaired(urls: (URL, URL?)) -> NSImage? {
        guard FileManager.default.fileExists(atPath: urls.0.path),
              let image = NSImage(contentsOf: urls.0) else {
            return nil
        }
        if let twoXURL = urls.1,
           FileManager.default.fileExists(atPath: twoXURL.path),
           let twoX = NSImage(contentsOf: twoXURL) {
            for representation in twoX.representations {
                image.addRepresentation(representation)
            }
        }
        return image
    }

    private static func bundledURLs(for id: ProviderID) -> (URL, URL?) {
        let name: String
        switch id {
        case .cursor: name = "cursor"
        case .chatgpt: name = "chatgpt"
        case .claude: name = "claude"
        }
        let oneX = bundledURL(name) ?? URL(fileURLWithPath: "/dev/null")
        return (oneX, bundledURL("\(name)@2x"))
    }

    private static func bundledURL(_ name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons")
            ?? Bundle.main.url(forResource: name, withExtension: "png") {
            return bundled
        }
        let file = "Resources/Icons/\(name).png"
        var roots: [URL] = []
        if let root = ProcessInfo.processInfo.environment["HERDR_PLUGIN_ROOT"] {
            roots.append(URL(fileURLWithPath: root))
        }
        roots.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent())
        for root in roots {
            let url = root.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func symbolName(for id: ProviderID) -> String {
        switch id {
        case .cursor: return "cursorarrow"
        case .chatgpt: return "sparkles"
        case .claude: return "sparkle"
        }
    }
}
